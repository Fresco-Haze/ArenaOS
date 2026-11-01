# SweatLobby deployment runbook

Two images, built by GitHub Actions on every push to `main` and published to GHCR:

- `ghcr.io/fresco-haze/arenaos-api`: the Haskell backend (SQLite in the `/data` volume). It also contains the `arenaos` admin command-line program.
- `ghcr.io/fresco-haze/arenaos-web`: Caddy plus the built frontend. It proxies `/api/*` to the backend with the prefix stripped.

The product was renamed from ArenaOS to SweatLobby in October 2026. Internal names (the image and package names above, the `arenaos` executables, the `ARENAOS_*` environment variables, the `/opt/arenaos` folder) are unchanged on purpose.

Both images are tagged `latest` and with the full commit SHA. **Deploy by SHA, not `latest`**, so you can roll back.

Only Caddy publishes ports (80, 443/tcp, 443/udp). The api container has no published port; it is reachable only from Caddy.

## Where it runs

| Piece | What it is |
|---|---|
| Server | Vultr Cloud Compute, shared CPU, 2 GB RAM (plan `vc2-1c-2gb`), Johannesburg, Ubuntu 24.04 LTS. About $10 a month, billed hourly. Destroying the server stops billing; stopping it does not. |
| Domain | `sweatlobby.com`, registered at Porkbun (yearly, auto-renew on). |
| DNS | Porkbun DNS. `A` records for the bare name and `www` point at the server's IP. Porkbun's default parking `ALIAS` and wildcard `CNAME` records were deleted. |
| HTTPS | Caddy gets and renews Let's Encrypt certificates for the names in `SITE_ADDRESS`. |
| Offsite backups | Backblaze B2 private bucket, encrypted with rclone before upload. |

Turn on two-factor login for the Vultr, Porkbun, Backblaze and GitHub accounts. Whoever controls those accounts controls the site, the name, the backups and the code.

## Server layout (`/opt/arenaos/`)

| File | What it is |
|---|---|
| `compose.yml` | copy of `deploy/compose.yml` |
| `.env` | `ARENAOS_TAG=<full commit sha>` and `SITE_ADDRESS=<domain names, or :80>` |
| `backup.sh`, `restore.sh` | copies of `deploy/backup.sh`, `deploy/restore.sh` (executable) |
| `offsite.sh` | copy of `deploy/offsite.sh` (executable) |
| `sl-admin` | copy of `deploy/sl-admin` (executable); see `ADMIN.md` |
| `ADMIN.md` | copy of `deploy/ADMIN.md` |

Backups go to `/var/backups/arenaos/`. Nothing in these folders is ever committed to git.

Example `.env`:

```
ARENAOS_TAG=<full 40-character commit sha>
SITE_ADDRESS="sweatlobby.com, www.sweatlobby.com"
```

Files copied from a Windows checkout may carry Windows line endings, which break shell scripts. After copying, run `sed -i 's/\r$//' <file>` on each script.

## Configuration

Backend (set in the image; change in `compose.yml` under `api.environment` only if you must):

| Variable | Default | Meaning |
|---|---|---|
| `ARENAOS_DB` | `arenaos-dev.db` (image: `/data/arenaos.db`) | SQLite file path. The `arenaos` admin program reads it too. |
| `PORT` | `3000` | listen port |
| `ARENAOS_HOST` | `127.0.0.1` (image: `0.0.0.0`) | bind address; `0.0.0.0` is safe only because the container has no published port |
| `ARENAOS_TRUST_PROXY` | `0` (image: `1`) | read the client IP from `X-Forwarded-For` (rightmost). Must be `1` behind Caddy, and only behind Caddy |
| `ARENAOS_TOKEN_TTL_SECONDS` | `604800` (7 days) | login token lifetime |
| `ARENAOS_RATE_LIMIT` | `on` | set `off` only for the local e2e suite |

Compose / Caddy (in `/opt/arenaos/.env`):

| Variable | Default | Meaning |
|---|---|---|
| `ARENAOS_TAG` | `latest` | image tag to run (use a full commit SHA) |
| `SITE_ADDRESS` | `:80` | `:80` = plain HTTP on any host or IP; one or more domain names = automatic HTTPS |

Rate limits (compiled in, `api/Main.hs`):

- Login: account lock after 5 failed logins (5 minutes); 30 failed logins per IP per 10 minutes.
- Registration: 10 per IP per hour.
- Password change (Settings): 5 wrong current passwords in 15 minutes lock that user's password changes for 5 minutes.

## First-time server setup

1. **Create the server** in Vultr as in the table above. First add your SSH public key on Vultr's SSH Keys page and tick it when deploying. Protect the key with a passphrase and write the passphrase down offline. A forgotten passphrase cannot be recovered: you would make a new key and reinstall the server.
2. **Copy the bootstrap script** from your PC and run it as root. Replace `<key>` and `<ip>`:

   ```
   scp -i <key> -o IdentitiesOnly=yes deploy/bootstrap.sh root@<ip>:/root/bootstrap.sh
   ssh -i <key> -o IdentitiesOnly=yes root@<ip>
   ```

   Then on the server:

   ```
   sed -i 's/\r$//' bootstrap.sh
   bash bootstrap.sh
   ```

   Part 1 creates the `deploy` user (your key is copied to it), turns on the firewall (22, 80, 443/tcp, 443/udp only), turns on automatic security updates, installs Docker, adds a swap file if none exists, and creates `/opt/arenaos`, `/var/backups/arenaos` and the backup log. It does not change SSH login rules, so you cannot lock yourself out.
3. **Prove the deploy login** in a second window: log in as `deploy`, then run `sudo whoami` (must print `root`) and `docker ps` (must not error).
4. **Lock SSH**, back in the first window: `bash bootstrap.sh lock-ssh`, then type `yes`. Root login and password login over SSH are now off. If you ever lock yourself out, use Vultr dashboard, your server, View Console.
5. **Install pending updates and reboot** (kernel updates need it): `sudo apt-get update && sudo apt-get -y full-upgrade && sudo reboot`.

The `deploy` user has passwordless `sudo` and is in the `docker` group. Both are effectively root, so the SSH key is the real secret.

## First deploy (plain HTTP, by IP)

Use throwaway accounts only. Plain HTTP sends passwords readable. Never create the `organizer` / `password123` account from `seed.ps1` on a server.

1. Copy `compose.yml`, `backup.sh`, `restore.sh`, `offsite.sh`, `sl-admin` and `ADMIN.md` from `deploy/` to `/opt/arenaos` with `scp`, then on the server:

   ```
   cd /opt/arenaos
   sed -i 's/\r$//' compose.yml backup.sh restore.sh offsite.sh sl-admin
   chmod +x backup.sh restore.sh offsite.sh sl-admin
   printf 'ARENAOS_TAG=<full 40-character commit sha>\nSITE_ADDRESS=:80\n' > .env
   docker compose pull
   docker compose up -d
   ```

2. Check `docker compose ps` (api must be `healthy`) and `curl -fsS http://localhost/api/health` (prints `{"status":"ok"}`). The api log should contain `facts warmed`.

## DNS and HTTPS

1. In Porkbun DNS for the domain, delete the default parking records (an `ALIAS` and a wildcard `CNAME` that mention `uixie.porkbun.com`). Leave the email-forwarding `MX` and `TXT` records alone.
2. Add two `A` records, TTL 600, both pointing at the server's IP: host empty (the bare name) and host `www`.
3. Check from any machine: `nslookup sweatlobby.com 1.1.1.1` and `nslookup www.sweatlobby.com 1.1.1.1` must both answer the server's IP. Wait until they do.
4. On the server, set the names and restart so Caddy fetches certificates:

   ```
   cd /opt/arenaos
   sed -i 's|^SITE_ADDRESS=.*|SITE_ADDRESS="sweatlobby.com, www.sweatlobby.com"|' .env
   cat .env
   docker compose up -d
   sleep 25
   docker compose logs --tail=40 web
   ```

   The log must say `certificate obtained successfully` for both names. Do not restart again and again if it fails: Let's Encrypt limits repeated failures. Fix the cause first (DNS not ready, port 80 or 443 blocked).
5. `curl -sI https://sweatlobby.com | head -n 3` must start with `HTTP/2 200`. From now on the site answers only on the domain names, not on the bare IP.

## Deploy / update

Wait for the GitHub Actions `images` run for the commit to go green. Then, on the server, inside `/opt/arenaos` (check with `pwd`; commands run elsewhere do nothing useful):

```
cd /opt/arenaos
NEW=$(curl -fsS https://api.github.com/repos/Fresco-Haze/ArenaOS/commits/<short sha> | grep -m1 '"sha"' | cut -d'"' -f4)
echo "${#NEW} characters"
```

It must print `40 characters`. (A harmless `curl: (23) Failure writing output` line can appear.) Then:

```
sed -i "s/^ARENAOS_TAG=.*/ARENAOS_TAG=$NEW/" .env
cat .env
docker compose pull
docker compose up -d
sleep 20
docker compose ps
curl -fsS https://sweatlobby.com/api/health
```

`api` must be `healthy` and the last command must print `{"status":"ok"}`. Everyone is logged out on any restart, because login tokens are in memory.

Update the compose file or scripts by copying the new versions from `deploy/` in the repo, then strip Windows line endings as above.

## Roll back

Set `ARENAOS_TAG` in `.env` to the previous full commit SHA, then `docker compose pull && docker compose up -d`. The database is untouched by a rollback.

## Backups

Two layers, both from cron as the `deploy` user (the server clock is UTC; 03:17 UTC is 06:17 in Nairobi):

```
17 3 * * * /opt/arenaos/backup.sh >> /var/log/arenaos-backup.log 2>&1
40 3 * * * /opt/arenaos/offsite.sh >> /var/log/arenaos-backup.log 2>&1
```

- `backup.sh` takes a consistent SQLite online backup inside the api container, runs `PRAGMA integrity_check` on the copy, gzips it (mode 600) and keeps the newest 14 in `/var/backups/arenaos`. Run it by hand any time: `/opt/arenaos/backup.sh`.
- `offsite.sh` copies new backups to the encrypted Backblaze remote and deletes cloud copies older than 30 days.
- Check the latest runs: `tail -n 4 /var/log/arenaos-backup.log` should show a `backup ok:` line and an `offsite ok:` line dated the same day.

Backups contain emails and password hashes. Treat them as secrets.

### One-time offsite setup (rclone)

1. In Backblaze B2, create a **private** bucket and an **application key restricted to that bucket** with read and write access. Copy the `keyID` and `applicationKey` straight into a password manager; the key is shown only once.
2. On the server, as `deploy`:

   ```
   sudo apt-get install -y rclone
   ```

3. Enter the key without it landing in shell history. Run these lines **one at a time**, pressing Enter after each (a pasted block feeds the later lines to the first prompt):

   ```
   read -r -p "B2 keyID: " B2ID
   read -r -s -p "B2 applicationKey (hidden): " B2KEY; echo
   rclone config create sl-b2 b2 account="$B2ID" key="$B2KEY" >/dev/null
   unset B2ID B2KEY
   ```

4. Create the encryption layer. The first block prints two secrets: **write both down offline right now**, before running the second block.

   ```
   P1=$(openssl rand -base64 24)
   P2=$(openssl rand -base64 24)
   echo "PASSWORD: $P1"
   echo "SALT:     $P2"
   ```

   ```
   rclone config create sl-crypt crypt remote=sl-b2:<your-bucket>/enc password="$P1" password2="$P2" --obscure >/dev/null
   unset P1 P2
   clear
   ```

5. Test, then run the script once by hand and add the cron line above:

   ```
   echo "encrypted hello" > /tmp/enc-test.txt
   rclone copyto /tmp/enc-test.txt sl-crypt:enc-test.txt
   rclone ls sl-crypt:
   rclone ls sl-b2:<your-bucket>/enc
   rclone deletefile sl-crypt:enc-test.txt
   rm /tmp/enc-test.txt
   /opt/arenaos/offsite.sh
   ```

   The first listing shows a readable name. The second shows a scrambled name: that is the encryption working.

**The crypt password and salt are the only way to read the offsite backups.** Keep them offline, away from the server. If you lose both, every offsite backup is unreadable. The B2 key lives in `~/.config/rclone/rclone.conf` on the server (readable only by `deploy`).

### Restore from a local backup

```
cd /opt/arenaos
./restore.sh /var/backups/arenaos/arenaos-<stamp>.db.gz
```

It asks you to type `restore`, stops the api, moves the current database aside inside the volume (`arenaos.db.before-restore-<stamp>`, never deleted), puts the backup in place, restarts and waits for `/health`. Everyone is logged out afterwards. To restore the newest backup without typing a file name: `./restore.sh "$(ls -t /var/backups/arenaos/arenaos-*.db.gz | head -n 1)"`.

This path was drilled on the live server (an account created before the backup survived; one created after it disappeared), and CI runs a backup, wipe, restore and login on every push.

### Check or restore from the cloud copy

This downloads the newest cloud backup, decrypts it and checks it. It prints only a file name, `ok` and a count:

```
mkdir -p /tmp/cloudtest && cd /tmp/cloudtest
f=$(rclone lsf sl-crypt: --include 'arenaos-*.db.gz' | sort | tail -n 1)
echo "newest in cloud: $f"
rclone copy "sl-crypt:$f" /tmp/cloudtest
gzip -t "$f" && gzip -dc "$f" > test.db
sqlite3 test.db "PRAGMA integrity_check;"
sqlite3 test.db "SELECT COUNT(*) FROM users;"
cd ~ && rm -rf /tmp/cloudtest
```

To restore from it, copy the downloaded `.db.gz` into `/var/backups/arenaos` and use `restore.sh` as above.

**Not yet tested:** rebuilding on a brand-new machine after losing the server. The steps would be: install rclone, recreate the `sl-b2` remote with a B2 key, recreate `sl-crypt` with the same bucket path and the **same password and salt**, then list and copy a backup. Test this once on a spare machine before you rely on it.

## Admin work

Done on the server over SSH, with no public admin page. See `ADMIN.md` (suspend and restore accounts, the audit log, the first administrator, resetting to a clean database).

## Troubleshooting

```
docker compose logs --tail=100 api     # backend errors
docker compose logs --tail=100 web     # Caddy / certificate errors
docker compose ps                      # container health
docker compose restart api
```

- **`no configuration file provided: not found`**, or `.env` not found: you are not in `/opt/arenaos`. Run `cd /opt/arenaos`.
- **Commands print Windows-style errors (`cd : Cannot find path`):** the SSH session had dropped and you typed into your own PC. Check that the prompt says `deploy@sweatlobby` before pasting server commands. A line `client_loop: send disconnect` means the session dropped; log in again.
- **`Permission denied (publickey)`:** wrong key file (use `-i <key> -o IdentitiesOnly=yes`), or the key's passphrase is wrong. A lost passphrase cannot be recovered; make a new key and reinstall the server's SSH keys from Vultr.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED`:** expected after reinstalling the server. Run `ssh-keygen -R <ip>` on your PC and connect again.
- **Site loads but login says "Could not reach the server":** `/api` proxy problem; check `docker compose logs web` and that api is healthy.
- **Everyone is rate limited at once:** `ARENAOS_TRUST_PROXY` is not `1`, so all clients share the proxy's IP.
- **HTTPS certificate not issued:** the domain's `A` records must point at the server and ports 80 and 443 must be open. Caddy retries on its own; see `docker compose logs web`.
- **Pull fails with "denied":** the GHCR package must be public (GitHub profile, Packages, package settings).
- **Locked out of SSH:** Vultr dashboard, your server, View Console.

## Security notes

- Never create the `organizer` / `password123` account from `seed.ps1` on a server. It is public in the repo.
- No secrets live in git. If one ever does, treat it as exposed and rotate it.
- Plain HTTP (`SITE_ADDRESS=:80`) is for testing only. Use throwaway accounts until HTTPS is on.
- SSH accepts keys only; root login is off. The firewall allows only 22, 80, 443/tcp and 443/udp.
- Docker can publish ports around the firewall. Keep the api container without a published port.
- Keep the SSH private key, its passphrase, the Backblaze key and the crypt password and salt out of git and out of chats.

## Known limits

- Login tokens and rate-limit counters live in memory. A restart logs everyone out and resets the counters.
- Suspending an account stops new logins but does not end a session that already exists (up to 7 days). `docker compose restart api` ends every session.
- There are no database migrations. A new release that adds columns to existing tables will not work with an old empty database; take a fresh empty backup after such a release.
- One backend process and one SQLite file. Fine for tournaments at this scale; not horizontally scalable.
- The admin command-line program trusts whatever user id you pass it. Its only protection is that running it requires SSH to the server.

## Costs

About $10 a month for the server and about $11 a year for the domain. GitHub Actions, GHCR and Let's Encrypt are free here. Backblaze B2's free tier should cover the backups, which are a few kilobytes each; check its current limits before relying on that.
