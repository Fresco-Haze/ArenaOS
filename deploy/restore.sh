#!/usr/bin/env bash
# Restore an ArenaOS backup:  restore.sh [-y] /var/backups/arenaos/arenaos-<stamp>.db.gz
# The current database is never deleted: it is moved aside inside the data volume
# as arenaos.db.before-restore-<stamp> (plus -wal / -shm if present).
set -euo pipefail

: "${COMPOSE_FILE:=/opt/arenaos/compose.yml}"
export COMPOSE_FILE

yes=0
if [ "${1:-}" = "-y" ]; then yes=1; shift; fi
file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "usage: restore.sh [-y] BACKUP.db.gz" >&2
  exit 2
fi
gzip -t "$file"

if [ "$yes" -ne 1 ]; then
  echo "This replaces the live database with: $file"
  echo "The current database is kept aside in the data volume (arenaos.db.before-restore-*)."
  read -r -p "Type 'restore' to continue: " ans
  [ "$ans" = "restore" ] || { echo "aborted"; exit 1; }
fi

echo "stopping api..."
docker compose stop api
trap 'echo "restore failed; restarting api with the existing database" >&2; docker compose up -d api' ERR

echo "restoring..."
gzip -dc "$file" | docker compose run --rm --no-deps -T --entrypoint sh api -c '
  set -e
  trap "rm -f /data/.restore.tmp" EXIT
  cat > /data/.restore.tmp
  [ "$(sqlite3 /data/.restore.tmp "PRAGMA integrity_check;")" = "ok" ]
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  for s in "" -wal -shm; do
    if [ -f "/data/arenaos.db$s" ]; then mv "/data/arenaos.db$s" "/data/arenaos.db$s.before-restore-$ts"; fi
  done
  mv /data/.restore.tmp /data/arenaos.db
'

trap - ERR
echo "starting api..."
docker compose up -d --wait --wait-timeout 120 api
echo "restore complete: api is healthy"