# Point-In-Time Recovery (PITR) - Consolidated Guide

Complete guide for performing Point-In-Time Recovery with Barman in the Patroni HA cluster.

**Status**: ✅ Fully implemented and automated via `scripts/pitr/perform_pitr.sh`

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Scenarios](#scenarios)
5. [WAL Methods](#wal-methods)
6. [Troubleshooting](#troubleshooting)
7. [Legacy PITR Docs Mapping](#legacy-pitr-docs-mapping)

---

## Overview

**What is PITR?**

Point-In-Time Recovery allows you to restore a PostgreSQL database to any specific timestamp between a base backup and the last archived WAL file.

**Why It Matters**:
- Recover from accidental `DELETE` or `DROP TABLE`
- Restore to known good state before corruption
- Meet compliance requirements (recover to audit point)
- Test data at historical points

**How It Works**:
1. Start with a base backup (full database copy)
2. Replay WAL files from backup end time to target time
3. Stop at target time
4. Promote database to production

---

## Prerequisites

### ✅ Required Before Starting PITR

1. **Backup Exists**
   ```bash
   docker exec barman barman list-backup db1
   # Should show at least one backup with status "DONE"
   ```

2. **WAL Archiving Active**
   ```bash
   docker exec barman barman status db1 | grep -E "(Failures|Last archived)"
   # Expected: Failures: 0, Last archived shows recent time
   ```

3. **WAL Files Available**
   ```bash
   docker exec barman barman list-wals db1 | head -10
   # Should show WAL files covering your target time
   ```

4. **Target Time Known**
   - Exact timestamp (e.g., `'2026-01-23 12:30:00'`)
   - Or use `latest` for most recent state

5. **Target Node Available**
   - Prefer replica node (isolates from cluster)
   - Or use leader (requires stopping cluster)

---

## Quick Start

### Automated PITR (Recommended)

```bash
# Full automated PITR with cluster integration
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore \
  --auto-start
```

**What this does**:
- Verifies backup exists
- Validates target time
- Checks WAL availability
- Creates recovery files
- Stops Patroni on target node
- Applies recovery
- Promotes node to leader
- Reinitializes other nodes (if `--auto-start`)

**See**: `docs/tools/perform_pitr.md` for complete script documentation.

---

## Scenarios

### Scenario 1: Restore to Latest State

**Goal**: Recover to the most recent available state (no specific timestamp needed).

**When to use**:
- After data corruption
- Testing recovery procedures
- When exact time is not critical

**Commands**:
```bash
# Get latest backup
BACKUP_ID=$(docker exec barman barman list-backup db1 | head -2 | tail -1 | awk '{print $2}')

# Perform PITR to latest
bash scripts/pitr/perform_pitr.sh $BACKUP_ID latest \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore
```

**Verification**:
```bash
# Check recovery completed
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false)

# Verify data
bash scripts/debug/count_database_stats.sh db2
```

---

### Scenario 2: Restore to Specific Timestamp

**Goal**: Recover to exact point in time (e.g., before accidental DELETE).

**When to use**:
- Accidental data deletion
- Need to restore to audit point
- Testing specific historical state

**Commands**:
```bash
# Identify backup before target time
docker exec barman barman list-backup db1

# Perform PITR
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore
```

**Important**: Target time must be **after** backup end time.

**Verification**:
```bash
# Check recovery target was correct
docker exec db2 psql -U postgres -c "SHOW recovery_target_time;"

# Verify data at target time
docker exec db2 psql -U postgres -d maborak -c "SELECT COUNT(*) FROM your_table;"
```

---

### Scenario 3: Restore After Accidental DELETE

**Goal**: Recover data deleted by mistake.

**Steps**:

1. **Identify when DELETE occurred:**
   ```bash
   # Check PostgreSQL logs
   docker exec db1 grep -i "DELETE" /var/log/postgresql/*.log | tail -20
   
   # Or check application logs
   # Note the timestamp when DELETE was executed
   ```

2. **Find backup before DELETE:**
   ```bash
   # List backups
   docker exec barman barman list-backup db1
   
   # Choose backup that ended BEFORE the DELETE
   # Example: DELETE at 12:30:00, use backup ending at 12:25:00
   ```

3. **Perform PITR to time just before DELETE:**
   ```bash
   # Recover to 1 second before DELETE
   bash scripts/pitr/perform_pitr.sh 20260123T122500 '2026-01-23 12:29:59' \
     --server db1 \
     --target db2 \
     --restore \
     --wal-method barman-wal-restore
   ```

4. **Verify data restored:**
   ```bash
   # Check table exists and has data
   docker exec db2 psql -U postgres -d maborak -c "SELECT COUNT(*) FROM deleted_table;"
   ```

5. **Export recovered data (if needed):**
   ```bash
   # Export to SQL dump
   docker exec db2 pg_dump -U postgres -d maborak -t deleted_table > recovered_data.sql
   ```

---

### Scenario 4: Restore into Target Container

**Goal**: Apply PITR to specific node without affecting cluster.

**When to use**:
- Testing recovery procedures
- Isolating recovery from production cluster
- Rebuilding specific node

**Commands**:
```bash
# Stop Patroni on target node first (if not using --target flag)
docker exec db2 supervisorctl stop patroni

# Perform PITR
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore

# Script automatically:
# - Stops Patroni
# - Backs up current data
# - Applies recovery
# - Configures restore_command
# - Starts PostgreSQL in recovery
```

**Post-Recovery**:
```bash
# Verify recovery completed
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Promote node (if needed)
docker exec db2 psql -U postgres -c "SELECT pg_promote();"

# Rejoin cluster (if other nodes are running)
# Note: PITR node will be on new timeline, other nodes need reinit
```

---

## WAL Methods

Two methods are available for fetching WAL files during recovery.

### Method 1: barman-wal-restore (Recommended)

**Command**:
```conf
restore_command = 'barman-wal-restore -U barman barman db1 %f %p'
```

**Advantages**:
- ✅ Simpler command
- ✅ Handles compression automatically
- ✅ Built-in error handling
- ✅ Recommended for most use cases

**Requirements**:
- `barman-wal-restore` must be in PATH on target node
- Barman server accessible via network

**Usage**:
```bash
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> \
  --wal-method barman-wal-restore
```

---

### Method 2: barman get-wal (Atomic-Safe)

**Command**:
```conf
restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db1 %f" > "$tmp" && mv "$tmp" %p)'
```

**Advantages**:
- ✅ Atomic file operations (prevents corruption)
- ✅ More control over process
- ✅ Useful in high-concurrency scenarios

**How It Works**:
1. Checks if WAL already exists (`test -f %p`)
2. Creates temp file with process ID (`%p.tmp.$$`)
3. Sets restrictive permissions (`umask 077`)
4. Downloads WAL to temp file
5. Atomically moves to final location (`mv "$tmp" %p`)

**Usage**:
```bash
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> \
  --wal-method barman-get-wal
```

**Note**: Script automatically configures this method when `--wal-method barman-get-wal` is specified.

---

## Troubleshooting

### Issue: Target Time Before Backup End

**Error**:
```
ERROR: Target time is before backup end time!
```

**Cause**: Cannot recover to time before backup completed.

**Solution**:
```bash
# Check backup end time
docker exec barman barman show-backup db1 <backup-id> | grep "End time"

# Use time after backup end, or use 'latest'
bash scripts/pitr/perform_pitr.sh <backup-id> latest --server db1 --target db2 --restore
```

---

### Issue: WAL Gaps

**Error**: Recovery stops, cannot find WAL file.

**Diagnosis**:
```bash
# Check WAL archiving status
docker exec barman barman status db1 | grep -E "(Failures|Last archived)"

# List WALs
docker exec barman barman list-wals db1

# Check for gaps in sequence
docker exec barman ls /data/pg-backup/db1/wals/*/ | sort
```

**Solution**:
```bash
# Use 'latest' instead of specific time
bash scripts/pitr/perform_pitr.sh <backup-id> latest --server db1 --target db2 --restore

# Or use backup end time (guaranteed to have WALs)
BACKUP_END=$(docker exec barman barman show-backup db1 <backup-id> | grep "End time" | awk '{print $3, $4}')
bash scripts/pitr/perform_pitr.sh <backup-id> "$BACKUP_END" --server db1 --target db2 --restore
```

---

### Issue: Recovery Stuck

**Symptom**: Recovery process hangs, no progress.

**Diagnosis**:
```bash
# Check recovery status
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Check logs
docker exec db2 tail -f /var/log/postgresql/*.log

# Check Barman logs
docker exec barman tail -f /var/log/barman/barman.log
```

**Common Causes**:
- WAL file missing (check Barman)
- Network issues (check SSH connectivity)
- Disk full (check disk space)

**Solution**:
```bash
# Check disk space
docker exec db2 df -h /var/lib/postgresql

# Check SSH connectivity
bash scripts/test_ssh_to_barman.sh

# Check WAL availability
docker exec barman barman list-wals db1 | grep <missing-wal>
```

---

### Issue: Recovery Completed but Data Missing

**Symptom**: Recovery finishes but data doesn't match expected state.

**Diagnosis**:
```bash
# Verify recovery target
docker exec db2 cat /var/lib/postgresql/15/patroni2/postgresql.auto.conf | grep recovery_target

# Check if recovery actually completed
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false)

# Check recovery LSN
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_replay_lsn();"
```

**Possible Causes**:
- Wrong target time (recovered to different time than expected)
- Data was deleted before target time
- Recovery stopped early due to WAL gap

**Solution**:
```bash
# Verify target time was correct
docker exec db2 psql -U postgres -c "SHOW recovery_target_time;"

# If wrong, re-run PITR with correct time
# If data was deleted before target, use earlier target time
```

---

## Common Pitfalls

### ❌ Pitfall 1: Recovering on Leader Without Stopping

**Problem**: Running PITR on leader while it's active causes cluster issues.

**Solution**: Always use `--target` flag or stop Patroni first:
```bash
# Automated (recommended)
bash scripts/pitr/perform_pitr.sh ... --target db2 --restore

# Manual
docker exec db1 supervisorctl stop patroni
# Then run PITR
```

---

### ❌ Pitfall 2: Target Time Too Close to Backup End

**Problem**: Target time < 10 seconds after backup end may require partial WAL files.

**Solution**: Use backup end time exactly or add buffer:
```bash
# Get backup end time
BACKUP_END=$(docker exec barman barman show-backup db1 <backup-id> | grep "End time" | awk '{print $3, $4}')

# Use backup end time or add 30 seconds buffer
TARGET_TIME=$(docker exec barman date -d "$BACKUP_END + 30 seconds" +"%Y-%m-%d %H:%M:%S")
```

---

### ❌ Pitfall 3: Not Verifying WAL Availability

**Problem**: Assuming WALs exist without checking.

**Solution**: Script validates automatically, but manual check:
```bash
# Check last archived WAL
docker exec barman barman show-server db1 | grep last_archived

# Verify target time is within range
# Target time must be ≤ last archived time
```

---

### ❌ Pitfall 4: Ignoring WAL Gap Warnings

**Problem**: Script warns about WAL gaps but user proceeds anyway.

**Solution**: **Always investigate gaps before proceeding**:
```bash
# If script warns about gaps, check:
docker exec barman barman list-wals db1 | grep <missing-wal>

# Use 'latest' if gaps cannot be resolved
bash scripts/pitr/perform_pitr.sh <backup-id> latest --server db1 --target db2 --restore
```

---

## Post-Recovery Verification Checklist

After PITR completes, verify:

- [ ] Recovery completed (`pg_is_in_recovery()` returns `f`)
- [ ] Target time correct (`SHOW recovery_target_time`)
- [ ] Data exists (run application queries)
- [ ] Statistics match expectations (`count_database_stats.sh`)
- [ ] Application connectivity works
- [ ] Cluster status healthy (`patronictl list`)
- [ ] Other nodes reinitialized (if `--auto-start` used)

---

## Legacy PITR Docs Mapping

The following legacy PITR documentation files have been consolidated into this guide:

### `docs/PITR_GUIDE.md` → This Document
- **Content**: Step-by-step manual PITR procedures
- **Moved to**: [Scenarios](#scenarios) section
- **Status**: Superseded by automated script, but manual steps preserved for learning

### `docs/PITR_QUICK_REFERENCE.md` → This Document
- **Content**: Quick command reference
- **Moved to**: [Quick Start](#quick-start) section
- **Status**: Commands integrated into scenarios

### `docs/PITR_CONSIDERATIONS.md` → This Document
- **Content**: Critical considerations, best practices, pitfalls
- **Moved to**: [Prerequisites](#prerequisites), [Common Pitfalls](#common-pitfalls)
- **Status**: Key points integrated, detailed considerations preserved in troubleshooting

### `docs/PITR_PATRONI_GUIDE.md` → This Document + `docs/tools/perform_pitr.md`
- **Content**: Patroni-specific PITR procedures
- **Moved to**: [Scenario 4](#scenario-4-restore-into-target-container)
- **Status**: Fully integrated into automated script

### `docs/PITR_TROUBLESHOOTING.md` → This Document
- **Content**: Troubleshooting guide
- **Moved to**: [Troubleshooting](#troubleshooting) section
- **Status**: All content preserved and enhanced

### `docs/BARMAN_STATUS_GUIDE.md` → Referenced
- **Content**: Barman status interpretation
- **Status**: Still useful as reference, linked from Prerequisites

**Recommendation**: Legacy docs can be archived but kept for reference. This consolidated guide is the canonical source.

---

## Advanced Topics

### Timeline Handling

**What are timelines?**
- PostgreSQL uses timelines to track WAL history
- Each promotion/failover creates new timeline
- PITR creates new timeline (diverges from original)

**Implications**:
- PITR node cannot replicate to old cluster nodes (timeline divergence)
- Other nodes must be reinitialized after PITR
- Use `--auto-start` flag to automate reinitialization

### Recovery Target Options

| Option | Usage | When to Use |
|--------|-------|-------------|
| `latest` | `--target-time latest` | Most recent state, no specific time needed |
| Specific time | `--target-time '2026-01-23 12:30:00'` | Exact timestamp required |
| Transaction ID | Not supported in script | Use manual recovery if needed |
| WAL LSN | Not supported in script | Use manual recovery if needed |

---

## References

- **Barman PITR**: https://www.pgbarman.org/documentation/
- **PostgreSQL Recovery**: https://www.postgresql.org/docs/15/continuous-archiving.html
- **perform_pitr.sh**: See `docs/tools/perform_pitr.md`
