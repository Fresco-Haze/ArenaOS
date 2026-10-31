# SweatLobby admin runbook

Admin work happens on the server over SSH. There is deliberately no public admin page, so there is no admin login for anyone to attack. Your SSH key is the access control.

Rules:

- Work as the `deploy` user in `/opt/arenaos`.
- Run `./backup.sh` before any change that writes data.
- Replace every `<...>` with a real value. Do not type the angle brackets.
- Never paste output that contains emails or password hashes into chats or tickets.

## One-time setup

Copy `sl-admin` to `/opt/arenaos`, then:

    cd /opt/arenaos
    sed -i 's/\r$//' sl-admin
    chmod +x sl-admin
    ./sl-admin list-roles 1

It should print `No roles assigned.` If the command is not found, the running image predates this tool: deploy a newer tag first.

## Look around

    ./sl-admin admin-dashboard <adminId>
    docker compose exec -T api sqlite3 /data/arenaos.db "SELECT id, username, account_status FROM users ORDER BY id;"

The second command deliberately leaves out emails and password hashes.

## Make the first administrator

Register a normal account in the browser and find its id with the SELECT above. Then:

    ./backup.sh
    docker compose exec -T api sqlite3 /data/arenaos.db "INSERT INTO user_roles (user_id, role) VALUES (<id>, 'Administrator');"
    ./sl-admin list-roles <id>

It should print Administrator. This very first grant is not in the audit log, because only the `grant-role` command writes audit entries. To add or remove administrators later:

    ./sl-admin grant-role <adminId> <userId> Administrator
    ./sl-admin revoke-role <adminId> <userId> Administrator

## Suspend or restore an account

    ./sl-admin set-account-status <adminId> <userId> Suspended
    ./sl-admin set-account-status <adminId> <userId> Active

A suspended user cannot log in. Someone who is already logged in stays logged in until their login expires (up to 7 days). To end every session now:

    docker compose restart api

This logs everyone out, not only that user.

## Audit log

    ./sl-admin audit-log <adminId>

## Cancel a tournament

    ./sl-admin cancel-tournament <ownerId> <tournamentId> "reason"

The command acts as the user id you give, so use the tournament owner's id. UNVERIFIED: whether `admin-dashboard` shows owner ids, and whether an administrator may cancel someone else's tournament directly. Check on a test tournament before relying on this.

## Remove a profile picture

First check the column name:

    docker compose exec -T api sqlite3 /data/arenaos.db ".schema user_avatars"

If the user id column is `user_id`:

    ./backup.sh
    docker compose exec -T api sqlite3 /data/arenaos.db "DELETE FROM user_avatars WHERE user_id = <id>;"

## Reset to a clean database

Keep one empty-database backup for this. Choose a backup taken before any accounts existed (about 5.7 KB) and copy it once:

    ls -l /var/backups/arenaos
    cp /var/backups/arenaos/<empty backup file> /opt/arenaos/clean-start.db.gz

To reset:

    ./backup.sh
    ./restore.sh /opt/arenaos/clean-start.db.gz

The old database is kept aside in the data volume as `arenaos.db.before-restore-<stamp>`. Warning: there are no schema migrations. If a later release adds columns to existing tables, an old empty database will not have them, so take a fresh empty backup after such a release.

## Roll back to the previous version

Set `ARENAOS_TAG` in `/opt/arenaos/.env` to the previous commit id, then:

    docker compose pull
    docker compose up -d
