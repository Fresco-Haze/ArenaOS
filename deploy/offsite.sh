#!/usr/bin/env bash
# Copy new local backups to encrypted offsite storage, then drop cloud copies older than 30 days.
#
#   cron (as the deploy user), 03:40 UTC every day:
#   40 3 * * * /opt/arenaos/offsite.sh >> /var/log/arenaos-backup.log 2>&1
#
# Needs the rclone remote "sl-crypt" (an encrypted view of the Backblaze B2 bucket).
# See deploy/README.md, "One-time offsite setup (rclone)".
set -euo pipefail
LOCAL=/var/backups/arenaos
REMOTE=sl-crypt:
exec 9>"$LOCAL/.offsite.lock"
flock -n 9 || { echo "offsite upload already running" >&2; exit 1; }
rclone copy "$LOCAL" "$REMOTE" --include 'arenaos-*.db.gz' --retries 3 --low-level-retries 5
rclone delete "$REMOTE" --min-age 30d --include 'arenaos-*.db.gz'
echo "offsite ok: $(rclone lsf "$REMOTE" --include 'arenaos-*.db.gz' | wc -l) backups in the cloud"
