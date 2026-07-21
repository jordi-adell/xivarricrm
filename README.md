# xivarricrm

Un CRM pensant fer fer servir al explai Xivarri i a femXivarri.

A Docker Compose deployment of [SuiteCRM](https://suitecrm.com/) 8.10.1 — a self-hosted, open-source CRM. It runs as four containers: a Caddy reverse proxy (the only one reachable from outside, with automatic HTTPS if you give it a domain), the SuiteCRM app itself, a MariaDB database, and a background worker for scheduled/async tasks.

Branded for Esplai Xivarri: the logo and color scheme (navy `#003388`, amber `#f0bc00`) are taken from [xivarri.org](https://xivarri.org/) and baked into the image at build time — see `branding/` and the relevant `Dockerfile` steps, and `CLAUDE.md` for how it's done and why.

## Prerequisites

- Docker and Docker Compose (`docker compose version`)
- Port 80 free on the host

## Quick start (no clone needed)

You only need two files — `docker-compose.yml` and `.env.example` — no source checkout required. This pulls the prebuilt image from GitHub Container Registry (`ghcr.io/jordi-adell/xivarricrm`) instead of building anything locally.

The image is private (it lives in a private GitHub repo), so you need to authenticate to `ghcr.io` before it can be pulled. Use a [personal access token](https://github.com/settings/tokens) with at least the `read:packages` scope:

```bash
docker login ghcr.io -u <your-github-username>
# paste your PAT (with read:packages scope) as the password
```

```bash
curl -O https://raw.githubusercontent.com/jordi-adell/xivarricrm/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/jordi-adell/xivarricrm/main/.env.example
cp .env.example .env
# edit .env: set real passwords and admin credentials (leave SITE_URL as-is, see note below)
docker compose up -d
```

The first time it starts, `app` runs SuiteCRM's CLI installer automatically — this takes a minute or two. Watch it with:

```bash
docker compose logs -f app
```

Once it's done, open **http://localhost/** and log in with the `SUITECRM_ADMIN_USER` / `SUITECRM_ADMIN_PASSWORD` from your `.env`.

### Services

Only `caddy` uses the standard web ports (80/443) — nothing else is reachable from the host at all.

| Service  | Role |
|----------|------|
| `caddy`  | Reverse proxy — the only container that publishes ports to the host (80 and 443); forwards everything to `app` on its internal, non-standard port. Automatically obtains and renews a Let's Encrypt certificate if `DOMAIN` is set (see "HTTPS" below) |
| `db`     | MariaDB 11 — SuiteCRM's database, internal only |
| `app`    | Apache + PHP 8.3 serving SuiteCRM on port 8888 *inside the compose network only*, reachable exclusively through `caddy` |
| `worker` | Same image as `app`, runs the Messenger worker that processes SuiteCRM's background/scheduled tasks (emails, workflows) |
| `backup` | Daily (03:00) database dump + restic backup of SuiteCRM's files to `./data/backups` (see "Backups" below) |

### Configuration

All configuration lives in `.env` (copy it from `.env.example`, never commit it):

| Variable | Purpose |
|----------|---------|
| `DB_ROOT_PASSWORD` | MariaDB root password |
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | SuiteCRM's database and credentials |
| `SUITECRM_ADMIN_USER`, `SUITECRM_ADMIN_PASSWORD` | Admin account created by the installer |
| `SITE_URL` | Address SuiteCRM's installer self-checks against **from inside the `app` container** — defaults to `http://caddy`, Docker's internal DNS name for the proxy. See note below before changing it. |
| `DEMO_DATA` | `yes`/`no` — whether to seed demo data during install |
| `DOMAIN` | Optional. A real public hostname (e.g. `crm.example.org`) that resolves to this host. When set, `caddy` automatically obtains and renews an HTTPS certificate for it. Leave unset for local/HTTP-only use. |
| `ACME_EMAIL` | Optional. Email address given to Let's Encrypt for expiry/problem notifications. Only used when `DOMAIN` is set. |
| `RESTIC_PASSWORD` | Encrypts the `backup` service's restic repository at `./data/backups`. **Losing this makes existing backups permanently unrecoverable** — restic encrypts client-side, there is no recovery path. Store it somewhere durable, separate from this host. |

> **About `SITE_URL`:** SuiteCRM's installer performs live HTTP self-checks against this exact address at install time, so it has to be reachable from inside the `app` container — that's why the default is the internal `http://caddy`, not `http://localhost`. Verified in testing: browsing through `http://localhost/` still works correctly (redirects and the GraphQL API are relative/path-based, not built from an absolute `site_url`). If you're deploying behind a real public domain, either leave this as `http://caddy` for install and update the public URL afterwards in SuiteCRM's admin settings, or point `SITE_URL` at something resolvable from inside `app` at install time — plain `http://localhost` won't work here since Apache no longer listens on the standard port.

### HTTPS

Set `DOMAIN` (and optionally `ACME_EMAIL`) in `.env` before starting the stack, then `docker compose up -d` as usual. `caddy` automatically requests a certificate from Let's Encrypt via the HTTP-01 challenge (it needs port 80 reachable from the internet at that domain to do this) and renews it on its own well before expiry — no other steps required. Leave `DOMAIN` unset (the default) to keep serving plain HTTP on port 80, exactly as before.

### Backups

The `backup` service dumps the database and archives SuiteCRM's files (`app_data`) into a [restic](https://restic.net/) repository once a day (03:00), automatically pruning old snapshots to 7 daily / 4 weekly / 6 monthly. It doesn't back up Caddy's certificates — those are cheap to re-obtain from Let's Encrypt and not worth the storage.

**`data/backups` is meant to be an NFS mount (or other off-host storage) that you set up yourself before starting the stack** — unlike `data/db`/`data/app`/`data/caddy`, `make up` deliberately does *not* auto-create this directory. A backup that lands on the same disk as the data it's protecting doesn't protect against a disk failure, so if `data/backups` doesn't exist (e.g. the NFS mount isn't active), `docker compose up` will fail loudly rather than silently writing "backups" to a local folder that provides no real redundancy.

Set `RESTIC_PASSWORD` in `.env` before first starting the stack (restic refuses to run without it) — see the warning in the Configuration table above.

Useful commands:
```bash
# Trigger a backup immediately instead of waiting for the 03:00 schedule
docker compose exec backup sh /scripts/run.sh

# List snapshots
docker compose exec backup restic snapshots

# Restore a snapshot's contents to a scratch directory for inspection
docker compose exec backup restic restore latest --target /tmp/restore
```

### Common tasks

Stop everything (data persists in Docker volumes):
```bash
docker compose down
```

Reset to a totally clean install (deletes the database and all SuiteCRM state):
```bash
docker compose down -v
docker compose up -d
```

Tail logs for a specific service:
```bash
docker compose logs -f app       # web server + installer
docker compose logs -f worker    # background task processing
docker compose logs -f db
```

### Data persistence

SuiteCRM's files/config, the database, and (if HTTPS is enabled) Caddy's certificates live on the host at `./data/app`, `./data/db`, and `./data/caddy`, next to the compose file (bind-mounted via Docker's `local` driver). Stopping and restarting containers (`docker compose down` / `up`) keeps your data; only `docker compose down -v` wipes it. `./data/backups` (the restic repository — see "Backups" above) is separate: it's expected to be off-host storage you mount yourself, not created automatically.

### Troubleshooting

- **Blank page / connection refused on :80** — the installer may still be running; check `docker compose logs -f app`.
- **Worker container restarting in a loop** — check `docker compose logs worker`; this usually means it can't reach SuiteCRM's config yet (still waiting on `app` to finish installing).
- **Changed `.env` after the first install** — most values (DB credentials, admin user) only take effect during the initial install. To apply changes, reset with `docker compose down -v` and run `docker compose up -d` again.

## For developers (git clone)

Cloning the repo gets you the `Dockerfile`, `entrypoint.sh`, and `docker-compose.override.yml` — the override adds a `build: .` to the `app` and `worker` services, so Compose builds your local changes instead of pulling the published image. Everything else above (services, `.env` config, common tasks, troubleshooting) still applies.

```bash
git clone git@github.com:jordi-adell/xivarricrm.git
cd xivarricrm
cp .env.example .env
make up   # docker compose up -d --build
```

`make up`/`make down` are just shortcuts around `docker compose up -d --build` / `docker compose down`; `make build` (`docker build -t crm .`) builds the image standalone, without Compose, if you just want to inspect it.

Rebuild after changing the `Dockerfile` or `entrypoint.sh`:
```bash
make up
```

Publishing a release image to `ghcr.io/jordi-adell/xivarricrm` happens automatically via `.github/workflows/docker-publish.yml` whenever a tag is pushed:
```bash
git tag v0.0.2
git push origin v0.0.2
```
