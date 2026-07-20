# HTTPS via Certbot — Design

## Context

This stack currently serves SuiteCRM over plain HTTP only, through Envoy on host port 80 (the single ingress point — see `CLAUDE.md`'s "Envoy: single ingress point" section). To run this behind a real public URL, we need HTTPS with automatically renewing Let's Encrypt certificates. Envoy has no built-in ACME client (unlike Caddy/Traefik), so certbot has to be wired in as a separate service, with Envoy doing TLS termination using the certificates certbot obtains.

The project's existing philosophy is a single static `docker-compose.yml` runnable from just that file + `.env`, with all deployment-specific values passed as environment variables (see `SITE_URL`, `DB_*`, etc. in `.env.example`). HTTPS must fit that same model: **optional, off by default**, toggled by env vars, no change to the zero-domain local/quick-start flow, and no extra `-f` compose files or custom Docker images.

## Requirements

- HTTPS is opt-in via env vars in `.env`; default behavior (no domain, HTTP-only via Envoy on port 80) must be unchanged.
- Domain ownership is proven via ACME HTTP-01 (webroot) — no DNS provider credentials required, since Envoy already owns port 80.
- Certificates auto-renew for the lifetime of the stack, with no manual intervention.
- Single command stays `docker compose up -d`; the only thing that changes between HTTP-only and HTTPS is `.env` contents.
- No new Dockerfile/custom image to build or publish — reuse the official `certbot/certbot` and `nginx:alpine` images, with any custom logic supplied as an inline file via Compose `configs:` (the same pattern already used for `envoy_config`).

## Architecture

```
                 ┌────────────────────────────────────────────┐
 host:80 ───────▶│                                              │
 host:443 ──────▶│                    envoy                    │──────▶ app:8888 (suitecrm_app cluster)
                 │  :80  route "/.well-known/acme-challenge/*"  │──────▶ certbot-web:80 (certbot_web cluster)
                 │  :80  route "/*"                             │──────▶ app:8888
                 │  :443 TLS-terminate, route "/*"               │──────▶ app:8888
                 └────────────────────────────────────────────┘
                          ▲                          ▲
                          │ reads certs (ro)          │ serves webroot
                 ┌────────┴────────┐        ┌─────────┴─────────┐
                 │  certbot_certs  │        │  certbot_webroot   │
                 │  (data/certbot) │        │  (internal volume) │
                 └────────┬────────┘        └─────────┬──────────┘
                          │ writes                     │ writes token
                 ┌────────┴─────────────────────────────┴────────┐
                 │                     certbot                    │
                 │  - bootstraps placeholder self-signed cert     │
                 │  - if TLS_ENABLED: certonly --webroot, then    │
                 │    `certbot renew` every 12h forever           │
                 │  - if not TLS_ENABLED: idles                   │
                 └─────────────────────────────────────────────────┘
```

Backend traffic between Envoy and `app` stays plain HTTP inside the Docker network (TLS terminates at the edge only) — no change to `app`/`worker`/`db`.

## Components

### `certbot` service
- Image: `certbot/certbot` (official, unmodified).
- `entrypoint`/`command` overridden to run a script supplied inline via a new `configs:` entry (`certbot_entrypoint`), mounted read-only and invoked as `sh /scripts/entrypoint.sh` — avoids needing exec permissions on the Compose-mounted config file, and avoids a new Dockerfile.
- Env: `DOMAIN` (bare hostname, e.g. `crm.example.org`), `CERTBOT_EMAIL`, `TLS_ENABLED`.
- Script behavior:
  1. `CERT_DOMAIN="${DOMAIN:-localhost}"`.
  2. If `/etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem` doesn't exist: generate a self-signed placeholder there via `openssl req -x509 -nodes -newkey rsa:2048 -days 1 -keyout .../privkey.pem -out .../fullchain.pem -subj "/CN=$CERT_DOMAIN"`. This unblocks Envoy's 443 listener on first boot regardless of whether TLS is actually enabled.
  3. If `TLS_ENABLED` is true and no real cert has been issued yet for `$DOMAIN` (checked via `/etc/letsencrypt/renewal/$DOMAIN.conf` absence — the placeholder never creates this file, only real certbot issuance does): remove the placeholder's `live`/`archive` entries for that name, then run `certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --email "$CERTBOT_EMAIL" --agree-tos --non-interactive --cert-name "$DOMAIN"`.
  4. If `TLS_ENABLED` is true: loop forever, `certbot renew --webroot -w /var/www/certbot --quiet` every 12h (certbot's own recommended cadence — `renew` is a no-op unless within the renewal window, and only touches certs it manages, so a failed/pending initial issuance is retried on the same cadence rather than crash-looping or hammering Let's Encrypt's rate limits).
  5. If `TLS_ENABLED` is false: `sleep infinity` (placeholder already in place, nothing else to do).
- Healthcheck: file existence check on `/etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem`, so Envoy can `depends_on: certbot: condition: service_healthy` and never race a missing cert file on first boot.
- Volumes: `certbot_certs:/etc/letsencrypt`, `certbot_webroot:/var/www/certbot`.

### `certbot-web` service
- Image: `nginx:alpine` (official, unmodified), config supplied inline via a new `configs:` entry (`certbot_web_config`) — same pattern as `envoy_config`.
- Serves only `/var/www/certbot` (the ACME webroot) on port 80. Not published to the host — reachable only from Envoy's `certbot_web` cluster, exactly like `app` is reachable only via the `suitecrm_app` cluster.
- Volumes: `certbot_webroot:/var/www/certbot:ro`.

### Volumes
- `certbot_certs` — new named volume, `driver: local` + `driver_opts` bound to `${PWD}/data/certbot`, following the same pattern just established for `db_data`/`app_data` (see `docker-compose.yml` and `CLAUDE.md`'s volumes section).
- `certbot_webroot` — plain internal named volume (transient ACME challenge tokens only; no reason to persist across recreation or expose on the host).

### Envoy changes
Still one static `envoy_config` (no templating, no custom image) — `${DOMAIN:-localhost}` is interpolated by Compose at parse time, same mechanism already used for `${DB_*}` etc. elsewhere in the file.
- Port-80 listener gains a route, checked *before* the existing catch-all `/` route: prefix `/.well-known/acme-challenge/` → new `certbot_web` cluster (`certbot-web:80`).
- New port-443 listener: `downstream_tls_context` / `tls_certificates` referencing `/etc/letsencrypt/live/${DOMAIN:-localhost}/fullchain.pem` and `.../privkey.pem` by filename (Envoy watches filename-based cert sources for changes and hot-rotates without a restart — this is what makes renewal "just work" without touching the envoy container). Routes to `suitecrm_app`, same as port 80.
- `ports:` gains `"443:443"` unconditionally.
- `depends_on: certbot: condition: service_healthy` (new), in addition to the existing `depends_on: app`.
- New `certbot_web` cluster definition (mirrors the existing `suitecrm_app` cluster, pointed at `certbot-web:80`).
- Mounts `certbot_certs:/etc/letsencrypt:ro`.

### Env vars (`.env.example`)
```
TLS_ENABLED=false
# DOMAIN=crm.example.org
# CERTBOT_EMAIL=admin@example.org
```

## Error handling / edge cases

- **DNS not pointed yet / port 80 unreachable externally when `TLS_ENABLED=true`**: `certonly` fails; the site stays reachable via the placeholder cert on 443 and plain HTTP on 80. Retried every 12h on the same loop — no crash-loop, no aggressive retry that could trip Let's Encrypt rate limits (5 duplicate-cert failures/week per domain).
- **`TLS_ENABLED` flipped back to `false` after a real cert was issued**: renewal stops, but the existing real cert isn't deleted — Envoy keeps serving it until it goes stale. Documented as a manual `rm -rf data/certbot` if a full reset is wanted.
- **Changing `DOMAIN` to a different hostname**: old cert data isn't auto-cleaned; document as a manual `data/certbot` cleanup step.

## Verification

- **Local / no-domain (default)**: `docker compose up -d` → `curl -I http://localhost/` still 200; `curl -k https://localhost/` reaches the placeholder cert (won't be trusted, expected).
- **Real domain** (requires actual DNS + open ports — cannot be exercised in this dev sandbox): set `TLS_ENABLED=true`, `DOMAIN`, `CERTBOT_EMAIL` in `.env`; `docker compose up -d`; `docker compose logs -f certbot` to watch issuance; `curl -I https://$DOMAIN/` once issued.
- **Renewal dry run**: `docker compose exec certbot certbot renew --dry-run`.
