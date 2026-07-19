# xivarricrm

Un CRM pensant fer fer servir al explai Xivarri i a femXivarri.

A Docker Compose deployment of [SuiteCRM](https://suitecrm.com/) 8.10.1 — a self-hosted, open-source CRM. It runs as four containers: an Envoy reverse proxy (the only one reachable from outside), the SuiteCRM app itself, a MariaDB database, and a background worker for scheduled/async tasks.

## Prerequisites

- Docker and Docker Compose (`docker compose version`)
- Port 80 free on the host

## Quick start (no clone needed)

You only need two files — `docker-compose.yml` and `.env.example` — no source checkout required. This pulls the prebuilt image from GitHub Container Registry (`ghcr.io/jordi-adell/xivarricrm`) instead of building anything locally.

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

Only `envoy` uses the standard web port (80) — nothing else is reachable from the host at all.

| Service  | Role |
|----------|------|
| `envoy`  | Reverse proxy — the only container that publishes a port to the host, on the standard HTTP port (80); forwards everything to `app` on its internal, non-standard port |
| `db`     | MariaDB 11 — SuiteCRM's database, internal only |
| `app`    | Apache + PHP 8.3 serving SuiteCRM on port 8888 *inside the compose network only*, reachable exclusively through `envoy` |
| `worker` | Same image as `app`, runs the Messenger worker that processes SuiteCRM's background/scheduled tasks (emails, workflows) |

### Configuration

All configuration lives in `.env` (copy it from `.env.example`, never commit it):

| Variable | Purpose |
|----------|---------|
| `DB_ROOT_PASSWORD` | MariaDB root password |
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | SuiteCRM's database and credentials |
| `SUITECRM_ADMIN_USER`, `SUITECRM_ADMIN_PASSWORD` | Admin account created by the installer |
| `SITE_URL` | Address SuiteCRM's installer self-checks against **from inside the `app` container** — defaults to `http://envoy`, Docker's internal DNS name for the proxy. See note below before changing it. |
| `DEMO_DATA` | `yes`/`no` — whether to seed demo data during install |

> **About `SITE_URL`:** SuiteCRM's installer performs live HTTP self-checks against this exact address at install time, so it has to be reachable from inside the `app` container — that's why the default is the internal `http://envoy`, not `http://localhost`. Verified in testing: browsing through `http://localhost/` still works correctly (redirects and the GraphQL API are relative/path-based, not built from an absolute `site_url`). If you're deploying behind a real public domain, either leave this as `http://envoy` for install and update the public URL afterwards in SuiteCRM's admin settings, or point `SITE_URL` at something resolvable from inside `app` at install time — plain `http://localhost` won't work here since Apache no longer listens on the standard port.

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

SuiteCRM's files/config and the database live in two Docker-managed volumes, `app_data` and `db_data` — not in this repo. Stopping and restarting containers (`docker compose down` / `up`) keeps your data; only `docker compose down -v` wipes it.

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
