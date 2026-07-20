# HTTPS via Caddy — Design

## Context

This stack currently serves SuiteCRM over plain HTTP only, through Envoy on host port 80 (the single ingress point — see `CLAUDE.md`'s "Envoy: single ingress point" section). To run this behind a real public URL, we need HTTPS with automatically renewing Let's Encrypt certificates.

An earlier version of this design kept Envoy and bolted on certbot as a separate service (see git history for that spec) — Envoy has no built-in ACME client, so that required a webroot sidecar, a manually-configured ACME route and TLS listener, and a self-signed placeholder cert to solve the chicken-and-egg problem of Envoy needing a cert file before certbot could obtain one. That's a lot of moving parts to hand-roll something several existing tools already solve well.

**Caddy** obtains and renews Let's Encrypt certificates itself, automatically, as a core feature — no separate ACME client, no webroot sidecar, no manual cert-path wiring. Since this stack's ingress role is a single reverse-proxy route to one backend (no complex routing, no gRPC, no observability requirements that would justify Envoy's extra power), replacing Envoy with Caddy removes essentially the entire certbot design in favor of a ~4-line config file. This also follows the project's global guidance to prefer existing libraries over reimplementing a feature.

The project's existing philosophy is a single static `docker-compose.yml` runnable from just that file + `.env`, with all deployment-specific values passed as environment variables. HTTPS must fit that same model: **optional, off by default**, toggled purely by whether `DOMAIN` is set, no change to the zero-domain local/quick-start flow, and no extra compose files or custom Docker images.

## Requirements

- HTTPS is opt-in via `.env`; default behavior (no domain, HTTP-only on port 80) must be unchanged.
- No separate on/off flag — `DOMAIN` alone decides HTTP-only vs HTTPS, matching Caddy's own default behavior (it only attempts ACME for site addresses that look like real domains, never for bare ports or IPs) and avoiding a state where the flag and the domain could disagree.
- Certificates auto-renew for the lifetime of the stack, with no manual intervention (Caddy handles this natively).
- Single command stays `docker compose up -d`; the only thing that changes between HTTP-only and HTTPS is `.env` contents.
- No new Dockerfile/custom image to build or publish — reuse the official `caddy:2-alpine` image, with the Caddyfile supplied inline via Compose `configs:` (the same pattern already used for `envoy_config`).

## Architecture

```
 host:80  ───────▶┌─────────────────────────────┐
 host:443 ───────▶│            caddy             │──────▶ app:8888
                  │  {$DOMAIN:-:80}              │
                  │    reverse_proxy app:8888     │
                  └──────────────┬────────────────┘
                                 │ persists obtained certs
                        ┌────────┴────────┐
                        │   caddy_data     │
                        │  (data/caddy)    │
                        └──────────────────┘
```

- `DOMAIN` unset → Caddy's site address falls back to `:80` → plain HTTP, identical to today's behavior, no ACME attempted at all.
- `DOMAIN` set to a real hostname → Caddy automatically requests a cert via HTTP-01 (it briefly answers the ACME challenge on port 80 itself, using its own built-in client), serves HTTPS on 443, and renews automatically well before expiry — no separate service, no manual cert paths, no placeholder-cert bootstrap.
- Backend traffic between Caddy and `app` stays plain HTTP inside the Docker network (TLS terminates at the edge only) — no change to `app`/`worker`/`db`.

## Components

### `caddy` service (replaces `envoy`)
- Image: `caddy:2-alpine` (official, unmodified).
- Config supplied inline via a `configs:` entry (`caddy_config`), mounted at `/etc/caddy/Caddyfile` — same mechanism `envoy_config` used, just a much smaller file:
  ```
  {$ACME_EMAIL}

  {$DOMAIN:-:80} {
      reverse_proxy app:8888
  }
  ```
  (The bare `{$ACME_EMAIL}` line is Caddy's global-options block setting the Let's Encrypt account email; harmless/no-op if unset.)
- `ports:` — `"80:80"` and `"443:443"`, still the only service with a host port mapping (Caddy remains the single ingress point).
- `depends_on: app` (same as Envoy had) — no new health-check dependency needed, since there's no separate cert-bootstrap service to wait on.
- Volumes: `caddy_data:/data` (Caddy's own certificate/state storage) and, optionally, `caddy_config_data:/config` (Caddy's autosaved runtime config — low-stakes, can be a plain internal volume, not host-bound).

### Volumes
- `caddy_data` — new named volume, `driver: local` + `driver_opts` bound to `${PWD}/data/caddy`, following the same pattern already established for `db_data`/`app_data`. This is what makes certificates survive container recreation, so restarts don't re-trigger issuance (avoiding Let's Encrypt rate limits).

### Env vars (`.env.example`)
```
# DOMAIN=crm.example.org
# ACME_EMAIL=admin@example.org
```
Both commented out / unset by default, preserving today's HTTP-only quick-start flow exactly.

### `SITE_URL` (existing var, used internally by `entrypoint.sh`)
Default changes from `http://envoy` to `http://caddy` — same role (an address reachable *through* the ingress proxy from inside the `app` container, used only for the installer's live self-check), just following the container rename. No other behavior change; this is independent of whether `DOMAIN`/HTTPS is configured.

## Error handling / edge cases

- **DNS not pointed yet / port 80 unreachable externally when `DOMAIN` is set**: Caddy's own ACME client retries with its own backoff (a well-tested path used by a huge number of production deployments) rather than anything hand-rolled here. The site keeps serving over `:80` in the meantime — Caddy doesn't tear down a working config because a certificate request failed.
- **Changing `DOMAIN` to a different hostname**: old certificate data for the previous domain isn't auto-cleaned from `data/caddy`; document as a manual cleanup step if desired (low stakes — Caddy just stores an unused cert alongside the new one).

## Docs impact

- `CLAUDE.md`'s "Envoy: single ingress point" section is rewritten around Caddy — substantially shorter, since there's no inline listener/route/cluster YAML to explain, and the historical note about the bind-mounted `envoy/envoy.yaml` permissions gotcha becomes moot (Caddy's config is one small file, same `configs:` mechanism, no `su-exec`/uid-101 concern documented for Caddy's image).
- `README.md`'s "Data persistence" section gains `data/caddy` alongside `data/db`/`data/app`.

## Verification

- **Local / no-domain (default)**: `docker compose up -d` → `curl -I http://localhost/` still 200, no TLS involved.
- **Real domain** (requires actual DNS + open ports — cannot be exercised in this dev sandbox): set `DOMAIN`/`ACME_EMAIL` in `.env`, `docker compose up -d`, watch `docker compose logs -f caddy` for issuance, then `curl -I https://$DOMAIN/`.
- **Cert persistence**: `docker compose restart caddy` and confirm (via logs) it does *not* re-request a certificate — it should load the existing one from `data/caddy`.
