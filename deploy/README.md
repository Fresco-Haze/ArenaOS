# ArenaOS deployment runbook

Two images, built by GitHub Actions on every push to `main` and published to GHCR:

- `ghcr.io/fresco-haze/arenaos-api`: the Haskell backend (SQLite in the `/data` volume)
- `ghcr.io/fresco-haze/arenaos-web`: Caddy + the built frontend; proxies `/api/*` to the backend with the prefix stripped

Both are tagged `latest` and with the commit SHA. **Deploy by SHA, not `latest`**, so you can roll back.

Only Caddy publishes ports (80, 443). The api container has no published port; it is reachable only from Caddy.

## Server layout (`/opt/arenaos/`)

| File | What it is |
|---|---|
| `compose.yml` | copy of `deploy/compose.yml` |
| `.env` | `ARENAOS_TAG=<commit sha>` and `SITE_ADDRESS=<domain or :80>` |
| `backup.sh`, `restore.sh` | copies of `deploy/backup.sh`, `deploy/restore.sh` (executable) |

Backups go to `/var/backups/arenaos/`. Nothing in this directory is ever committed to git.

## Configuration

Backend (set in the image; change in `compose.yml` under `api.environment` only if you must):

| Variable | Default | Meaning |
|---|---|---|
| `ARENAOS_DB` | `arenaos-dev.db` (image: `/data/arenaos.db`) | SQLite file path |
| `PORT` | `3000` | listen port |
| `ARENAOS_HOST` | `127.0.0.1` (image: `0.0.0.0`) | bind address; `0.0.0.0` is safe only because the container has no published port |
| `ARENAOS_TRUST_PROXY` | `0` (image: `1`) | read the client IP from `X-Forwarded-For` (rightmost). Must be `1` behind Caddy, and only behind Caddy |
| `ARENAOS_TOKEN_TTL_SECONDS` | `604800` (7 days) | login token lifetime |
| `ARENAOS_RATE_LIMIT` | `on` | set `off` only for the local e2e suite |

Compose / Caddy (in `/opt/arenaos/.env`):

| Variable | Default | Meaning |
|---|---|---|
| `ARENAOS_TAG` | `latest` | image tag to run (use a commit SHA) |
| `SITE_ADDRESS` | `:80` | `:80` = plain HTTP on any host/IP; a domain name = automatic HTTPS |

Rate limits (compiled in, `api/Main.hs`): account lock after 5 failed logins (5 min); 30 failed logins per IP per 10 min; 10 registrations per IP per hour.

## First-time server setup

**Not written yet.** To be added on deploy day once a VPS exists: create a non-root `deploy` user, SSH key login only, firewall (22, 80, 443, 443/udp), Docker from the official repo, automatic security updates, and the `/opt/arenaos` layout above.

Two things the setup must include for the backup scripts to work:

```bash
sudo install -d -o deploy -m 700 /var/backups/arenaos
sudo touch /var/log/arenaos-backup.log && sudo chown deploy /var/log/arenaos-backup.log
```

## Deploy / update

```bash
cd /opt/arenaos
# set ARENAOS_TAG in .env to the commit SHA (from the green Actions run)
docker compose pull
docker compose up -d
docker compose ps          # api should become "healthy"
curl -fsS http://localhost/api/health   # {"status":"ok"} (use https://<domain> once set)
```

Update the compose file or scripts by copying the new versions from `deploy/` in the repo.

## Roll back

Set `ARENAOS_TAG` in `.env` to the previous commit SHA, then `docker compose pull && docker compose up -d`. The database is untouched by a rollback. Everyone is logged out on any restart (tokens are in memory).

## Backups

Nightly, via cron as the `deploy` user:

```
17 3 * * * /opt/arenaos/backup.sh >> /var/log/arenaos-backup.log 2>&1
```

`backup.sh` takes a consistent SQLite online backup inside the api container, runs `PRAGMA integrity_check` on the copy, gzips it (mode 600) and keeps the newest 14. Run it by hand any time: `/opt/arenaos/backup.sh`. Check the latest: `tail -n 3 /var/log/arenaos-backup.log; ls -lt /var/backups/arenaos | head`.

Backups contain emails and password hashes. Treat them as secrets. **Offsite copies: not set up yet.**

## Restore

```bash
cd /opt/arenaos
./restore.sh /var/backups/arenaos/arenaos-<stamp>.db.gz
```

It asks you to type `restore`, stops the api, moves the current database aside inside the volume (`arenaos.db.before-restore-<stamp>`, never deleted), puts the backup in place, restarts and waits for `/health`. CI runs a real backup, wipe, restore and login on every push, so the path is tested; still do one real restore on the server before relying on it.

## Troubleshooting

```bash
docker compose logs --tail=100 api     # backend errors
docker compose logs --tail=100 web     # Caddy / certificate errors
docker compose ps                      # container health
docker compose restart api
```

- **Site loads but login says "Could not reach the server":** `/api` proxy problem; check `docker compose logs web` and that api is healthy.
- **Everyone is rate limited at once:** `ARENAOS_TRUST_PROXY` is not `1`, so all clients share the proxy's IP.
- **HTTPS certificate not issued:** the domain's A record must point at the server, and ports 80/443 must be open. Caddy retries on its own; see `docker compose logs web`.
- **Pull fails with "denied":** the GHCR package must be public (GitHub profile, Packages, package settings).

## Security notes

- Never create the `organizer` / `password123` account from `seed.ps1` on a server. It is public in the repo.
- No secrets live in git. If one ever does, treat it as exposed and rotate it.
- Plain HTTP (`SITE_ADDRESS=:80`) is for testing only. Passwords are readable on the wire. Use throwaway accounts until HTTPS is on.

## Known limits

- Login tokens and rate-limit counters live in memory. A restart logs everyone out and resets the counters.
- One backend process, one SQLite file. Fine for tournaments at this scale; not horizontally scalable.
