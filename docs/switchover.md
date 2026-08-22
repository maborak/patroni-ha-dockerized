# Cross-Cluster Switchover Runbook (Mac ↔ Remote)

Manual procedure for swapping which Patroni cluster is the primary, between the **Mac side** (N-node Patroni in Docker — `db1..dbN`, sized by `PATRONI_REPLICAS` in `.env`) and the **Remote side** (Patroni on bare metal / VMs at `<remote-host>`). The losing side becomes a standby cluster of the winner via Patroni's `standby_cluster:` mechanism.

**Use the make target first** — the procedure below is fully scripted; this runbook is the manual fallback and explains what the script does at every step:

```bash
make switchover-to-remote    # Mac → Remote (forward)  — implements Section A
make switchover-from-remote  # Remote → Mac (reverse)  — implements Section B
# Flags (both targets): YES=1 (skip confirmations) · DRY_RUN=1 (rehearse, change
# nothing) · SKIP_BACKUP=1 (skip the pre-switchover Barman backup)
```

Backed by `scripts/ops/switchover_to_remote.sh`, `scripts/ops/switchover_from_remote.sh`, and `scripts/ops/lib/cross_cluster.sh`. All remote endpoints come from `.env` §8 (`REMOTE_*`, `MAC_VPN_HOST`) — see the glossary below.

**See also**: `docs/runbooks.md` for the intra-cluster (`patronictl switchover`) procedure. This document is specifically about cross-cluster (DR-style) role swaps.

---

## ⚠️  DATA-LOSS WARNINGS — READ BEFORE PROCEEDING ⚠️

This procedure can destroy data if executed wrong. The risks are:

1. **`patronictl pause` does NOT stop writes**, only auto-failover. App writes that land on the old primary after pause and before promote will be **silently destroyed by pg_rewind** when the old primary demotes. §A.1.5 / §B.1.5 add a hard write-block. Do not skip those steps.
2. **§A.4 / §B.4 are the POINT OF NO RETURN.** Once `standby_cluster:` is removed from the new primary's DCS and it promotes, the only way back is the full reverse procedure. Be sure before executing.
3. **`synchronous_commit` MUST be `on` (it is, per the template).** Never run this procedure with `local` / `off` / `remote_write` — those let writes commit on the primary before the standby has them, which means lag-check-equals-zero can lie. Verify with `SHOW synchronous_commit;` if you've ever tuned this.
4. **Rehearse before you cut over.** Run `make switchover-to-remote DRY_RUN=1` (or the reverse) before your first real switchover — it walks the full step sequence without touching anything. Keep a dated entry in the §F drill log for every drill and every real run, and for a first production cut-over a staging-clone dry run is still strongly recommended.
5. **NEVER `docker-compose stop` or `supervisorctl stop` Patroni mid-procedure.** If Patroni is in the middle of bootstrapping a new node from basebackup and you stop it, Patroni's bootstrap-failure handler deletes the data dir. Recover stuck Patronis with `patronictl restart cluster <scope>` instead. This rule was learned the hard way — see the project memory note about a 43 GB data loss.

### Operator setup (one-time per shell session)

```bash
# Load the postgres password and the cross-cluster vars (REMOTE_*, MAC_VPN_HOST)
# from .env into the current shell so the commands below don't hardcode anything.
set -a; source .env; set +a
export PGPASSWORD="$POSTGRES_PASSWORD"   # used by the libpq verify commands

# Sanity: confirm they loaded
[ -n "$PGPASSWORD" ] && echo "PGPASSWORD set (len=${#PGPASSWORD})" || echo "PGPASSWORD UNSET — fix before continuing"
[ -n "$REMOTE_SSH_HOST" ] && echo "REMOTE_SSH_HOST set" || echo "REMOTE_SSH_HOST UNSET — fix before continuing"
```

If you skip this step, the verify commands at A.11 / B.11 will prompt for a password, and every `$REMOTE_*` / `$MAC_VPN_HOST` reference below will be empty. The remote-side commands expand these variables **locally** before `ssh` sends the command — that's intentional, so the values never need to be hardcoded in this document.

---

## Glossary & topology

| Side | Where | Scope | etcd | PG bin | PG port | HAProxy | PgBouncer |
|---|---|---|---|---|---|---|---|
| **Mac** | Docker on `$MAC_VPN_HOST` (VPN) | `patroni1` | `etcd1/2/3` (Docker) | `/usr/lib/postgresql/15/bin` | `5431` | `:5551` write / `:5552` read | `:6432` write / `:6433` read |
| **Remote** | `<remote-host-1..N>` (bare metal / VMs) | `patroni1` | `<etcd1>`, `<etcd2>` (remote network) | `$REMOTE_PG_BIN` | `$REMOTE_PG_PORT` | `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT` write / `$REMOTE_HAPROXY_READ_PORT` read | `$REMOTE_PGBOUNCER_HOST` `:6432` write / `:6433` read |

The two scopes share the literal name `patroni1` without colliding because each side uses its OWN etcd cluster. The authoritative values for the right-hand column live in `.env` §8; any literal address in this document is an example placeholder.

**Replication slots used** (names come from `.env` §8):
- `standby_remote` (`STANDBY_REMOTE_SLOT_NAME`) — slot on the **Mac primary**, consumed by the Remote standby leader. Created automatically by Patroni when Mac was the primary. Drop manually when Mac demotes.
- `mac_standby` (`MAC_STANDBY_SLOT_NAME`) — slot on the **Remote primary**, consumed by the Mac standby leader after a forward switchover. Created manually during the switchover.

---

## Section 0 — Preflight (run before either direction)

> The `make` targets run all of these checks automatically and fail fast (see Section G). Do them manually only when driving the procedure by hand.

Verify both clusters are healthy and that lag is 0 bytes before you touch anything.

### 0.1 Mac side — current state
```bash
# Cluster topology
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
# When Mac is primary, expect: db1=Leader, db2..dbN=Replicas, all "running"
# When Mac is standby, expect: db1=Standby Leader, db2..dbN=Replicas

# Is this PG actually a primary?
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "SELECT pg_is_in_recovery();"
# Primary returns: f    Standby returns: t
```

### 0.2 Remote side — current state
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG list"

ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres \
   -c 'SELECT pg_is_in_recovery();'"
```

### 0.3 Lag must be 0 bytes
Run **on whichever side is the current primary**:
```bash
# From Mac primary, lag toward Remote standby
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c \
  "SELECT slot_name, active,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS unconfirmed
   FROM pg_replication_slots WHERE slot_name='$STANDBY_REMOTE_SLOT_NAME';"
# Expect: active=t, retained ~0, unconfirmed ~0
```

```bash
# Plus pg_stat_replication view of the standby
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c \
  "SELECT application_name, client_addr, state, sync_state,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag
   FROM pg_stat_replication;"
```

If `retained` > 0 or `replay_lag` > 0 — **STOP**. Wait for the lag to drain. Switching while lagged means data loss.

### 0.4 Confirm system_identifier matches
```bash
# Mac
docker exec db1 psql -U postgres -h localhost -p 5431 -t -A -c \
  "SELECT system_identifier FROM pg_control_system();"

# Remote (any node)
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -t -A -c \
   'SELECT system_identifier FROM pg_control_system();'"
```
Both numbers must be **identical**. If they differ, the remote was bootstrapped from a different source — DO NOT attempt switchover; you'd be replacing one universe with another.

### 0.5 Confirm WAL major version matches
Both sides MUST be the same PG major (e.g. 15). Mac runs PG 15.x in Docker; the remote typically runs a parallel source build (see `remote-standby/install-pg15-arch.md`). If anyone bumped one side without bumping the other, streaming replication will fail.
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -t -A -c "SHOW server_version;"
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -t -A -c 'SHOW server_version;'"
```

### 0.6 Confirm `synchronous_commit` is safe
The lag-check in §0.3 assumes the standby has actually persisted what the primary committed. With `synchronous_commit=off`/`local`/`remote_write`, the primary can ack a commit before WAL reaches the standby — so "lag = 0" can lie. Verify:
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -t -A -c "SHOW synchronous_commit;"
# Expect: on
```
If the value is anything but `on`, STOP. To fix it: `patronictl -c /etc/patroni/patroni.yml edit-config` and set `postgresql.parameters.synchronous_commit: on` (NOTE: `patronictl edit-config` shows flat DCS contents — `postgresql:` is a top-level key, NOT under `bootstrap.dcs:`). Save, wait a checkpoint. Or accept that you may lose recent writes — then this is not a clean switchover but a partial-data DR procedure.

### 0.7 Take a fresh Barman backup of the current primary (recommended)
Not strictly required but **strongly recommended for production**. Gives you a fallback if everything goes wrong (the `make` targets do this unless you pass `SKIP_BACKUP=1`):
```bash
# From the Mac side (when Mac is the primary)
make backup SERVER=db1

# Verify the backup
docker exec barman barman list-backup db1 | head -3
docker exec barman barman check db1
```
A successful backup means: even if both clusters end up corrupted, you can restore from this checkpoint via PITR. See `docs/pitr.md`.

### 0.8 Inventory app roles
We're about to revoke `CONNECT` from app roles (§A.1.5 / §B.1.5). List them now so the revoke step is explicit:
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -d maborak -c "
  SELECT rolname, rolcanlogin, rolsuper
  FROM pg_roles
  WHERE NOT rolname LIKE 'pg_%'
    AND rolname NOT IN ('postgres','replicator')
  ORDER BY rolname;"
```
Write down the role names you see — you'll reference them in §A.1.5 / §B.1.5. If you set `APP_ROLES="role1 role2"` in `.env`, the switchover scripts do this REVOKE/GRANT automatically.

**Optional improvement** (one-time setup): if you have many app roles and want the switchover to revoke them in a single line, create a group role and have all app roles inherit it:
```sql
CREATE ROLE app_writers NOLOGIN;
GRANT app_writers TO <app_role_1>, <app_role_2>, ...;
GRANT CONNECT ON DATABASE maborak TO app_writers;
-- (and remove direct CONNECT grants from the individual roles if desired)
```
After this, §A.1.5 step 2 becomes a single line: `REVOKE CONNECT ON DATABASE maborak FROM app_writers;`. Reduces the error surface during a high-pressure window.

---

## Section A — Switchover: Mac → Remote (forward)

**Starting state**: Mac is the primary; Remote is the standby cluster.
**Ending state**: Remote is the primary; Mac is the standby cluster.

### A.1 Stop apps from writing to Mac

Stop application services or repoint them to a maintenance page. Optional belt-and-suspenders:
```bash
docker-compose stop haproxy
# Mac's write pool (:5551) now returns connection-refused.
# Don't stop pgbouncer/pgbouncer-ro — they're harmless, and you'll want them up if you abort.
```

### A.2 Pause Mac's Patroni
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml pause patroni1

# Verify
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
# Cluster header should show "Maintenance" mode (or "Pause" depending on version)
```

Pausing disables Patroni's automatic failover. Without this, Patroni could elect a new Mac leader mid-procedure, fighting the manual changes. **Pause does NOT block writes** — that's §A.1.5's job.

### A.1.5 Hard write-block on Mac (CRITICAL — do not skip)

`pause` doesn't stop writes; apps that bypassed A.1 will still hit the leader. Without this step, any post-pause write is destroyed by pg_rewind in §A.8.

This step applies to **all user databases on the cluster** (not just `maborak`). Discover them first and confirm the list:
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -t -A -c "
  SELECT datname FROM pg_database
  WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres'
  ORDER BY datname;"
```
The `postgres` admin database is **intentionally excluded** — we keep it writable so the operator's own session (and the RESET commands in §A.4.5) can run DDL. All other user databases (e.g. `maborak`) get write-blocked.

All operations below run **from the `postgres` database** (`-d postgres`), so the operator's own session stays writable regardless of what we block.

```bash
# 1. Block writes on every non-template, non-postgres database.
#    This uses ALTER DATABASE (catalog change → WAL-replicated → travels to
#    the remote standby and stays in effect after it promotes in §A.4).
#    DO NOT use ALTER SYSTEM — that writes to postgresql.auto.conf on the
#    local filesystem and is NOT WAL-replicated, leaving remote unprotected.
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT datname FROM pg_database
              WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
      EXECUTE format('ALTER DATABASE %I SET default_transaction_read_only = on', r.datname);
      RAISE NOTICE 'Locked %', r.datname;
    END LOOP;
  END;
  \$\$;"

# 2. Revoke CONNECT from each app role on every user database.
#    Replace <app_role_1>, <app_role_2>, ... with the actual role names from §0.8.
#    DO NOT revoke from 'postgres' or 'replicator'.
#    (If you've factored your roles into a single 'app_writers' group per §0.8,
#    you can replace this with a single REVOKE on that group, per database.)
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT datname FROM pg_database
              WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
      EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM \"<app_role_1>\"', r.datname);
      EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM \"<app_role_2>\"', r.datname);
      -- ... add one line per app role from §0.8 ...
    END LOOP;
  END;
  \$\$;"

# 3. Terminate existing app sessions across all user databases
#    (so they reconnect and hit the new catalog setting AND the REVOKE).
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  SELECT datname, usename, count(*) AS killing
  FROM pg_stat_activity
  WHERE datname IS NOT NULL
    AND datname <> 'postgres'
    AND usename NOT IN ('postgres','replicator')
    AND pid <> pg_backend_pid()
  GROUP BY datname, usename;

  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname IS NOT NULL
    AND datname <> 'postgres'
    AND usename NOT IN ('postgres','replicator')
    AND pid <> pg_backend_pid();"

# 4. Verify writes are blocked on EVERY user database (loop, fail loudly if any allow writes).
for db in $(docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres';"); do
  if docker exec db1 psql -U postgres -h localhost -p 5431 -d "$db" -c \
       "CREATE TABLE writeblock_test (x int);" 2>&1 | grep -q 'read-only'; then
    echo "OK: $db is blocked"
  else
    echo "WARNING: $db is NOT blocked — investigate"
    docker exec db1 psql -U postgres -h localhost -p 5431 -d "$db" -c \
      "DROP TABLE IF EXISTS writeblock_test;" >/dev/null 2>&1
  fi
done
```

**Why this is safe** — `ALTER DATABASE ... SET param` writes to the `pg_db_role_setting` system catalog. Catalog updates generate WAL records, so the change replicates to the remote standby within milliseconds. By the time you promote remote in §A.4, its catalog already says `default_transaction_read_only = on` for every user database. Apps cannot write to remote either, even though the local `postgresql.auto.conf` on remote was never touched.

**Why `ALTER SYSTEM` would be wrong here** — PostgreSQL physical replication streams data + catalog changes, NOT configuration files. `ALTER SYSTEM` modifies `postgresql.auto.conf` on the local node's filesystem; that file is NOT shipped via WAL. If you used `ALTER SYSTEM`, only Mac would become read-only; remote would happily accept writes the moment it promotes, defeating the purpose.

**Why `postgres` database is excluded** — `ALTER DATABASE ... RESET` and `REVOKE`/`GRANT` are DDL operations that fail under a read-only session. By keeping `postgres` writable and connecting through `-d postgres`, the operator can always run the unblock commands in §A.4.5. If `postgres` were also read-only, the script would be unable to lift its own block.

### A.3 Force a checkpoint, switch WAL, then poll lag to true zero

After §A.1.5 no new writes are happening. Now make sure all existing WAL is shipped:

```bash
# 1. Force a checkpoint and a WAL switch on the current Mac primary
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  CHECKPOINT;
  SELECT pg_switch_wal();"

# 2. Poll lag until it's truly zero for 3 consecutive checks (~30 s)
for i in 1 2 3; do
  echo "--- check $i ---"
  docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
    SELECT slot_name, active,
           pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)   AS retained_bytes,
           pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS unconfirmed_bytes
    FROM pg_replication_slots WHERE slot_name='$STANDBY_REMOTE_SLOT_NAME';

    SELECT application_name, state, sync_state,
           pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
    FROM pg_stat_replication WHERE application_name='db1';"
  sleep 10
done
# All four byte values must read 0 (or very small constant — pg_replication_slots
# can show a few KB even at "caught up" because of checkpoint records).
# replay_lag_bytes MUST be 0. If it's not, STOP — apps may still be writing
# despite §A.1.5; investigate before proceeding.
```

If any value isn't dropping toward 0, **STOP**. Common causes:
- An app bypassed the REVOKE (was using a superuser role)
- Network blip between Mac and remote
- Remote PG fell behind for some reason — check `ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "systemctl status $REMOTE_PATRONI_SERVICE"`

### A.4 Promote remote — remove `standby_cluster:` from remote DCS

> 🚨 **POINT OF NO RETURN** 🚨
> Once this `edit-config` removes `standby_cluster:` and remote promotes, you cannot revert by re-adding the block. To return to "Mac is primary" you must run the full Section B in reverse. Be sure §A.1–§A.3 all completed cleanly before you proceed.
```bash
ssh -t "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG edit-config"
# -t forces TTY allocation so the interactive editor (vi/nano) opens correctly.
```
In the editor:
- `patronictl edit-config` shows the **flat DCS contents** (top-level keys are `loop_wait`, `ttl`, `postgresql`, `standby_cluster`, etc.). NOT the on-disk format with `bootstrap.dcs:` wrapping.
- Locate the **top-level** `standby_cluster:` key (sibling of `postgresql:`).
- Delete the entire block: the `standby_cluster:` key and its four children (`host:`, `port:`, `primary_slot_name:`, `create_replica_methods:`)
- Save and exit

`patronictl` writes the new config back to etcd. Within `loop_wait` (10 s) the standby leader promotes itself.

```bash
# Watch the role flip
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG list"
# Expect: the remote leader's role changes from "Standby Leader" → "Leader" (within ~30 s)

ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -t -A \
   -c 'SELECT pg_is_in_recovery();'"
# Expect: f (false — remote is now writeable)
```

If the role does not flip within 60 s, check Patroni logs:
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "journalctl -u $REMOTE_PATRONI_SERVICE -n 50 --no-pager"
```

### A.4.5 Restore app access on the new primary (remote)

The §A.1.5 catalog changes (the per-database `ALTER DATABASE` and the REVOKEs) replicated to remote BEFORE it promoted, so remote inherits both the read-only default AND the revoked CONNECT privileges across **every user database**. Apps still can't connect or write. Restore now — symmetric to §A.1.5, all from `-d postgres` (admin database stays writable):

```bash
# 1. Lift the read-only default on every user database
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"DO \\\$\\\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT datname FROM pg_database
                WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
        EXECUTE format('ALTER DATABASE %I RESET default_transaction_read_only', r.datname);
        RAISE NOTICE 'Unlocked %', r.datname;
      END LOOP;
    END;
    \\\$\\\$;\""

# 2. Re-grant CONNECT for each app role on every user database
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"DO \\\$\\\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT datname FROM pg_database
                WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO \\\"<app_role_1>\\\"', r.datname);
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO \\\"<app_role_2>\\\"', r.datname);
        -- ... one line per app role ...
      END LOOP;
    END;
    \\\$\\\$;\""

# 3. Verify writes succeed on EVERY user database
for db in $(ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
    "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -t -A -c \
     \"SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres';\""); do
  if ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT \
       -d '$db' -c \"CREATE TABLE writeunblock_test (x int); DROP TABLE writeunblock_test;\"" >/dev/null 2>&1; then
    echo "OK: $db writes succeed"
  else
    echo "WARNING: $db writes FAILED — investigate"
  fi
done
```

After §A.4.5, the new primary (remote) accepts writes from apps. The RESET and GRANT changes propagate to Mac automatically once §A.8 establishes Mac as a standby of remote — that's fine, Mac is in recovery anyway and the catalog state just matches.

### A.5 Drop the now-orphaned slot on Mac
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c \
  "SELECT pg_drop_replication_slot('$STANDBY_REMOTE_SLOT_NAME');"
# Expect: pg_drop_replication_slot row returned, no error
```

Without this, Mac would retain WAL forever for a slot nobody is reading. If you forget, you'll discover it as `pg_wal/` filling the data volume.

### A.6 Create slot on remote for Mac to consume
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"SELECT pg_create_physical_replication_slot('$MAC_STANDBY_SLOT_NAME', true);\""
# The second arg (true) marks the slot as 'immediately_reserve' so WAL is retained
# from creation time, not from first connection.
```

### A.7 Edit Mac's DCS — add `standby_cluster:` pointing at remote
```bash
docker exec -it db1 patronictl -c /etc/patroni/patroni.yml edit-config
```

> **Important**: `patronictl edit-config` shows the **flat DCS contents** — NOT the file-on-disk format with `bootstrap.dcs:` wrapping. What you see in the editor has top-level keys: `loop_wait`, `ttl`, `retry_timeout`, `postgresql`, `synchronous_mode`, etc. Add `standby_cluster:` as a **sibling top-level key**, NOT nested under `bootstrap.dcs.` (that path doesn't exist in the editor view).

In the editor (top-level position, sibling of `postgresql:` — in the flat DCS view keys appear alphabetically, so `standby_cluster:` sits between `retry_timeout:` and `synchronous_mode:`):

```yaml
# ... existing top-level keys like loop_wait, ttl, retry_timeout, postgresql, etc ...

standby_cluster:
  host: <remote-haproxy>        # $REMOTE_HAPROXY_HOST
  port: 5511                    # $REMOTE_HAPROXY_WRITE_PORT
  primary_slot_name: mac_standby
  create_replica_methods:
    - basebackup
```

Save and exit.

**About `archive_mode`**: leave it as `on`. The Mac template's `archive_command` self-gates on Patroni `Leader` role; when Mac becomes the standby_leader of a standby cluster, PostgreSQL runs in recovery mode and `archive_command` is NOT invoked (PG only invokes archive_command on a primary when `archive_mode: on`, NOT `always`). No edit needed.

### A.8 Resume Mac's Patroni
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml resume patroni1

# Watch what happens
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
# Within ~30 s: one node wins the Standby Leader election, the others become Replicas.
# Inside the Mac side, db1..dbN still cascade among themselves; only the Standby
# Leader actually opens a stream to remote at $REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT.
```

What Patroni does automatically:
1. Reads the new `standby_cluster:` block from etcd
2. Elects a Standby Leader among db1..dbN (deterministic by node priority)
3. On the elected node, reconfigures `primary_conninfo` to point at `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT`
4. **If timelines diverged**, runs `pg_rewind` first (the template has `use_pg_rewind: true` and `wal_log_hints: on`). pg_rewind will use the `superuser` credentials (the Mac template has no separate `rewind:` auth block; PG falls back to the superuser).
5. Starts the walreceiver against remote

Tail Patroni logs on the elected Standby Leader to confirm:
```bash
docker logs db1 2>&1 | tail -100 | grep -E 'rewind|standby|primary_conninfo|streaming'
```

If you see `pg_rewind` succeed → walreceiver opens → state shows "streaming", you're done with this step.

### A.9 Restart Mac's HAProxy (if you stopped it in A.1)
```bash
docker-compose start haproxy
```
Mac's write pool `:5551` will now report **all backends DOWN**. That's correct — Mac no longer has a leader. The read pool `:5552` may continue serving reads, but apps should be repointed in A.10 anyway.

### A.10 Repoint applications to remote

| App was connecting to | Repoint to |
|---|---|
| `<mac-vpn-ip>:5551` (Mac HAProxy write) | `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT` |
| `<mac-vpn-ip>:5552` (Mac HAProxy read) | `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_READ_PORT` |
| `<mac-vpn-ip>:6432` (Mac PgBouncer write) | `$REMOTE_PGBOUNCER_HOST:6432` |
| `<mac-vpn-ip>:6433` (Mac PgBouncer read) | `$REMOTE_PGBOUNCER_HOST:6433` |

`<mac-vpn-ip>` is `$MAC_VPN_HOST`. If `REMOTE_PGBOUNCER_HOST` is empty it falls back to `REMOTE_HAPROXY_HOST`.

Update env files / service configs / DNS records, then restart the apps.

### A.11 Verify end-to-end
```bash
# Write on the new primary
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d maborak -c \
   \"CREATE TABLE IF NOT EXISTS switchover_test (id serial PRIMARY KEY, ts timestamptz DEFAULT now(), note text);
     INSERT INTO switchover_test (note) VALUES ('switched mac->remote at ' || now()) RETURNING id, ts, note;\""

# Wait briefly, then read on Mac (now a standby) — same row should appear
sleep 3
docker exec db1 psql -U postgres -h localhost -p 5431 -d maborak -c \
  "SELECT id, ts, note FROM switchover_test ORDER BY id DESC LIMIT 1;"

# Verify writes work via remote PgBouncer
psql \
  -h "$REMOTE_PGBOUNCER_HOST" -p 6432 -U postgres -d maborak \
  -c "SELECT pg_is_in_recovery();"
# Expect: f

# Verify lag from remote's perspective
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"SELECT application_name, client_addr, state, sync_state,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag
     FROM pg_stat_replication;\""
```

Forward switchover complete. Log the run in §F.

---

## Section B — Switchover: Remote → Mac (reverse)

**Starting state**: Remote is the primary; Mac is the standby cluster (likely the state you reached at the end of Section A).
**Ending state**: Mac is the primary; Remote is the standby cluster.

### B.1 Stop apps from writing to remote
Stop application services or repoint to a maintenance page. Optional:
```bash
# No belt-and-suspenders equivalent needed on remote — HAProxy stays running.
# If you really want to block writes hard:
ssh "$REMOTE_SSH_USER@$REMOTE_HAPROXY_HOST" "systemctl stop haproxy"
```

### B.2 Pause Remote's Patroni
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG pause patroni1"

# Verify on any remote node
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG list"
```

Pause stops auto-failover but NOT writes — that's §B.1.5.

### B.1.5 Hard write-block on Remote (CRITICAL — do not skip)

Same rationale and mechanism as §A.1.5: catalog-level `ALTER DATABASE` (NOT `ALTER SYSTEM`) so the read-only flag replicates to Mac via WAL and stays in effect after Mac promotes in §B.4. Applies to **every user database**; `postgres` admin database stays writable so RESET / GRANT can run.

```bash
# 1. Block writes on every non-template, non-postgres database
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"DO \\\$\\\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT datname FROM pg_database
                WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
        EXECUTE format('ALTER DATABASE %I SET default_transaction_read_only = on', r.datname);
        RAISE NOTICE 'Locked %', r.datname;
      END LOOP;
    END;
    \\\$\\\$;\""

# 2. Revoke CONNECT from each app role on every user database
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"DO \\\$\\\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT datname FROM pg_database
                WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM \\\"<app_role_1>\\\"', r.datname);
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM \\\"<app_role_2>\\\"', r.datname);
        -- ... one line per app role ...
      END LOOP;
    END;
    \\\$\\\$;\""

# 3. Kill existing app sessions across all user databases
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname IS NOT NULL
       AND datname <> 'postgres'
       AND usename NOT IN ('postgres','replicator')
       AND pid <> pg_backend_pid();\""

# 4. Verify writes blocked on EVERY user database
for db in $(ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
    "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -t -A -c \
     \"SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres';\""); do
  if ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT \
       -d '$db' -c \"CREATE TABLE writeblock_test (x int);\"" 2>&1 | grep -q 'read-only'; then
    echo "OK: $db is blocked"
  else
    echo "WARNING: $db is NOT blocked"
    ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT \
      -d '$db' -c \"DROP TABLE IF EXISTS writeblock_test;\"" >/dev/null 2>&1
  fi
done
```

### B.3 Force a checkpoint, switch WAL, then poll lag to true zero

```bash
# 1. Force checkpoint + WAL switch on remote primary
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"CHECKPOINT; SELECT pg_switch_wal();\""

# 2. Poll lag for 3 consecutive checks; all values must read 0
for i in 1 2 3; do
  echo "--- check $i ---"
  ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
    "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
     \"SELECT slot_name, active,
              pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)   AS retained_bytes,
              pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS unconfirmed_bytes
       FROM pg_replication_slots WHERE slot_name='$MAC_STANDBY_SLOT_NAME';

       SELECT application_name, state, sync_state,
              pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
       FROM pg_stat_replication;\""
  sleep 10
done
# replay_lag_bytes MUST be 0. If it's not, STOP — investigate before proceeding.
```

If lag does not drain to 0, STOP. Common causes are the same as in §A.3.

### B.4 Promote Mac — remove `standby_cluster:` from Mac DCS

> 🚨 **POINT OF NO RETURN** 🚨
> After this `edit-config` removes `standby_cluster:` from Mac's DCS, Mac promotes and the only way back to "Remote is primary" is the full Section A in reverse. Confirm §B.1–§B.3 all completed cleanly first.
```bash
docker exec -it db1 patronictl -c /etc/patroni/patroni.yml edit-config
```
- `patronictl edit-config` shows the **flat DCS contents** — not the file-on-disk format with `bootstrap.dcs:` wrapping.
- Locate the **top-level** `standby_cluster:` key (sibling of `postgresql:`).
- Delete it (the key and its four children: `host`, `port`, `primary_slot_name`, `create_replica_methods`).
- Save + exit

```bash
# Watch role flip
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
# Expect: db1 changes from "Standby Leader" → "Leader" within ~30 s

docker exec db1 psql -U postgres -h localhost -p 5431 -t -A -c "SELECT pg_is_in_recovery();"
# Expect: f
```

If the flip doesn't happen, check logs:
```bash
docker logs db1 2>&1 | tail -50
```

### B.4.5 Restore app access on the new primary (Mac)

The §B.1.5 catalog changes replicated to Mac before it promoted across **every user database**. Restore now from `-d postgres` (admin database stays writable):

```bash
# 1. Lift the read-only default on every user database
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT datname FROM pg_database
              WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
      EXECUTE format('ALTER DATABASE %I RESET default_transaction_read_only', r.datname);
      RAISE NOTICE 'Unlocked %', r.datname;
    END LOOP;
  END;
  \$\$;"

# 2. Re-grant CONNECT for each app role on every user database
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c "
  DO \$\$
  DECLARE r record;
  BEGIN
    FOR r IN SELECT datname FROM pg_database
              WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' LOOP
      EXECUTE format('GRANT CONNECT ON DATABASE %I TO \"<app_role_1>\"', r.datname);
      EXECUTE format('GRANT CONNECT ON DATABASE %I TO \"<app_role_2>\"', r.datname);
      -- ... one line per app role ...
    END LOOP;
  END;
  \$\$;"

# 3. Verify writes succeed on EVERY user database
for db in $(docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres';"); do
  if docker exec db1 psql -U postgres -h localhost -p 5431 -d "$db" -c \
       "CREATE TABLE writeunblock_test (x int); DROP TABLE writeunblock_test;" >/dev/null 2>&1; then
    echo "OK: $db writes succeed"
  else
    echo "WARNING: $db writes FAILED — investigate"
  fi
done
```

### B.5 Drop the now-orphaned slot on remote
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d postgres -c \
   \"SELECT pg_drop_replication_slot('$MAC_STANDBY_SLOT_NAME');\""
```

### B.6 Create slot on Mac for remote to consume
```bash
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c \
  "SELECT pg_create_physical_replication_slot('$STANDBY_REMOTE_SLOT_NAME', true);"
```

### B.7 Edit remote DCS — add `standby_cluster:` pointing at Mac
```bash
ssh -t "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG edit-config"
# -t forces TTY allocation so the interactive editor (vi/nano) opens correctly.
```

> **Important**: `patronictl edit-config` shows the **flat DCS contents**. Top-level keys are `loop_wait`, `ttl`, `postgresql`, `synchronous_mode`, etc. — NOT `bootstrap.dcs.<keys>`. Add `standby_cluster:` as a **top-level sibling of `postgresql:`**.

```yaml
# ... existing top-level keys (loop_wait, ttl, postgresql, retry_timeout, etc.) ...

standby_cluster:
  host: <mac-vpn-ip>            # $MAC_VPN_HOST
  port: 5551                    # Mac HAProxy write port
  primary_slot_name: standby_remote
  create_replica_methods:
    - basebackup
```

(The block goes in alphabetical position among the top-level keys — between `retry_timeout:` and `synchronous_mode:`.)

Save and exit.

**About `archive_mode` on remote**: remote's local config has `archive_mode: 'off'` (set when it was bootstrapped as a standby). If you flipped it on while remote was acting as primary, flip it back to `'off'` now in the same edit so the (currently absent) archive_command can't misfire.

### B.8 Resume remote's Patroni
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG resume patroni1"

# Watch
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG list"
# Within ~30 s: one remote node wins Standby Leader election; the rest cascade
```

Tail Patroni logs on the new standby leader to confirm pg_rewind + streaming:
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "journalctl -u $REMOTE_PATRONI_SERVICE -n 100 --no-pager | grep -E 'rewind|standby|primary_conninfo|streaming'"
```

### B.9 Restart HAProxy on remote (if you stopped it in B.1)
```bash
ssh "$REMOTE_SSH_USER@$REMOTE_HAPROXY_HOST" "systemctl start haproxy"
```
The write pool (`$REMOTE_HAPROXY_WRITE_PORT`) will report all backends DOWN (correct).

### B.10 Repoint applications back to Mac

| App was connecting to | Repoint to |
|---|---|
| `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT` | `$MAC_VPN_HOST:5551` |
| `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_READ_PORT` | `$MAC_VPN_HOST:5552` |
| `$REMOTE_PGBOUNCER_HOST:6432` | `$MAC_VPN_HOST:6432` |
| `$REMOTE_PGBOUNCER_HOST:6433` | `$MAC_VPN_HOST:6433` |

### B.11 Verify end-to-end
```bash
# Write on the new primary (Mac)
docker exec db1 psql -U postgres -h localhost -p 5431 -d maborak -c \
  "INSERT INTO switchover_test (note) VALUES ('switched remote->mac at ' || now()) RETURNING id, ts, note;"

# Wait, then read on remote (now a standby)
sleep 3
ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" \
  "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d maborak -c \
   \"SELECT id, ts, note FROM switchover_test ORDER BY id DESC LIMIT 1;\""

# Verify writes via Mac PgBouncer
psql \
  -h "$MAC_VPN_HOST" -p 6432 -U postgres -d maborak \
  -c "SELECT pg_is_in_recovery();"
# Expect: f

# Verify lag from Mac's perspective
docker exec db1 psql -U postgres -h localhost -p 5431 -d postgres -c \
  "SELECT application_name, client_addr, state, sync_state,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag
   FROM pg_stat_replication;"
```

Reverse switchover complete. Log the run in §F.

---

## Section C — Rollback per step

The general rule: **the §A.4 / §B.4 `edit-config` that removes `standby_cluster:` is the point of no return.** Before that edit, you can resume the old primary and walk away. After that edit, the only way back is the full reverse procedure.

> 🚨 **NEVER `docker-compose stop` Patroni mid-procedure** 🚨
> Patroni interprets a stop during bootstrap as bootstrap-failure and **deletes the data directory** to force a clean re-bootstrap. This already cost 43 GB of data once on this project. If a node is stuck, use `patronictl restart cluster <scope>` or `patronictl reinit <scope> <node>` — both are bootstrap-safe.

> 🚨 **NEVER manually `rm` a Patroni data dir** 🚨
> Use `patronictl reinit <scope> <node>` instead. It atomically wipes + basebackups from the current leader, refusing to run on the wrong node (e.g., the current leader itself). Manual `rm` on the wrong path is irreversible.

### Aborting during Section A (Mac → Remote)

| Step that failed | What to do |
|---|---|
| A.1 (apps still writing) | Stop the apps. No DB changes have been made yet. |
| A.1.5 (write-block failed) | Investigate which app role still has write access. Don't proceed — apps will write past the lag check and lose data. |
| A.2 (pause failed) | Pause typically only fails if etcd is unreachable. Fix etcd first (`docker exec etcd1 etcdctl endpoint health`). |
| A.3 (lag won't reach 0) | Means writes are still hitting Mac. Re-audit §A.1.5. Common cause: a superuser session you forgot about. Don't proceed. |
| A.4 (remote promote failed) | `ssh -t "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG edit-config"` and restore the original `standby_cluster:` block. Then **restore app access on Mac** by running the §A.4.5 DO blocks (loop over all user databases). Resume Mac Patroni (A.8 step). You're back to start. |
| A.4.5 (grant restore failed) | Apps are blocked. Re-run the §A.4.5 DO blocks (RESET + GRANT loop over all user databases) on remote. Cluster is in correct state otherwise. |
| A.5 (slot drop failed) | Almost always means the slot is still active. That can't happen if A.4 succeeded — investigate why a consumer is still attached (`SELECT * FROM pg_replication_slots; SELECT * FROM pg_stat_replication;`). |
| A.6 (slot create failed) | Slot name collision: `SELECT slot_name FROM pg_replication_slots` on remote. Drop the stale slot if present. |
| A.7 (Mac DCS edit failed) | If you saved bad YAML, re-open and fix. If patronictl refuses, check `docker logs db1` for the parse error. Until you save successfully, nothing has changed on Mac DCS. |
| A.8 (resume + pg_rewind failed) | Read Patroni logs (`docker logs dbN`). Two common modes: **(a)** `target server needs to be shut down cleanly` → Mac PG hadn't fully checkpointed. Recovery: `docker exec dbN supervisorctl restart patroni` (NOT `docker-compose stop`). **(b)** `no common timeline` → the timelines diverged beyond pg_rewind's ability. Recovery: `docker exec db1 patronictl -c /etc/patroni/patroni.yml reinit patroni1 dbN`. Patroni handles the wipe + basebackup atomically; refuses to run on the current leader. Slow (hours over VPN) but bootstrap-safe. |

### Aborting during Section B (Remote → Mac)

| Step that failed | What to do |
|---|---|
| B.1, B.1.5, B.2, B.3 | Symmetric to A.1/A.1.5/A.2/A.3 with Mac/Remote swapped. |
| B.4 (Mac promote failed) | `docker exec -it db1 patronictl -c /etc/patroni/patroni.yml edit-config` and restore `standby_cluster:`. Restore app access on remote (RESET + GRANT). Resume Remote Patroni. Back to post-Section-A state. |
| B.4.5 (grant restore failed) | Apps blocked on Mac. Re-run RESET + GRANT on Mac (`docker exec db1 psql ...`). |
| B.5–B.7 | Symmetric to A.5–A.7. |
| B.8 (remote resume + pg_rewind failed) | Symmetric to A.8. Use `ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG reinit patroni1 db2"` (or any replica). **DO NOT** manually `rm` the remote PG data dir — use reinit. |

---

## Section D — Endpoint reference card

Pin this to the wall. All values resolve from `.env` §8; if `REMOTE_PGBOUNCER_HOST` is empty it defaults to `REMOTE_HAPROXY_HOST`.

| Use case | Mac is Primary | Remote is Primary |
|---|---|---|
| App writes (HAProxy) | `$MAC_VPN_HOST:5551` | `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_WRITE_PORT` |
| App reads (HAProxy) | `$MAC_VPN_HOST:5552` | `$REMOTE_HAPROXY_HOST:$REMOTE_HAPROXY_READ_PORT` |
| App writes (PgBouncer) | `$MAC_VPN_HOST:6432` | `$REMOTE_PGBOUNCER_HOST:6432` |
| App reads (PgBouncer) | `$MAC_VPN_HOST:6433` | `$REMOTE_PGBOUNCER_HOST:6433` |
| Operator psql (write, direct) | `docker exec db1 psql ... -p 5431` | `ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT ..."` |
| Operator cluster status | `docker exec db1 patronictl -c /etc/patroni/patroni.yml list` | `ssh "$REMOTE_SSH_USER@$REMOTE_SSH_HOST" "patronictl -c $REMOTE_PATRONI_CONFIG list"` |

---

## Section E — Pre-existing operational guidance

**Do not run these procedures during:**
- Active backups (Barman or `make backup`) — the WAL stream is in use
- Long-running transactions on the current primary — they may abort
- Schema migrations
- Any period when lag is non-zero

**Do not assume `pg_rewind` will always work:**
- If `wal_log_hints: on` was ever flipped off on the new primary, divergent WAL records have no hint bits and pg_rewind can't rebuild them. Both sides' templates have `wal_log_hints: on` — verify with `SHOW wal_log_hints;` if you're suspicious.
- If timelines diverged more than `wal_keep_size` ago, pg_rewind will fail and you need a full basebackup.

**Do not edit YAML in the live config files directly** (`/etc/patroni/patroni.yml` inside the container, or `$REMOTE_PATRONI_CONFIG` on remote). Those are bootstrap-only — once Patroni is running, the live config lives in etcd and you edit it with `patronictl edit-config`. File edits are silently ignored until the next bootstrap.

**Do not skip the slot create/drop steps (A.5/A.6, B.5/B.6).** A forgotten slot on the demoted primary will fill the data volume; a missing slot on the new primary means the new standby has no WAL retention guarantee.

**Do not skip §A.1.5 / §B.1.5 (hard write-block).** `patronictl pause` does NOT block writes — it only disables auto-failover. Any write that lands on the old primary after pause and before promote is silently destroyed by pg_rewind. The default_transaction_read_only + REVOKE CONNECT combo in §A.1.5/§B.1.5 is the only thing that actually stops writes.

**Do not run with `synchronous_commit` weaker than `on`.** With `local`/`off`/`remote_write`, the primary acks writes before the standby has them, so "lag = 0" can lie. Verified in §0.6.

**Never `docker-compose stop` or `supervisorctl stop` Patroni mid-procedure.** Patroni's bootstrap-failure handler deletes data dirs. Use `patronictl restart cluster <scope>` or `patronictl reinit <scope> <node>` instead — both are bootstrap-safe.

---

## Section F — Switchover drill log

Keep a dated entry for every switchover you run — real or rehearsal — so the next operator knows what's been exercised. The scripted paths rehearse their full step sequence with `DRY_RUN=1` without touching data; run one before your first real switchover and record both here. (The scripts remind you to update this table at the end of a run.)

| Date | Direction | Mode (real / `DRY_RUN=1` drill) | Operator | Wall-clock | Notes |
|---|---|---|---|---|---|
| | | | | | |

---

## Section G — Automation Reference

Everything above is automated. Prefer the make targets; this runbook doubles as the step-by-step explanation of what they do.

- `make switchover-to-remote` → runs `scripts/ops/switchover_to_remote.sh` (Section A)
- `make switchover-from-remote` → runs `scripts/ops/switchover_from_remote.sh` (Section B)
- Shared helpers (PSQL wrappers, DCS get/put, write-block/unblock, slot management): `scripts/ops/lib/cross_cluster.sh`
- Flags: `YES=1` (skip interactive confirmation) · `DRY_RUN=1` (print every action, change nothing) · `SKIP_BACKUP=1` (skip the pre-switchover Barman backup)
- App-role handling: set `APP_ROLES="role1 role2"` in `.env` and the REVOKE/GRANT steps (§A.1.5 / §A.4.5) run over that list automatically — no per-role SQL editing. The `app_writers` group trick from §0.8 remains an option.

**Preflights the script runs before touching anything** (all fail-fast, implemented in `cross_cluster.sh` — the manual §0 equivalents):

- **system_identifier match** between Mac and Remote (`preflight_identity`) — refuses if the clusters were bootstrapped from different sources (§0.4)
- **PG major version match** on both sides (`preflight_pg_version`) (§0.5)
- **`synchronous_commit` gate** — aborts unless every node reports `on` (`preflight_sync_commit`) (§0.6)
- **Direction auto-detect** via `pg_is_in_recovery()` on both sides — refuses to run the wrong-direction script (§0.1/§0.2)
- **Lag polling to true zero** with retry/timeout before the point of no return (`wait_for_zero_lag`) (§0.3, §A.3/§B.3)
- Slot health checks, non-interactive DCS `standby_cluster` add/remove via the Patroni API, and post-promote role-flip confirmation (`wait_for_role`)
