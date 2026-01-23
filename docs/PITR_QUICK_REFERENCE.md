# PITR Quick Reference

## Quick Steps

### 1. List Available Backups
```bash
docker exec barman barman list-backup db1
```

### 2. Choose Backup and Target Time
```bash
BACKUP_ID="20260104T153446"
TARGET_TIME="2026-01-04 15:45:00"  # or "latest"
```

### 3. Perform Recovery (Automated)
```bash
./scripts/perform_pitr.sh $BACKUP_ID "$TARGET_TIME"
```

### 4. Apply Recovery to Database
```bash
# Backup current data
docker exec db1 mv /var/lib/postgresql/15/patroni1 /var/lib/postgresql/15/patroni1.backup

# Copy recovered data
docker cp /tmp/pitr_recovery_*/. db1:/var/lib/postgresql/15/patroni1/

# Set permissions
docker exec db1 chown -R postgres:postgres /var/lib/postgresql/15/patroni1

# Restart
docker-compose restart db1
```

### 5. Verify Recovery
```bash
# Check recovery status
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"

# Verify data
./scripts/count_database_stats.sh
```

## Manual Recovery (Step-by-Step)

### Step 1: Verify Backup
```bash
docker exec barman barman list-backup db1
docker exec barman barman show-backup db1 <backup-id>
```

### Step 2: Check WAL Status
```bash
docker exec barman barman status db1
```

### Step 3: Perform Recovery
```bash
# Create recovery directory
mkdir -p /tmp/pitr_recovery

# Recover to specific time
docker exec barman barman recover \
  --target-time "2026-01-04 15:45:00" \
  db1 <backup-id> \
  /tmp/pitr_recovery

# Or recover to latest
docker exec barman barman recover \
  --target-time "latest" \
  db1 <backup-id> \
  /tmp/pitr_recovery
```

### Step 4: Apply Recovery
```bash
# Stop database (if needed)
docker-compose stop db1

# Backup current data
docker exec db1 mv /var/lib/postgresql/15/patroni1 /var/lib/postgresql/15/patroni1.backup

# Copy recovered data
docker cp /tmp/pitr_recovery/. db1:/var/lib/postgresql/15/patroni1/

# Set permissions
docker exec db1 chown -R postgres:postgres /var/lib/postgresql/15/patroni1

# Start database
docker-compose start db1
```

### Step 5: Verify
```bash
# Check if recovery completed
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"

# Should return 'f' (false) when complete

# Verify data
./scripts/count_database_stats.sh
```

## Manual PITR Configuration (postgresql.conf)

To perform PITR manually by configuring PostgreSQL directly, add these settings to `postgresql.conf` or `postgresql.auto.conf`:

```conf
# Restore command to fetch WAL files from Barman
restore_command = 'if [ -f %p ] && [ $(stat -c%s %p 2>/dev/null || echo 0) -gt 1000000 ]; then exit 0; fi; TMPFILE="/tmp/$(basename %p).$$.$(date +%s)"; rsync -e "ssh -i /home/postgres/.ssh/barman_rsa -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -a barman@barman:/data/pg-backup/db1/wals/*/%f "$TMPFILE" 2>/dev/null && [ -f "$TMPFILE" ] && [ $(stat -c%s "$TMPFILE" 2>/dev/null || echo 0) -gt 0 ] && (gunzip -c "$TMPFILE" > %p 2>/dev/null || cp "$TMPFILE" %p) && rm -f "$TMPFILE" || (rm -f "$TMPFILE" %p; exit 0)'

# Target time for recovery (adjust date and time as needed)
recovery_target_time = '2026-01-04 15:50:00+00:00'

# Pause recovery at target time (allows inspection before manual promotion)
recovery_target_action = 'pause'
```

**Steps for manual PITR:**

1. Add the configuration above to `postgresql.conf` or `postgresql.auto.conf` in your data directory
2. Create the recovery signal file:
   ```bash
   docker exec db1 su - postgres -c "touch /var/lib/postgresql/15/patroni1/recovery.signal && chmod 600 /var/lib/postgresql/15/patroni1/recovery.signal"
   ```
3. Start PostgreSQL - it will automatically begin recovery to the target time
4. When recovery reaches the target time, it will pause (if `recovery_target_action = 'pause'`)
5. To promote after inspection:
   ```bash
   docker exec db1 su - postgres -c "touch /var/lib/postgresql/15/patroni1/promote.signal"
   ```
   Or use `SELECT pg_promote();` from psql

**Note:** Replace `db1` in the `restore_command` with your actual node name if different. The `%p` and `%f` are PostgreSQL placeholders that will be replaced automatically during recovery.

## Recovery Target Options

| Option | Command |
|--------|---------|
| **Specific Time** | `--target-time "2026-01-04 15:45:00"` |
| **Latest** | `--target-time "latest"` |
| **Specific WAL** | `--target-wal 000000010000000600000025` |
| **Transaction ID** | `--target-xid 12345678` |

## Important Notes

⚠️ **Before Recovery:**
- ✅ Verify backup exists
- ✅ Check WAL archiving is working
- ✅ Backup current data
- ✅ Know your target recovery time

⚠️ **After Recovery:**
- ✅ Verify `pg_is_in_recovery()` returns `f`
- ✅ Compare statistics with pre-PITR data
- ✅ Test application connectivity
- ✅ Verify critical data

## Troubleshooting

### Recovery Stuck
```bash
# Check logs
docker exec db1 tail -f /var/log/postgresql/*.log
docker exec barman tail -f /var/log/barman/barman.log
```

### Missing WAL Files
```bash
# Check WAL availability
docker exec barman barman show-server db1 | grep last_archived
docker exec barman ls -lh /data/pg-backup/db1/wals/
```

### Recovery Failed
```bash
# Check backup details
docker exec barman barman show-backup db1 <backup-id>

# Verify target time is within backup range
docker exec barman barman show-backup db1 <backup-id> | grep -E "(Begin time|End time)"
```

## Files Created

- `PITR_GUIDE.md` - Complete detailed guide
- `scripts/perform_pitr.sh` - Automated PITR script
- `scripts/count_database_stats.sh` - Statistics script for verification
- `db_stats_before_pitr_*.json` - Pre-PITR statistics

