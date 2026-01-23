# perform_pitr.sh - Complete Reference

**File**: `scripts/pitr/perform_pitr.sh`  
**Status**: ✅ **DO NOT MODIFY** - This script is production-tested and must remain unchanged.

---

## Purpose and Philosophy

`perform_pitr.sh` is a **comprehensive, production-grade PITR automation script** that handles the entire recovery workflow from backup selection through cluster reintegration.

### Design Principles

1. **Safety First**: Validates prerequisites, warns about risks, creates backups
2. **Automation**: Minimizes manual steps when `--target` flag used
3. **Patroni-Aware**: Understands cluster topology, handles node isolation
4. **Error Handling**: Comprehensive validation and clear error messages
5. **Flexibility**: Supports both automated and manual workflows

### What It Does

The script orchestrates:
- Backup verification and selection
- WAL availability validation
- Recovery file creation
- Node isolation (Patroni-aware)
- Recovery application
- Cluster reintegration (optional)

---

## Synopsis

```bash
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> [OPTIONS]
```

### Positional Arguments

| Argument | Required | Description | Example |
|----------|----------|-------------|---------|
| `<backup-id>` | ✅ Yes | Barman backup identifier | `20260123T120000` |
| `<target-time>` | ✅ Yes | Recovery target time or `latest` | `'2026-01-23 12:30:00'` or `latest` |

### Options

| Option | Argument | Default | Description |
|--------|----------|---------|-------------|
| `--server` | `<server>` | Auto-detect | Barman server name (db1-db4) |
| `--target` | `<node>` | None | Target node for automated application |
| `--restore` | None | `false` | Start PostgreSQL recovery automatically |
| `--wal-method` | `<method>` | `barman-wal-restore` | WAL fetch method |
| `--auto-start` | None | `false` | Auto-start and monitor recovery |

---

## Full Command Reference

### Basic Usage (Manual Mode)

```bash
# List available backups first
docker exec barman barman list-backup db1

# Perform PITR (creates recovery files, shows instructions)
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1
```

**Output**: Recovery files created, manual steps printed.

---

### Automated PITR (Recommended)

```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore
```

**What happens**:
1. Verifies backup exists
2. Validates target time
3. Checks WAL availability
4. Creates recovery files
5. Stops Patroni on db2
6. Backs up current data
7. Applies recovery
8. Configures restore_command
9. Starts PostgreSQL in recovery mode
10. Monitors recovery progress
11. Promotes when complete

---

### Automated PITR with Cluster Reintegration

```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore \
  --auto-start
```

**Additional steps** (beyond `--restore`):
- Automatically promotes db2 to leader
- Reinitializes db1, db3, db4 as replicas
- Monitors reinitialization progress

---

## Canonical Examples

### Example 1: Recover to Latest (Most Common)

**Use Case**: Recover to most recent state after corruption.

```bash
# Get latest backup ID
BACKUP_ID=$(docker exec barman barman list-backup db1 | head -2 | tail -1 | awk '{print $2}')

# Perform PITR to latest
bash scripts/pitr/perform_pitr.sh $BACKUP_ID latest \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore \
  --auto-start
```

**Expected Output**:
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
Last archived: 0000000100000006000000CD at 2026-01-23 12:30:00
Failures: 0

[4/8] Creating recovery directory...
✓ Recovery directory created

[5/8] Performing PITR recovery...
Recovering to latest available state (end of WAL)...
✓ Recovery completed successfully

[6/8] Verifying recovery files...
✓ Recovery files created in container

[7.1/10] Stopping Patroni on db2...
✓ Patroni stopped

[7.2/10] Verifying db2 is not in cluster...
✓ db2 is not in cluster

[7.3/10] Backing up current data directory...
✓ Data backed up to /var/lib/postgresql/15/patroni2.backup_20260123_123045

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

---

### Example 2: Recover to Specific Timestamp

**Use Case**: Recover to time just before accidental DELETE.

```bash
# DELETE occurred at 12:30:00, recover to 12:29:59
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:29:59' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore
```

**Expected Output**: Similar to Example 1, but stops at specified time.

**Verification**:
```bash
# Check recovery target was correct
docker exec db2 psql -U postgres -c "SHOW recovery_target_time;"
# Should show: 2026-01-23 12:29:59

# Verify data exists (before DELETE)
docker exec db2 psql -U postgres -d maborak -c "SELECT COUNT(*) FROM deleted_table;"
# Should show row count before DELETE
```

---

### Example 3: Manual PITR (For Learning)

**Use Case**: Understand each step, don't automate.

```bash
# Step 1: Create recovery files only
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1

# Script outputs:
# - Recovery files location
# - Manual steps to apply recovery
# - Promotion instructions
```

**Then follow printed instructions**:
```bash
# Script prints:
# 1. Stop Patroni on target node
docker exec db2 supervisorctl stop patroni

# 2. Backup current data
docker exec db2 mv /var/lib/postgresql/15/patroni2 /var/lib/postgresql/15/patroni2.backup

# 3. Copy recovered data
docker cp barman:/tmp/pitr_recovery_*/. db2:/var/lib/postgresql/15/patroni2/

# 4. Set permissions
docker exec db2 chown -R postgres:postgres /var/lib/postgresql/15/patroni2

# 5. Start PostgreSQL
docker exec db2 supervisorctl start patroni

# 6. Monitor recovery
docker exec db2 tail -f /var/log/postgresql/*.log
```

---

## Positional Arguments Detail

### `<backup-id>`

**Format**: `YYYYMMDDTHHMMSS` (Barman backup identifier)

**Examples**:
- `20260123T120000` - Backup from Jan 23, 2026 at 12:00:00
- `20260104T153446` - Backup from Jan 4, 2026 at 15:34:46

**How to find**:
```bash
docker exec barman barman list-backup db1
# Output:
# db1 20260123T120000 - Mon Jan 23 12:00:00 2026 - Size: 19.6 GiB
#                      ^^^^^^^^^^^^^^
#                      This is the backup-id
```

**Validation**: Script verifies backup exists before proceeding.

---

### `<target-time>`

**Format**: PostgreSQL timestamp or `latest`

**Examples**:
- `'2026-01-23 12:30:00'` - Specific timestamp
- `'2026-01-23 12:30:00+00:00'` - With timezone
- `latest` - Most recent available state

**Rules**:
- Must be **after** backup end time (script validates)
- Must be **before or equal to** last archived WAL time
- Microsecond precision supported (e.g., `'2026-01-23 12:30:00.123456'`)

**Special Value: `latest`**:
- Recover to most recent available WAL
- No target time validation needed
- Best option when exact time not critical
- Handles WAL availability automatically

---

## Options Detail

### `--server <server>`

**Purpose**: Specify which Barman server configuration to use.

**Values**: `db1`, `db2`, `db3`, `db4`

**Default**: Auto-detect (checks all servers)

**When to specify**:
- You know which server the backup is on
- Faster execution (skips auto-detection)

**Example**:
```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest --server db1 --target db2 --restore
```

---

### `--target <node>`

**Purpose**: Automatically apply PITR to specified node.

**Values**: `db1`, `db2`, `db3`, `db4`

**Default**: None (manual mode)

**What it enables**:
- ✅ Stops Patroni on target node
- ✅ Backs up current data directory
- ✅ Copies recovered data
- ✅ Configures recovery settings
- ✅ Starts PostgreSQL in recovery

**Requires**: `--restore` flag to actually start recovery

**Example**:
```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest --server db1 --target db2 --restore
```

---

### `--restore`

**Purpose**: Start PostgreSQL recovery automatically.

**Default**: `false` (only prepare recovery files)

**When to use**: Always use with `--target` for full automation

**What it does**:
- Starts PostgreSQL in recovery mode
- Monitors recovery progress
- Promotes when complete (if `--auto-start` also specified)

**Example**:
```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest --server db1 --target db2 --restore
```

**Note**: Without `--target`, this flag has no effect (no node to start on).

---

### `--wal-method <method>`

**Purpose**: Choose WAL fetch method for `restore_command`.

**Values**:
- `barman-wal-restore` (default, recommended)
- `barman-get-wal` (atomic-safe alternative)

**Default**: `barman-wal-restore`

**When to use `barman-get-wal`**:
- High-concurrency recovery scenarios
- Need atomic file operations
- barman-wal-restore not available

**Example**:
```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest \
  --server db1 --target db2 --restore \
  --wal-method barman-get-wal
```

**See**: [WAL Methods](#wal-methods) section in `docs/pitr.md`

---

### `--auto-start`

**Purpose**: Automatically start PostgreSQL and monitor recovery, then reintegrate cluster.

**Default**: `false`

**What it enables** (beyond `--restore`):
- ✅ Automatically promotes node when recovery completes
- ✅ Reinitializes other nodes as replicas
- ✅ Monitors reinitialization progress

**When to use**:
- Full cluster recovery scenario
- Want zero-touch automation
- Testing complete recovery workflow

**Example**:
```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest \
  --server db1 --target db2 --restore --auto-start
```

**Warning**: This will reinitialize other nodes. Ensure this is desired.

---

## Environment Variables

### `PATRONI_CLUSTER_NAME`

**Purpose**: Override Patroni cluster name.

**Default**: `patroni1`

**Usage**:
```bash
PATRONI_CLUSTER_NAME=mycluster bash scripts/pitr/perform_pitr.sh ...
```

**When needed**: If using non-default cluster name in Patroni configs.

---

## Expected Outputs

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
✓ Data backed up to /var/lib/postgresql/15/patroni2.backup_20260123_123045

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

---

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

---

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

**Action**: Use time after backup end or use `latest`.

---

## Troubleshooting

### Script Fails at Step 1 (Backup Not Found)

**Error**:
```
✗ Backup 20260123T120000 not found on server: db1
```

**Diagnosis**:
```bash
# List all backups
for server in db1 db2 db3 db4; do
  echo "=== $server ==="
  docker exec barman barman list-backup $server
done
```

**Fix**: Use correct backup ID or specify `--server` if backup is on different server.

---

### Script Fails at Step 5 (Recovery Creation)

**Error**:
```
✗ Recovery failed!
Check Barman logs: docker exec barman tail -f /var/log/barman/barman.log
```

**Diagnosis**:
```bash
# Check Barman logs
docker exec barman tail -50 /var/log/barman/barman.log

# Check disk space
docker exec barman df -h /data/pg-backup

# Verify backup integrity
docker exec barman barman check db1
```

**Fix**: Resolve underlying issue (disk space, backup corruption, etc.) then retry.

---

### Recovery Stuck at Step 7.8 (Monitoring)

**Symptom**: Script hangs at "Monitoring recovery progress..."

**Diagnosis**:
```bash
# Check recovery status manually
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Check logs
docker exec db2 tail -f /var/log/postgresql/*.log

# Check if WAL files are being fetched
docker exec db2 ls -lh /var/lib/postgresql/15/patroni2/pg_wal/ | tail -10
```

**Common Causes**:
- WAL gap (recovery waiting for missing WAL)
- Network issue (cannot fetch WALs from Barman)
- Disk full (cannot write WAL files)

**Fix**: Resolve underlying issue, then recovery will continue.

---

### Node Not Promoting (Step 7.9)

**Error**:
```
⚠ db2 is still not the leader (current role: Replica)
```

**Diagnosis**:
```bash
# Check cluster status
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# Check if other nodes are still active
docker exec db1 psql -U postgres -c "SELECT application_name, state FROM pg_stat_replication;"
```

**Fix**:
```bash
# Stop other nodes first
docker-compose stop db1 db3 db4

# Then promote
docker exec db2 patronictl -c /etc/patroni/patroni.yml failover patroni1 --candidate db2 --force
```

---

## Post-Restore Verification SQL Checklist

After PITR completes, run these SQL queries:

### 1. Recovery Status
```sql
SELECT pg_is_in_recovery();
-- Expected: f (false) when recovery complete
```

### 2. Recovery Target
```sql
SHOW recovery_target_time;
-- Expected: Your target time (or NULL if latest)
```

### 3. Timeline
```sql
SELECT timeline_id FROM pg_control_checkpoint();
-- Expected: New timeline (higher than original)
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
-- On target node, check if it's leader
SELECT pg_is_in_recovery();
-- Expected: f (false)

-- Check replication slots (if other nodes exist)
SELECT slot_name, active FROM pg_replication_slots;
```

---

## Safety Warnings

### ⚠️ What This Script Overwrites

**When `--target` is used**:
- **Target node's data directory** (`/var/lib/postgresql/15/patroni{N}/`)
- **Current data is backed up** to `${PATRONI_DATA_DIR}.backup_${TIMESTAMP}`
- **Recovery settings** in `postgresql.auto.conf`

**What is NOT overwritten**:
- Other nodes (unless `--auto-start` reinitializes them)
- Barman backups (read-only)
- Configuration files (mounted read-only)

### ⚠️ Assumptions

The script assumes:
- Target node can be stopped (Patroni will stop PostgreSQL)
- Sufficient disk space for recovery files
- Barman is accessible via SSH
- Network connectivity between nodes

### ⚠️ Irreversible Operations

**Once recovery starts**:
- Original data is backed up but recovery cannot be easily undone
- Cluster state changes (timeline divergence)
- Other nodes may need reinitialization

**Rollback**: Restore from `${PATRONI_DATA_DIR}.backup_${TIMESTAMP}` if needed.

---

## Integration with Patroni

### How Script Handles Patroni

1. **Node Isolation**:
   - Stops Patroni service (not container)
   - Verifies node removed from cluster
   - Prevents Patroni from interfering

2. **Recovery Configuration**:
   - Creates `postgresql.auto.conf` with recovery settings
   - Configures `restore_command` based on `--wal-method`
   - Sets `recovery_target_time` if specified

3. **Promotion**:
   - Uses `patronictl failover` to promote node
   - Waits for promotion to complete
   - Verifies node is leader

4. **Cluster Reintegration**:
   - Reinitializes other nodes as replicas (if `--auto-start`)
   - Monitors reinitialization progress
   - Provides status updates

---

## Common Usage Patterns

### Pattern 1: Quick Recovery to Latest

```bash
BACKUP_ID=$(docker exec barman barman list-backup db1 | head -2 | tail -1 | awk '{print $2}')
bash scripts/pitr/perform_pitr.sh $BACKUP_ID latest --server db1 --target db2 --restore --auto-start
```

**Use when**: Need quick recovery, exact time not critical.

---

### Pattern 2: Precise Time Recovery

```bash
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:29:59.500000' \
  --server db1 --target db2 --restore --wal-method barman-wal-restore
```

**Use when**: Need exact timestamp (e.g., just before DELETE).

---

### Pattern 3: Manual Application

```bash
# Create recovery files
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1

# Follow printed instructions to apply manually
# (Gives you control over each step)
```

**Use when**: Learning, testing, or need manual control.

---

## Performance Considerations

### Recovery Time

**Factors**:
- Database size (larger = longer)
- Number of WALs to replay (time from backup to target)
- Disk I/O speed
- Network speed (WAL fetching)

**Typical Times**:
- Small DB (< 10GB): 5-15 minutes
- Medium DB (10-100GB): 15-60 minutes
- Large DB (> 100GB): 1-4 hours

### Optimization Tips

1. **Use latest backup** (fewer WALs to replay)
2. **Recover to time close to backup end** (fewer WALs)
3. **Ensure fast disk I/O** (SSD recommended)
4. **Monitor during recovery** (catch issues early)

---

## Error Recovery

### If Script Fails Mid-Process

**Scenario**: Script fails at step 7.5 (copying data)

**Recovery**:
```bash
# Check what was done
docker exec db2 ls -la /var/lib/postgresql/15/patroni2/

# Restore from backup
docker exec db2 mv /var/lib/postgresql/15/patroni2.backup_* /var/lib/postgresql/15/patroni2

# Restart Patroni
docker exec db2 supervisorctl start patroni
```

### If Recovery Files Corrupted

**Scenario**: Recovery files created but corrupted

**Recovery**:
```bash
# Remove corrupted recovery
docker exec barman rm -rf /tmp/pitr_recovery_*

# Re-run script
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> --server db1 --target db2 --restore
```

---

## Advanced: Custom restore_command

The script automatically configures `restore_command` based on `--wal-method`. For custom commands:

**Manual override** (not recommended):
1. Run script without `--restore` (creates recovery files only)
2. Manually edit `postgresql.auto.conf` after copying files
3. Start PostgreSQL manually

**See**: `docs/pitr.md` → WAL Methods section for command formats.

---

## References

- **Barman Recovery**: https://www.pgbarman.org/documentation/
- **PostgreSQL Recovery**: https://www.postgresql.org/docs/15/continuous-archiving.html
- **Patroni Operations**: https://patroni.readthedocs.io/en/latest/

---

## Support

**For Issues**:
1. Check `docs/pitr.md` → Troubleshooting
2. Review script output (detailed error messages)
3. Check logs: `docker logs db2` and `docker exec barman tail /var/log/barman/barman.log`

**Script Location**: `scripts/pitr/perform_pitr.sh`  
**Do NOT modify** - Script is production-tested and stable.
