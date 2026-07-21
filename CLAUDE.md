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
curl -I http://localhost/                # expect 200/301, not 404 or connection refused
docker compose logs -f app              # watch the installer / Apache startup
docker compose logs worker              # confirm the Messenger worker is consuming, not crash-looping
```

To force a clean reinstall (wipes the DB and the installed SuiteCRM state):

```bash
docker compose down -v
```

## Architecture

Five services in `docker-compose.yml`, three of them the same image built from the multi-stage `Dockerfile`:

- **`caddy`** — the only service with a `ports:` mapping to the host: `80:80` and `443:443`. Everything else is reachable only from other containers on the compose network, on deliberately non-standard ports. See "Caddy: single ingress point" below.
- **`db`** — `mariadb:11`, data in the `db_data` volume, healthchecked via `healthcheck.sh`.
- **`app`** — serves SuiteCRM over Apache on port **8888** *inside the compose network only* (no host port mapping, and not the standard 80/8080 — traffic reaches it exclusively through `caddy`), code/config in the `app_data` volume.
- **`worker`** — same image as `app`, but overrides `command` to run `bin/console messenger:consume internal-async` (SuiteCRM 8.10+ needs this running or background/scheduled tasks — email, workflows — queue forever and never execute). The receiver name is `internal-async`, **not** `async`.
- **`backup`** — `restic/restic`, cron-driven daily database dump + file backup. See "Backups: restic" below.

`docker-compose.yml` itself has no `build:` key for `app`/`worker` — only `image: ghcr.io/jordi-adell/xivarricrm:latest`. That's deliberate: it's what lets the whole stack run from just `docker-compose.yml` + `.env` downloaded on their own, no git clone or Dockerfile required (Compose just pulls the published image). `docker-compose.override.yml` (only present if you've cloned the repo) adds `build: .` back to both services — Compose auto-merges an override file of that exact name with the base file, so a git checkout gets local builds via `docker compose up --build` while a bare download of the two files above stays pull-only. Don't move the `build:` key back into the base file; that would make the no-clone flow require a Dockerfile it doesn't have.

### Dockerfile: why it's multi-stage

Stage 1 (`builder`) installs `-dev` headers and compiles the PHP extensions SuiteCRM needs (gd, intl, mbstring, mysqli, pdo_mysql, soap, zip) via `docker-php-ext-install`, then downloads and unzips the SuiteCRM release into `/apps`. Stage 2 starts fresh from `php:8.3-apache`, installs only the matching runtime shared libs (no compilers/headers), and copies the compiled extensions plus `/apps` from the builder. This keeps the final image free of build tooling.

Apache's document root is repointed from `/var/www/html` to `/apps/public` (SuiteCRM 8's Symfony-style public folder — the app root must never be served directly). Apache is also moved from port 80 to **8888**, a deliberately non-standard port — only `caddy` should ever be found on 80/443. This isn't cosmetic, see the entrypoint section below for why it has to match `SITE_URL`'s reachability, not its literal value.

`docker inspect`/`docker compose ps` will still show `app`/`worker` as exposing both `80/tcp` *and* `8888/tcp`, even though Apache only ever listens on 8888 (verified directly: `Listen 8888` in `ports.conf`, `<VirtualHost *:8888>` in the vhost). The stray `80/tcp` is inherited `EXPOSE` metadata from the `php:8.3-apache` base image — Docker's `EXPOSE` is additive only, there's no instruction to remove a port declared by a parent image, so `EXPOSE 8888` (added right before `COPY entrypoint.sh`) makes the real port show up correctly but can't clear the stale one. Harmless either way: neither `app` nor `worker` has a `ports:` mapping in compose, so nothing is actually reachable on either port from the host regardless of what the image metadata claims.

### entrypoint.sh: the install has to happen against a *running* server

`bin/console suitecrm:app:install` performs live HTTP self-checks (`check-route-access`, GraphQL calls) against the literal `-S`/`SITE_URL` value it's given — not against Apache directly. If nothing answers at that address, those checks fail and the install silently corrupts itself — it writes a `config.php` and marks itself "installed" while still missing DB tables (this happened during initial development and is why the entrypoint logic looks the way it does). So on the `app` container only, the entrypoint:

1. Waits for the DB (`mysqli_connect` polling loop).
2. Starts a **temporary** background Apache (`apache2ctl start`) on its own port (8888), and polls `http://localhost:8888/` directly until it answers — this just confirms Apache itself is up.
3. Polls `SITE_URL` (`http://caddy` by default) until *that* answers too — this confirms the separate `caddy` container is up and successfully proxying to `app`. Both waits are necessary: step 2 alone doesn't guarantee `caddy` (a different container, started independently) is ready yet, and the installer's self-check only ever hits `SITE_URL`, never Apache directly.
4. Runs the installer, passing `SITE_URL` as `-S`.
5. Stops the temporary Apache (`apache2ctl stop`) and hands off to the real `apache2-foreground` (the Dockerfile's `CMD`), which becomes PID 1.

**`SITE_URL` no longer equals Apache's own port.** Since only `caddy` is allowed on the standard ports and `app`'s Apache lives on the non-standard 8888, `SITE_URL` has to be something reachable *through caddy* from inside the `app` container — Docker's embedded DNS resolves the service name `caddy` from any container on the same compose network, so the default is `http://caddy` (port 80 implied). Plain `http://localhost` would fail here: inside the `app` container, `localhost` is the container's own loopback, which only has Apache on 8888 — it never reaches the separate `caddy` container. Verified empirically that this doesn't leak into user-facing behavior: SuiteCRM's redirects and its GraphQL routing are relative/path-based, not built from the absolute `site_url`, so browsing through `http://localhost/` (the real, host-published address) works correctly even though the installer only ever saw `http://caddy`.

The `worker` container runs the *same* entrypoint script but never installs anything itself: it just polls for `/apps/public/legacy/config.php` to exist (written by `app`), then execs its `messenger:consume` command. Installation is owned exclusively by `app` to avoid two containers racing to install against the same fresh DB.

Idempotency for `app` itself is a simple existence check on `config.php` — a second start (restart, recreate) skips straight to serving.

### Caddy: single ingress point, automatic HTTPS

Caddy's config (a Caddyfile, not Envoy's YAML — this stack used to run Envoy here; see git history) is defined inline in `docker-compose.yml` under the top-level `configs:` key (`caddy_config`) and mounted into the container via the `caddy` service's own `configs:` entry — same "inline, no separate file" reasoning as before: the whole stack has to run from just `docker-compose.yml` + `.env`, without cloning the repo (see README's "Quick start").

The Caddyfile is two blocks:
```
{
  ${ACME_EMAIL:+email ${ACME_EMAIL}}
}

${DOMAIN:-:80} {
  reverse_proxy app:8888
}
```
Both `${...}` substitutions are resolved by **Compose itself** at parse time (the same interpolation mechanism used for `${DB_NAME}` etc. elsewhere in the file) — not by Caddy's own `{$VAR}` placeholder syntax, which doesn't support bash-style `:-`/`:+` defaults. This matters: if `DOMAIN` is unset, the site block's address becomes literally `:80`, and Caddy explicitly does not attempt ACME/HTTPS for a bare-port address — confirmed via `caddy validate`, which logs "server is listening only on the HTTP port, so no automatic HTTPS will be applied" in that case. If `DOMAIN` is set to a real hostname, Caddy both obtains a cert via HTTP-01 *and* automatically adds an HTTP→HTTPS redirect on port 80 — that redirect is Caddy's own default behavior for a domain-addressed site, not something configured explicitly here. The `${ACME_EMAIL:+email ${ACME_EMAIL}}` nested-substitution pattern (verified working via `docker compose config`) collapses to an empty global-options block when `ACME_EMAIL` is unset — an empty `{ }` block is valid Caddyfile syntax (also verified via `caddy validate`), so there's no need to conditionally omit the whole block.

Caddy owning ports 80/443 (and only Caddy) is deliberate, same as before: `app`/`db`/`worker` are all on non-standard, internal-only ports, so the host can reach nothing except through Caddy — there's no separate "firewall rule" step, the compose topology itself enforces it.

Certificates and Caddy's other on-disk state live in `/data` inside the container, backed by the `caddy_data` volume (see "Volumes" below) — this is what makes a cert survive `docker compose down`/`up` instead of being re-requested every restart (which would risk Let's Encrypt's rate limits). Renewal is entirely automatic; there's no separate cron/certbot-style service to maintain.

### Volumes: named volumes backed by host paths under `data/`

`app_data:/apps` is a named Docker volume, shared between `app` and `worker` — same files, not copies, which is how `worker` can see `config.php` without ever installing. On first mount, Docker seeds an empty named volume from the image's `/apps` content (the freshly-unzipped, not-yet-installed SuiteCRM tree); every start after that reuses whatever was written there (including the installed `config.php`), which is what makes the "skip install if already installed" check actually persist across container recreation.

`db_data`, `app_data`, `caddy_data`, and `backup_repo` are all defined with `driver: local` and `driver_opts: {type: none, o: bind, device: ${PWD}/data/db}` (respectively `.../data/app`, `.../data/caddy`, `.../data/backups`) — still named volumes as far as Docker's own bookkeeping is concerned (`docker volume ls`/`inspect` show them, `worker` and `app` still share `app_data` purely by volume name), but the backing storage is an explicit host directory next to `docker-compose.yml` instead of Docker's internal `/var/lib/docker/volumes/...`. That directory must already exist before `docker compose up` — the `local` driver's bind option does not create it — which is why `make up` runs `mkdir -p data/db data/app data/caddy`. **`data/backups` is deliberately excluded from that `mkdir -p` list** (see "Backups: restic" below for why). Editing files on the host under `data/app` **does** now reach the running container. Ownership self-heals on every start regardless: `entrypoint.sh` runs `chown -R www-data:www-data /apps` as root before handing off to Apache, and the official `mariadb` image's own entrypoint chowns its datadir the same way. Caddy runs as its own non-root user inside the container and manages `/data`'s ownership itself — no equivalent chown step needed here.

Because `docker volume create` is idempotent, switching an *existing* deployment to this config does not retroactively move already-installed data into `data/db`/`data/app`/`data/caddy` — Compose reuses the pre-existing volume as-is. Moving to the new host-backed paths on an existing install requires `docker compose down -v` (destroys the old data) followed by `docker compose up` again.

### Backups: restic

`backup` runs the official `restic/restic` image unmodified (matching the "no custom Dockerfiles" precedent set by `caddy` — see above) with its `entrypoint:` overridden to `sh /scripts/entrypoint.sh` instead of the image's own `/entrypoint.sh` wrapper. Both scripts are delivered inline via `configs:` (`backup_entrypoint`, `backup_run`), the same mechanism `caddy_config` uses, for the same reason — the whole stack has to run from just `docker-compose.yml` + `.env`.

- **`backup_entrypoint`** runs once at container start: `apk add --no-cache mariadb-client` (the base image is Alpine but doesn't ship a MySQL/MariaDB client — confirmed by inspecting the image directly), writes a crontab entry (`0 3 * * * sh /scripts/run.sh`), and execs `crond -f -d 8` as the container's foreground process. `restic/restic` already bundles `crond` (busybox), so no separate scheduler container/image is needed.
- **`backup_run`** (the actual daily job): `mariadb-dump`s the `db` service over the network into a scratch dir (no Docker socket access needed — this is why `backup` isn't given DB credentials beyond what `app`/`worker` already receive the same way), then `restic backup`s that dump plus the read-only-mounted `app_data` volume, then `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`. `caddy_data` (TLS certs) is intentionally **not** backed up — trivially re-obtainable from Let's Encrypt, not worth the storage.
- **Gotcha that would silently break every backup:** Compose's `${VAR}` interpolation runs over the *entire* compose file text, including inside `configs:` `content:` blocks — so a literal `$DB_HOST`/`$DUMP_DIR` in the script (meant to be evaluated by `sh` at container runtime) gets swallowed and replaced with an empty string by Compose itself at parse time, since those aren't real host/`.env` variables. Verified this by inspecting the actual mounted file inside a running container (`docker exec backup cat /scripts/run.sh`) — `docker compose config`'s own YAML dump is *not* trustworthy evidence here, since it doesn't clearly indicate what Compose did to the content string during interpolation. The fix is the standard Compose escape: double every `$` meant for shell runtime evaluation (`$$DB_HOST`, `$$DUMP_DIR`). This is the same class of pitfall as `caddy_config`'s `${DOMAIN}`/`${ACME_EMAIL}`, just inverted — there, the `${...}` substitutions are *supposed* to be resolved by Compose; here, they're not.
- **`restic init` idempotency**: `backup_run` checks `restic snapshots` first and only runs `restic init` if that fails — the same "check before acting" idiom as `entrypoint.sh`'s `config.php` existence check and `caddy`'s empty-vs-populated global-options block.
- **Why `data/backups` isn't auto-`mkdir`'d**: it's meant to be an NFS mount (or other off-host storage) the operator sets up *before* starting the stack, unlike `data/db`/`data/app`/`data/caddy` which are meant to be plain local directories. If it doesn't exist, `docker compose up` fails loudly (same failure mode already established for the other `driver_opts` bind volumes) rather than silently writing "backups" to a local folder that provides no protection against a disk failure.
- **`RESTIC_PASSWORD`** encrypts the repository client-side; restic refuses to run without it. There is no recovery path if it's lost — unlike `DB_PASSWORD`, which can simply be reset, losing this password makes existing backups permanently unrecoverable, so treat its `.env.example` `changeme-restic-password` placeholder as more urgent to replace (with something saved durably, e.g. a password manager) than the other `changeme-*` values.

### Esplai Xivarri branding

The `branding/` directory holds logo assets and drives a CSS recolor in the Dockerfile, both derived from https://xivarri.org/'s own site (their real CSS, not a guess): navy `#003388` (by far their dominant color) and amber `#f0bc00` as the accent, with the org's two-figure line-art icon recolored to match.

- **Logos** (`branding/logo-*.png/.svg`) are generated with ImageMagick from the icon downloaded off xivarri.org (`logo-1.png`), not committed as source — regenerate by re-running the same `convert`/`composite` steps if the org's branding changes. They're copied over SuiteCRM's default logo files by exact path in the Dockerfile (`company_logo.png`, `suitecrm_logo.png`, `p_login_logo.png/.svg`, and the sidebar/icon variants — found by `find /apps/public -iname '*logo*'` against a running container).
- **`company_logo.png` is a navy-on-white "badge," not a flat cutout.** Both the topbar logo and the centered login-page logo render from the exact same `<img src>` (confirmed via `document.querySelectorAll('img')` in a real browser) — one sits on the now-navy topbar, the other on a white background. A single flat-color asset can't read on both; the white rounded-rect backing plate is what makes it legible either way. If the org's brand colors change and this stops looking right, this is the file to revisit first.
- **`branding/favicon.ico`** is a multi-resolution icon (16/32/48px, built with `convert ... \( -clone 0 -resize NxN \) ... favicon.ico`) cropped to just the two heads from the full icon — the full tall icon reads as a blurry smear at favicon size, the cropped heads-only version reads as two circles even at 16px. It's copied over both `public/favicon.ico` and `public/dist/themes/suite8/images/favicon.ico`; only the latter is actually what `dist/index.html`'s `<link rel="icon">` points at — check that tag before assuming a different path if this ever needs to change again.
- **Colors are patched post-build with `sed`**, not sourced/recompiled from SCSS — the shipped SuiteCRM release only includes compiled, minified CSS (`public/dist/styles.*.css` and the legacy `suite8` theme CSS), no build toolchain in this image. The Dockerfile's `RUN find ... | xargs sed -i` step replaces specific hex codes (SuiteCRM's default Bootstrap-blue family, its topbar purple, and its login-button coral) with brand-equivalent shades computed to preserve the *same relative lightness* as the originals (a plain per-channel scale toward the new hue distorts color for near-black/near-white variants — see the git history for the Python luminance-blend approach used to derive the replacement table). Confirmed with a real Playwright screenshot, not just curl, since this is a visual change — CSS custom properties like `--primary-color` exist in the compiled stylesheet but are **not** actually consumed via `var()` anywhere, so overriding them does nothing; the literal hex substitution is what actually works.
- **Gotcha that cost real debugging time:** after editing the Dockerfile's color list, `docker compose build`/`up --build` sometimes kept serving a stale image under the `ghcr.io/jordi-adell/xivarricrm:latest` tag instead of the freshly built one (visually confirmed via `docker inspect <container> --format '{{.Image}}'` not matching the just-built image ID) — the underlying cause wasn't pinned down, but a plain `docker build --no-cache -t ghcr.io/jordi-adell/xivarricrm:latest .` followed by `docker compose down -v && docker compose up -d` (no `--build`) reliably produces and runs the correct image. If a CSS/branding change doesn't seem to take effect, don't trust `--build` alone — verify the running container's image ID actually matches a fresh `docker build`.
