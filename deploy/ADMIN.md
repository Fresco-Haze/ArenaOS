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

## Reset a password (manual)

There is no reset email yet. The forgot-password page only records a reset link in the api log. Users ask for a reset by emailing support@sweatlobby.com.

1. Find their user id:

    docker compose exec -T api sqlite3 /data/arenaos.db "SELECT id, username FROM users ORDER BY id;"

2. Find their link in the api log. Each line reads `[password reset] user <id> /reset-password?token=...`. Use the last line for that id:

    docker compose logs api --since 24h | grep "password reset"

3. Look up the email stored on that account (one row, no password hash):

    docker compose exec -T api sqlite3 /data/arenaos.db "SELECT email FROM users WHERE id = <id>;"

4. Send https://sweatlobby.com followed by the path from the log line (starting at /reset-password) to that stored address and nowhere else. Never send it to a different address mentioned in the request.

Rules:

- The log lines contain live reset tokens. Never paste them, or the email, into chats or tickets.
- A link works for 24 hours and then dies. Links are also lost whenever the api container is recreated (every deploy), so if you deployed since the request, ask the user to request again.
- Replying from your own mailbox shows your own address to the user. Decide that on purpose.

## Delete an account

People ask for deletion by emailing privacy@sweatlobby.com. Do it within 30 days. First confirm the request came from the email stored on the account, the same rule as a password reset. Results and the audit log stay by design: they hold ids and a placeholder name only.

You need two values from step 1: the account id and its exact username. Below they appear as <id> and <username>.

1. Find the account:

    docker compose exec -T api sqlite3 /data/arenaos.db "SELECT id, username, account_status FROM users ORDER BY id;"

2. Look first (read-only). The player row is found through the registration, not by name:

    docker compose exec -T api sqlite3 -header /data/arenaos.db "SELECT pa.player_id, pl.name FROM registrations r JOIN participants pa ON pa.id = r.participant_id JOIN players pl ON pl.id = pa.player_id WHERE r.user_id = <id>; SELECT id, name FROM players WHERE lower(name) = lower('<username>'); SELECT id, name, organizer_name FROM tournaments WHERE owner_id = <id>; SELECT id, name FROM teams WHERE owner_user_id = <id>; SELECT provider, user_id FROM user_identities WHERE user_id = <id>;"

Stop and look by hand if the second query shows a player row that the first query did not. Teams they own, and the text of tournaments they ran (name, description, rules), are not changed by the steps below: read them and edit by hand if they hold personal details.

3. Back up:

    ./backup.sh

4. The change, as one transaction. The first two statements stop everything if the id and username do not match one account:

    docker compose exec -T api sqlite3 -bail /data/arenaos.db "CREATE TEMP TABLE guard (ok INTEGER NOT NULL); INSERT INTO guard SELECT (SELECT 1 FROM users WHERE id = <id> AND username = '<username>'); BEGIN; UPDATE players SET name = 'Deleted player <id>' WHERE id IN (SELECT pa.player_id FROM registrations r JOIN participants pa ON pa.id = r.participant_id WHERE r.user_id = <id> AND pa.player_id IS NOT NULL); UPDATE tournaments SET organizer_name = 'Deleted player <id>' WHERE owner_id = <id>; UPDATE notifications SET detail = 'Deleted player <id>' WHERE kind = 'JoinRequested' AND lower(detail) = lower('<username>'); DELETE FROM notifications WHERE user_id = <id>; DELETE FROM user_avatars WHERE user_id = <id>; DELETE FROM password_resets WHERE user_id = <id>; DELETE FROM user_roles WHERE user_id = <id>; DELETE FROM user_identities WHERE user_id = <id>; DELETE FROM google_handoffs WHERE user_id = <id> OR expires_at <= CAST(strftime('%s','now') AS INTEGER) OR used_at IS NOT NULL; UPDATE users SET username = 'deleted-<id>', email = 'deleted-<id>@deleted.invalid', password_hash = 'deleted', full_name = NULL, bio = NULL, account_status = 'Deactivated' WHERE id = <id>; COMMIT;"

If it prints an error mentioning guard.ok, the id and username do not match one account and nothing was changed. Silence means it worked.

5. Restart the api so it drops cached data and ends any session (this logs everyone out), and wait for healthy:

    docker compose restart api
    docker compose ps

6. Check:

    docker compose exec -T api sqlite3 -header /data/arenaos.db "SELECT id, username, account_status FROM users WHERE id = <id>; SELECT id, name FROM players; SELECT user_id, kind, detail FROM notifications; SELECT COUNT(*) AS identities_left FROM user_identities WHERE user_id = <id>;"

The account should read deleted-<id> and Deactivated, the player row should read Deleted player <id>, and no notification should still show the old username, and identities_left should read 0. In the browser, /players should show no trace of the old name, and logging in as the old username should say wrong email, username or password.

Limits:

- The old data stays in backups until they rotate: 14 days on the server, and the offsite Backblaze copy until its own retention removes it.
- If the person was renamed after sending a join request, the old name may remain in that notification. Step 6 shows it.
- A Google sign-up that was started and never finished leaves a short-lived row holding the Google ID, email and name. The step 4 command removes expired and used rows, and so does every new Google sign-in.
- Tell the person it is done from your own mailbox, and never paste their email into chats or tickets.

## Audit log

    ./sl-admin audit-log <userId>

This shows events ABOUT that user (for example who suspended them), not events they performed. To see every event, oldest first:

    docker compose exec -T api sqlite3 -header /data/arenaos.db "SELECT * FROM audit_log ORDER BY id;"

Only the commands above are recorded. The first administrator insert and any hand-run SQL are not.

## Cancel a tournament

    ./sl-admin cancel-tournament <ownerId> <tournamentId> "reason"

The command acts as the user id you give, so use the tournament owner's id. An administrator cannot cancel someone else's tournament directly: with your own admin id the command fails with `Unauthorized NotTournamentOwner`. Use the owner's id instead. Find both ids with `./sl-admin admin-dashboard <adminId>`: each tournament line prints its `tournamentId` and `tournamentOwner = UserId {unUserId = N}`. Both behaviours were tested on a throwaway tournament on 3 November 2026: the admin id was refused, the owner id printed `Tournament cancelled.` and the state became Cancelled. Run `./backup.sh` first.

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

After a restore, the old database stays in the data volume as `arenaos.db.before-restore-<stamp>`, with `-wal` and `-shm` copies when they existed. It still holds the old accounts' personal data. Once you have checked that the site works after the restore, look at what is there and then delete it:

    docker compose exec -T api sh -c 'ls -l /data/arenaos.db*.before-restore-*'
    docker compose exec -T api sh -c 'rm /data/arenaos.db*.before-restore-*'

Only do this after the restore is confirmed good, because these files are your way back. The backup that `./backup.sh` took before the restore stays in `/var/backups/arenaos` until it rotates, and the Privacy page already says backups expire.

## Roll back to the previous version

Set `ARENAOS_TAG` in `/opt/arenaos/.env` to the previous commit id, then:

    docker compose pull
    docker compose up -d
