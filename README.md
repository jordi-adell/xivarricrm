# xivarricrm

Un CRM pensant fer fer servir al explai Xivarri i a femXivarri.

A Docker Compose deployment of [SuiteCRM](https://suitecrm.com/) 8.10.1 — a self-hosted, open-source CRM.

This repo doesn't contain SuiteCRM's source: the Dockerfile downloads the official release zip and builds a runnable image from it (PHP 8.3 + Apache), wired up to a MariaDB database, a background worker, and an Envoy reverse proxy via Docker Compose.

## Prerequisites

- Docker and Docker Compose (`docker compose version`)
- `make`
- Port 8080 free on the host

## Getting started

```bash
cp .env.example .env
# edit .env: set real passwords, admin credentials, and SITE_URL if not running on localhost
make up
```

`make up` builds the image and starts four containers:

| Service  | Role |
|----------|------|
| `envoy`  | Reverse proxy — the only container that publishes a port to the host (8080); forwards everything to `app` |
| `db`     | MariaDB 11 — SuiteCRM's database |
| `app`    | Apache + PHP 8.3 serving SuiteCRM, reachable only from `envoy` |
| `worker` | Same image as `app`, runs the Messenger worker that processes SuiteCRM's background/scheduled tasks (emails, workflows) |

The first time it starts, `app` runs SuiteCRM's CLI installer automatically — this takes a minute or two. Watch it with:

```bash
docker compose logs -f app
```

Once it's done, open **http://localhost:8080/** and log in with the `SUITECRM_ADMIN_USER` / `SUITECRM_ADMIN_PASSWORD` from your `.env`.

## Configuration

All configuration lives in `.env` (copy it from `.env.example`, never commit it):

| Variable | Purpose |
|----------|---------|
| `DB_ROOT_PASSWORD` | MariaDB root password |
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | SuiteCRM's database and credentials |
| `SUITECRM_ADMIN_USER`, `SUITECRM_ADMIN_PASSWORD` | Admin account created by the installer |
| `SITE_URL` | Public URL of the instance (must include the port, e.g. `http://localhost:8080`) |
| `DEMO_DATA` | `yes`/`no` — whether to seed demo data during install |

## Common tasks

Stop everything (data persists in Docker volumes):
```bash
make down
```

Reset to a totally clean install (deletes the database and all SuiteCRM state):
```bash
docker compose down -v
make up
```

Rebuild the image after changing the `Dockerfile` or `entrypoint.sh`:
```bash
make up   # runs docker compose up -d --build
```

Tail logs for a specific service:
```bash
docker compose logs -f app       # web server + installer
docker compose logs -f worker    # background task processing
docker compose logs -f db
```

## Data persistence

SuiteCRM's files/config and the database live in two Docker-managed volumes, `app_data` and `db_data` — not in this repo. Stopping and restarting containers (`make down` / `make up`) keeps your data; only `docker compose down -v` wipes it.

## Troubleshooting

- **Blank page / connection refused on :8080** — the installer may still be running; check `docker compose logs -f app`.
- **Worker container restarting in a loop** — check `docker compose logs worker`; this usually means it can't reach SuiteCRM's config yet (still waiting on `app` to finish installing).
- **Changed `.env` after the first install** — most values (DB credentials, admin user) only take effect during the initial install. To apply changes, reset with `docker compose down -v` and run `make up` again.
