# PITR Troubleshooting Guide

## Common Error: Target Time Before Backup End

### Error Message
```
ERROR: The requested target time 2026-01-04 15:25:00+00:00 is before the backup end time 2026-01-04 15:25:21.747093+00:00
```

### Cause
You cannot recover to a time **before** the backup completed. The backup represents the database state at the **end** of the backup process.

### Solution

#### Option 1: Use a Time After Backup End
```bash
# Backup ended at 15:25:21, so recover to 15:26:00 or later
./scripts/perform_pitr.sh 20260104T152519 '2026-01-04 15:26:00' db1
```

#### Option 2: Use an Earlier Backup
If you need to recover to 15:25:00, use a backup that was created **before** that time:
```bash
# List backups to find one before your target time
docker exec barman barman list-backup db1

# Use a backup that ended before 15:25:00
./scripts/perform_pitr.sh <earlier-backup-id> '2026-01-04 15:25:00' db1
```

#### Option 3: Recover to Latest
```bash
# Recover to the most recent state
./scripts/perform_pitr.sh 20260104T152519 latest db1
```

## Finding Valid Recovery Times

### Check Backup Details
```bash
docker exec barman barman show-backup db1 <backup-id> | grep -E "(Begin time|End time)"
```

### Check Available WAL Range
```bash
# Last archived WAL (upper limit)
docker exec barman barman show-server db1 | grep last_archived_time

# Current WAL position
docker exec barman barman show-server db1 | grep current_xlog
```

### Valid Recovery Range
- **Minimum:** After backup end time
- **Maximum:** Up to last archived WAL time
- **Or:** Use `latest` for most recent state

## Other Common Issues

### Missing WAL Files
**Error:** Recovery stops, cannot find WAL file

**Solution:**
```bash
# Check WAL archiving status
docker exec barman barman status db1 | grep -E "(Failures|Last archived)"

# Verify WAL files exist
docker exec barman ls -lh /data/pg-backup/db1/wals/

# Check if target time is within WAL range
docker exec barman barman show-server db1 | grep -E "(last_archived|current_xlog)"
```

### Recovery Stuck
**Symptom:** Recovery process hangs

**Solution:**
```bash
# Check recovery logs
docker exec db1 tail -f /var/log/postgresql/*.log

# Check Barman logs
docker exec barman tail -f /var/log/barman/barman.log

# Verify WAL files are being applied
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"
```

### Recovery Completed but Data Missing
**Symptom:** Recovery finishes but data doesn't match expected state

**Solution:**
```bash
# Verify recovery target was correct
docker exec db1 cat /var/lib/postgresql/15/patroni1/recovery.conf 2>/dev/null || \
docker exec db1 cat /var/lib/postgresql/15/patroni1/postgresql.conf | grep recovery_target

# Check if recovery actually completed
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false)

# Compare statistics
./scripts/count_database_stats.sh
# Compare with db_stats_before_pitr_*.json
```

## Quick Diagnostic Commands

```bash
# 1. List all backups
docker exec barman barman list-backup db1

# 2. Show backup details
docker exec barman barman show-backup db1 <backup-id>

# 3. Check WAL archiving
docker exec barman barman status db1

# 4. Verify recovery files
ls -lh /tmp/pitr_recovery_*/

# 5. Check recovery status
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"

# 6. View logs
docker exec db1 tail -f /var/log/postgresql/*.log
docker exec barman tail -f /var/log/barman/barman.log
```

