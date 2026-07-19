# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker/Compose deployment of SuiteCRM 8.10.1 (self-hosted CRM, Symfony-based backend + legacy PHP frontend under `public/legacy`). There is no application source code here — this repo only builds and orchestrates the container images. The SuiteCRM codebase itself is fetched at image-build time from `suitecrm.com` and lives inside the image/volume, not in this repo.

## Commands

```bash
cp .env.example .env        # fill in DB/admin credentials and SITE_URL first
make up                     # docker compose up -d --build
make down                   # docker compose down
make build                  # docker build -t crm .  (single-image build, no compose)
```

There is no test suite, linter, or formatter in this repo — it's infrastructure config, not application code. "Testing" a change means rebuilding and hitting the running instance:

```bash
docker compose up -d --build
curl -I http://localhost:8080/          # expect 200/301, not 404 or connection refused
docker compose logs -f app              # watch the installer / Apache startup
docker compose logs worker              # confirm the Messenger worker is consuming, not crash-looping
```

To force a clean reinstall (wipes the DB and the installed SuiteCRM state):

```bash
docker compose down -v
```

## Architecture

Four services in `docker-compose.yml`, three of them the same image built from the multi-stage `Dockerfile`:

- **`envoy`** — the only service with a `ports:` mapping to the host (8080). Everything else is reachable only from other containers on the compose network. See "Envoy: single ingress point" below.
- **`db`** — `mariadb:11`, data in the `db_data` volume, healthchecked via `healthcheck.sh`.
- **`app`** — serves SuiteCRM over Apache on port 8080 *inside the compose network only* (no host port mapping — traffic reaches it exclusively through `envoy`), code/config in the `app_data` volume.
- **`worker`** — same image as `app`, but overrides `command` to run `bin/console messenger:consume internal-async` (SuiteCRM 8.10+ needs this running or background/scheduled tasks — email, workflows — queue forever and never execute). The receiver name is `internal-async`, **not** `async`.

### Dockerfile: why it's multi-stage

Stage 1 (`builder`) installs `-dev` headers and compiles the PHP extensions SuiteCRM needs (gd, intl, mbstring, mysqli, pdo_mysql, soap, zip) via `docker-php-ext-install`, then downloads and unzips the SuiteCRM release into `/apps`. Stage 2 starts fresh from `php:8.3-apache`, installs only the matching runtime shared libs (no compilers/headers), and copies the compiled extensions plus `/apps` from the builder. This keeps the final image free of build tooling.

Apache's document root is repointed from `/var/www/html` to `/apps/public` (SuiteCRM 8's Symfony-style public folder — the app root must never be served directly). Apache is also moved from port 80 to **8080**, both inside the container and in the compose port mapping — this isn't cosmetic, see the entrypoint section below for why it has to match `SITE_URL`.

### entrypoint.sh: the install has to happen against a *running* server

`bin/console suitecrm:app:install` performs live HTTP self-checks (`check-route-access`, GraphQL calls) against `SITE_URL`. If nothing is listening yet, those checks fail and the install silently corrupts itself — it writes a `config.php` and marks itself "installed" while still missing DB tables (this happened during initial development and is why the entrypoint logic looks the way it does). So on the `app` container only, the entrypoint:

1. Waits for the DB (`mysqli_connect` polling loop).
2. Starts a **temporary** background Apache (`apache2ctl start`), polls `SITE_URL` until it responds.
3. Runs the installer.
4. Stops the temporary Apache (`apache2ctl stop`) and hands off to the real `apache2-foreground` (the Dockerfile's `CMD`), which becomes PID 1.

This is why `SITE_URL` (in `.env`) must resolve to the same port Apache actually listens on inside the container (8080) — it's used both for this internal self-check and as SuiteCRM's public-facing URL.

The `worker` container runs the *same* entrypoint script but never installs anything itself: it just polls for `/apps/public/legacy/config.php` to exist (written by `app`), then execs its `messenger:consume` command. Installation is owned exclusively by `app` to avoid two containers racing to install against the same fresh DB.

Idempotency for `app` itself is a simple existence check on `config.php` — a second start (restart, recreate) skips straight to serving.

### Envoy: single ingress point

`envoy/envoy.yaml` defines one listener (0.0.0.0:8080) that proxies everything to the `app` cluster (`app:8080`) — there is no other route, no other cluster, and the admin interface is bound to `127.0.0.1:9901` inside the container (not published). This, combined with `app`/`db`/`worker` no longer publishing any ports of their own, means the host can reach nothing except through Envoy's single listener — there's no separate "firewall rule" step, the compose topology itself enforces it.

One real gotcha hit while setting this up: the official `envoyproxy/envoy` image drops privileges from root to a built-in `envoy` user (uid 101) via `su-exec` before reading its config (see `/docker-entrypoint.sh` in the image). A bind-mounted `envoy.yaml` that isn't world-readable on the host fails with a misleading `unable to read file` error — the fix is keeping `envoy/envoy.yaml` at least `644`.

### Volumes: why `app_data` isn't a bind mount

`app_data:/apps` is a named Docker volume, shared between `app` and `worker` — same files, not copies, which is how `worker` can see `config.php` without ever installing. On first mount, Docker seeds an empty named volume from the image's `/apps` content (the freshly-unzipped, not-yet-installed SuiteCRM tree); every start after that reuses whatever was written there (including the installed `config.php`), which is what makes the "skip install if already installed" check actually persist across container recreation. Editing files on the host does **not** affect the running container — there's no bind mount into `/apps`.
