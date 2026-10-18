#!/usr/bin/env bash
# Nightly SQLite backup for ArenaOS. Runs on the VPS host.
#
#   cron (as the deploy user), 03:17 every day:
#   17 3 * * * /opt/arenaos/backup.sh >> /var/log/arenaos-backup.log 2>&1
#
# Uses SQLite's online .backup inside the api container, so it is safe while the
# server is running (WAL or not). The copy is integrity-checked before it counts.
set -euo pipefail

: "${COMPOSE_FILE:=/opt/arenaos/compose.yml}"
: "${BACKUP_DIR:=/var/backups/arenaos}"
: "${KEEP:=14}"
export COMPOSE_FILE

umask 077
mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { echo "another backup is already running" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$BACKUP_DIR/arenaos-$stamp.db.gz"
tmp="$out.partial"
trap 'rm -f "$tmp"' EXIT

# 1. Consistent copy inside the container, then an integrity check on the copy.
docker compose exec -T api sh -c '
  set -e
  rm -f /tmp/backup.db
  sqlite3 -cmd ".timeout 5000" /data/arenaos.db ".backup /tmp/backup.db"
  [ "$(sqlite3 /tmp/backup.db "PRAGMA integrity_check;")" = "ok" ]
'

# 2. Stream it out, compress, and verify what landed on the host.
docker compose exec -T api cat /tmp/backup.db | gzip -9 > "$tmp"
docker compose exec -T api rm -f /tmp/backup.db
gzip -t "$tmp"
hdr=$(head -c 15 < <(gzip -dc "$tmp"))
[ "$hdr" = "SQLite format 3" ] || { echo "backup is not a SQLite file" >&2; exit 1; }
mv "$tmp" "$out"

# 3. Keep only the newest $KEEP backups.
mapfile -t old < <(ls -1t "$BACKUP_DIR"/arenaos-*.db.gz | tail -n +$((KEEP + 1)))
if [ "${#old[@]}" -gt 0 ]; then rm -f -- "${old[@]}"; fi

echo "backup ok: $out ($(du -h "$out" | cut -f1))"