# perform_pitr.sh - Reference

**File**: `scripts/pitr/perform_pitr.sh`

Automated Point-In-Time Recovery with Backup, with full Patroni integration: backup verification, WAL validation, recovery file creation, node isolation, recovery application, and optional cluster reintegration.

For recovery scenarios, WAL method comparison, and troubleshooting, see [docs/pitr.md](../pitr.md) — this document focuses on the script's interface and behavior.

---

## Table of Contents

1. [Entry Points](#entry-points)
2. [Synopsis](#synopsis)
3. [Interactive Mode](#interactive-mode)
4. [Remote PITR (ssh:// target)](#remote-pitr-sshtarget)
5. [Options Detail](#options-detail)
6. [Environment Variables](#environment-variables)
7. [Expected Output](#expected-output)
8. [Post-Restore Verification SQL Checklist](#post-restore-verification-sql-checklist)
9. [Integration with Patroni](#integration-with-patroni)
10. [Safety Notes](#safety-notes)
11. [Performance Notes](#performance-notes)
12. [Error Recovery](#error-recovery)

---

## Entry Points

### `make pitr` (recommended)

```bash
# No arguments → interactive wizard
make pitr

# Full arguments → direct execution
make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' \
  SERVER=db1 TARGET=db2 RESTORE=1 AUTO_START=1

# Partial arguments → usage help is printed
```

Make variables map to script flags: `SERVER=` → `--server`, `TARGET=` → `--target`, `RESTORE=1` → `--restore`, `AUTO_START=1` → `--auto-start`, `WAL_METHOD=` → `--wal-method`.

### Direct invocation

```bash
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> [OPTIONS]
```

---

## Synopsis

### Positional Arguments

| Argument | Required | Description | Example |
|----------|----------|-------------|---------|
| `<backup-id>` | ✅ Yes | Backup backup identifier (`YYYYMMDDTHHMMSS`) | `20260123T120000` |
| `<target-time>` | ✅ Yes | Recovery target time or `latest` | `'2026-01-23 12:30:00'` or `latest` |

### Options

| Option | Argument | Default | Description |
|--------|----------|---------|-------------|
| `--server` | `<server>` | Auto-detect | Backup server name (db1..dbN); checks all servers if omitted |
| `--target` | `<node>` | None | Target node (db1..dbN) for automated application |
| `--target` | `ssh://user@host[:port]/path` | None | Remote PITR mode (see below) |
| `--restore` | None | `false` | Start PostgreSQL recovery automatically |
| `--wal-method` | `<method>` | `backup-wal-restore` | WAL fetch method: `backup-wal-restore` or `backup-get-wal` |
| `--auto-start` | None | `false` | Auto-start, monitor recovery, promote, and reintegrate cluster |

Both space form (`--server db1`) and equals form (`--server=db1`) are accepted. Unknown flags are rejected with an error.

### Target Time Rules

- Must be **after** backup end time (script validates)
- Must be **before or equal to** last archived WAL time
- `latest` recovers to the most recent available WAL and skips target time validation

---

## Interactive Mode

Run with no arguments (e.g., `make pitr`) for a step-by-step wizard. Requires a terminal; with piped stdin it aborts unless `PITR_ALLOW_PIPED=1` is set (testing escape hatch used by the smoke tests).

Wizard steps:

1. **Select backup** — lists backups from all servers; enter `r` to re-scan for new backups, `q` to quit.
2. **Select target node** — choose from db1..dbN.
3. **Select WAL method** — `backup-wal-restore` (recommended, default on Enter) or `backup-get-wal`.
4. **Enter target time** — Enter for `latest`, or a `'YYYY-MM-DD HH:MM:SS'` timestamp.
5. **Summary + confirm** — shows backup server, backup ID, target node, WAL method, target time; asks `Start PITR? (y/N)`.

On confirmation, the wizard runs with `--restore --auto-start` semantics: it applies recovery to the selected node, promotes it, and reinitializes the other replicas.

---

## Remote PITR (ssh://target)

Ship the recovered `PGDATA` to a **non-cluster host** instead of applying it locally:

```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest \
  --target ssh://postgres@db.example.com:2222/var/lib/postgresql/15/main
```

Behavior:

- Pre-flights SSH connectivity and required tools (`tar`, `rsync`) on the remote; picks the best compressor available on both ends (zstd > pigz > gzip > none).
- Transfers in three phases: compress in the backup container → resumable `rsync --partial --append-verify` to the remote → decompress and unpack into the target path (wiping any existing contents there, after showing them and asking for confirmation).
- Verifies extracted byte size against the source, then cleans up all staging artifacts.
- Prints **next steps** to run on the remote host: stop PostgreSQL, back up the old data dir, `chown -R postgres:postgres`, verify `postgresql.auto.conf` / `recovery.signal`, and start PostgreSQL (it replays WAL to the target and promotes).

Constraints:

- **Incompatible with `--restore` / `--auto-start`** — the remote host is not Patroni-orchestrated; you finish manually.
- Refuses shallow paths (`/`, `/var`, `/var/lib`, `/tmp`, `/root`, `/etc`, `/usr`, `/home`, ...) to limit blast radius. Use a specific data-directory path.
- Requires `rsync` on the host running the script and on the remote.

---

## Options Detail

### `--server <server>`

Backup server configuration to use (db1..dbN). Specify when you know which server holds the backup — it skips auto-detection.

### `--target <node>`

Automates application to a local cluster node: stops Patroni on the node, backs up the current data directory, copies recovered data, sets permissions, configures recovery settings, and (with `--restore`) starts PostgreSQL in recovery.

### `--restore`

Starts PostgreSQL in recovery mode and monitors progress. Only meaningful with `--target <node>`. Promotion and cluster reintegration require `--auto-start`.

### `--wal-method <method>`

Sets `restore_command`. `backup-wal-restore` (default, recommended) or `backup-get-wal` (atomic-safe SSH alternative). See [WAL Methods](../pitr.md#wal-methods) in `docs/pitr.md` for the command formats and trade-offs.

### `--auto-start`

Beyond `--restore`: promotes the target node when recovery completes, reinitializes all other nodes as replicas, and monitors reinitialization. **Warning**: reinitialization destroys data on the other nodes — ensure that is intended.

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PATRONI_CLUSTER_NAME` | `patroni1` | Patroni cluster name; also names the data dir (`/var/lib/postgresql/<PG_VERSION>/<CLUSTER_NAME>/`) |
| `POSTGRES_VERSION` | probed / `15` | PostgreSQL major version used in the data dir path |
| `PITR_ALLOW_PIPED` | `0` | `1` allows interactive mode with piped stdin (testing only) |
| `KEEP_TMP_ON_FAILURE` | `0` | `1` keeps staging dirs on failure for debugging |

---

## Expected Output

### Successful Automated PITR

```
========================================
  Point-In-Time Recovery (PITR)
========================================

Backup ID: 20260123T120000
Target Time: latest
Target Node: db2
Mode: Automated (--target)

[1/8] Verifying backup exists...
✓ Backup found on server: db1

[2/8] Backup details:
Backup 20260123T120000
Begin time: 2026-01-23 12:00:00
End time: 2026-01-23 12:00:15

[3/8] Checking WAL archiving status...
✓ WAL archiving active
Last archived: 0000000100000006000000CD

[4/8] Creating recovery directory...
✓ Recovery directory created

[5/8] Performing PITR recovery...
✓ Recovery completed successfully

[6/8] Verifying recovery files...
✓ Recovery files created in container
Recovery directory size: 19.6 GiB

[7.1/10] Stopping Patroni on db2...
✓ Patroni stopped

[7.2/10] Verifying db2 is not in cluster...
✓ db2 is not in cluster

[7.3/10] Backing up current data directory...
✓ Data backed up to /var/lib/postgresql/15/patroni1.backup_20260123_123045

[7.4/10] Copying recovered data...
✓ Files copied successfully

[7.5/10] Setting permissions...
✓ Permissions set

[7.6/10] Configuring recovery settings...
✓ Recovery configured

[7.7/10] Starting PostgreSQL recovery...
✓ PostgreSQL started in recovery mode

[7.8/10] Monitoring recovery progress...
Recovery in progress...
Recovery completed at 2026-01-23 12:30:00

[7.9/10] Promoting node...
✓ db2 is now the leader!

[7.10/10] Reinitializing other nodes...
✓ Reinitialization commands executed

========================================
  Automated PITR Complete
========================================

✓ PITR has been applied to db2
```

### WAL Gap Warning

```
[3/8] Checking WAL availability...
⚠ WARNING: WAL gaps detected!
Missing WAL files: 0000000100000006000000CE, 0000000100000006000000CF
Recovery to 2026-01-23 12:30:00 will likely FAIL due to missing WAL files.

Recommendations:
  1. Use 'latest' to recover to the most recent available state (RECOMMENDED)
  2. Use the backup end time: 2026-01-23 12:00:15

Continue anyway? (y/N):
```

**Action**: Choose `N` and use `latest` or fix WAL gaps first.

### Target Time Validation Error

```
[2/8] Backup details:
Backup 20260123T120000
Begin time: 2026-01-23 12:00:00
End time: 2026-01-23 12:00:15
Target time: 2026-01-23 11:59:00

✗ ERROR: Target time is before backup end time!
You can only recover to a time AFTER the backup completed.

Valid recovery times:
  After: 2026-01-23 12:00:15
  Or use: latest (to recover to most recent state)
```

**Action**: Use a time after backup end, or `latest`.

For diagnosis of failed steps (Backup logs, disk space, recovery stalls), see [Troubleshooting](../pitr.md#troubleshooting) in `docs/pitr.md`.

---

## Post-Restore Verification SQL Checklist

After PITR completes, run these queries on the target node:

### 1. Recovery Status
```sql
SELECT pg_is_in_recovery();
-- Expected: f (false) when recovery complete
```

### 2. Recovery Target
```sql
SHOW recovery_target_time;
-- Expected: your target time (or NULL if latest)
```

### 3. Timeline
```sql
SELECT timeline_id FROM pg_control_checkpoint();
-- Expected: new timeline (higher than original)
```

### 4. Data Verification
```sql
-- Count rows in critical tables
SELECT COUNT(*) FROM your_important_table;

-- Check for expected data
SELECT * FROM your_table WHERE created_at <= '2026-01-23 12:30:00' LIMIT 10;

-- Verify no data after target time
SELECT COUNT(*) FROM your_table WHERE created_at > '2026-01-23 12:30:00';
-- Expected: 0 (if target time was before data creation)
```

### 5. Cluster Status
```sql
-- Check the target is no longer a replica
SELECT pg_is_in_recovery();
-- Expected: f (false)

-- Check replication slots (once other nodes rejoin)
SELECT slot_name, active FROM pg_replication_slots;
```

---

## Integration with Patroni

1. **Node isolation**: stops the Patroni *service* (not the container) on the target and verifies the node left the cluster, so Patroni cannot interfere with recovery.
2. **Recovery configuration**: writes `postgresql.auto.conf` with `restore_command` (per `--wal-method`) and `recovery_target_time`, plus `recovery.signal`.
3. **Promotion**: uses `patronictl failover` to promote the recovered node and waits for it to become leader.
4. **Cluster reintegration** (`--auto-start`): reinitializes all other nodes as replicas of the new leader and monitors their progress.

### If the node does not promote

Do **not** stop replica containers with `docker-compose stop` — a stopped node whose data dir is deemed failed can lead Patroni to wipe the data dir on bootstrap. Instead:

```bash
# 1) Pause Patroni's auto-failover while you inspect
docker exec db1 patronictl -c /etc/patroni/patroni.yml pause

# 2) Check cluster state
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# 3) Promote the recovered node if needed
docker exec db1 patronictl -c /etc/patroni/patroni.yml failover \
  --candidate db2 --force

# 4) Rebuild stale replicas safely through Patroni
make reinit NODE=db3

# 5) Resume failover protection
docker exec db1 patronictl -c /etc/patroni/patroni.yml resume
```

---

## Safety Notes

### What gets overwritten (with `--target <node>`)

- The target node's data directory `/var/lib/postgresql/<PG_VERSION>/<CLUSTER_NAME>/` (e.g. `/var/lib/postgresql/15/patroni1`)
- Current data is first backed up to `<data-dir>.backup_<timestamp>`
- Recovery settings in `postgresql.auto.conf`

### What is not overwritten

- Other nodes (unless `--auto-start` reinitializes them)
- Backup backups (read-only)
- Configuration files (mounted read-only)

### Irreversible operations

Once recovery starts, the cluster timeline diverges; other nodes need reinitialization. Roll back by restoring from `<data-dir>.backup_<timestamp>` if needed.

---

## Performance Notes

**Recovery time factors**: database size, number of WALs to replay (time between backup end and target), disk I/O, and network speed for WAL fetching.

**Typical times**:
- Small DB (< 10 GB): 5-15 minutes
- Medium DB (10-100 GB): 15-60 minutes
- Large DB (> 100 GB): 1-4 hours

**Optimization tips**:
1. Use the latest backup (fewer WALs to replay)
2. Recover to a time close to backup end
3. Ensure fast disk I/O (SSD recommended)
4. Monitor during recovery (catch issues early)

For remote PITR, transfer is compressed when possible (zstd/pigz/gzip negotiated with the remote) and resumable via `rsync --partial`.

---

## Error Recovery

### If the script fails mid-process

```bash
# Check the target's data dir state
docker exec db2 ls -la /var/lib/postgresql/15/patroni1/

# Restore the pre-PITR backup taken by the script
docker exec db2 mv /var/lib/postgresql/15/patroni1.backup_* /var/lib/postgresql/15/patroni1

# Restart Patroni
docker exec db2 supervisorctl start patroni
```

Staging directories created by a failed run are cleaned up automatically; set `KEEP_TMP_ON_FAILURE=1` before running to keep them for debugging.

### If recovery files are corrupted

```bash
# Remove corrupted staging
docker exec backup rm -rf /tmp/pitr_recovery_*

# Re-run the script
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> --server db1 --target db2 --restore
```

---

## References

- [docs/pitr.md](../pitr.md) — scenarios, WAL methods, troubleshooting
- **Backup**: https://www.pgbarman.org/documentation/
- **PostgreSQL continuous archiving**: https://www.postgresql.org/docs/15/continuous-archiving.html
- **Patroni operations**: https://patroni.readthedocs.io/en/latest/
- **Testing**: `make smoke-test` runs sandboxed wizard + PITR tests (`scripts/testing/smoke_test_*.sh`)
