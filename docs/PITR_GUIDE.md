# Point-In-Time Recovery (PITR) Guide

Complete step-by-step guide for performing PITR with Barman.

## Barman Overview

Barman (Backup and Recovery Manager) is a disaster recovery solution for PostgreSQL servers. It provides continuous WAL archiving and base backups, enabling Point-In-Time Recovery (PITR).

### How Barman Works

1. **WAL Archiving**: PostgreSQL continuously streams Write-Ahead Log (WAL) files to Barman via `archive_command`
2. **Base Backups**: Periodic full database backups are taken using `barman backup`
3. **WAL Processing**: Barman processes incoming WAL files and stores them in an organized structure
4. **Recovery**: You can recover to any point in time using base backups + WAL files

### Barman Directory Structure

For each PostgreSQL server (e.g., `db1`, `db2`), Barman maintains:

```
/data/pg-backup/{server}/
├── incoming/          # WAL files arrive here first (temporary staging)
│   └── 000000010000000000000001
├── wals/             # Processed WAL files organized by timeline
│   └── 0000000100000000/
│       ├── 000000010000000000000001
│       ├── 000000010000000000000002.gz
│       └── ...
├── base/             # Base backups
│   └── 20260104T163505/
│       ├── data/
│       └── ...
└── .barman/          # Barman metadata
```

**WAL Flow:**
1. PostgreSQL sends WAL → `/data/pg-backup/{server}/incoming/`
2. Barman cron processes WAL → moves to `/data/pg-backup/{server}/wals/{timeline}/`
3. WALs are compressed (`.gz`) after processing
4. Old WALs are purged based on retention policy

## Quick Reference: Recovery Commands

**The `restore_command` you need to add to `postgresql.auto.conf`:**

### Method 1: barman-wal-restore (Recommended)

```
restore_command = 'barman-wal-restore -U barman barman db2 %f %p'
```

**Advantages:**
- Simpler command
- Handles compression automatically
- Built-in error handling
- Recommended for most use cases

**Replace:**
- `db2` → Your Barman server name

### Method 2: barman get-wal (Atomic-safe)

```
restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)'
```

**Advantages:**
- Atomic file operations (prevents corruption)
- More control over the process
- Useful in high-concurrency scenarios

**How it works:**
- Checks if WAL file already exists (`test -f %p`)
- Creates temporary file with process ID (`%p.tmp.$$`)
- Sets restrictive permissions (`umask 077`)
- Downloads WAL to temp file
- Atomically moves to final location (`mv "$tmp" %p`)

**Replace:**
- `barman` → Your Barman server hostname
- `db2` → Your Barman server name

**Also add:**
```
recovery_target_time = '2026-01-04 15:50:00+00:00'
recovery_target_action = 'promote'
recovery_target_timeline = 'latest'
```

## Prerequisites

1. ✅ A base backup exists
2. ✅ WAL archiving is working
3. ✅ WAL files are available for the target recovery time
4. ✅ You know the target recovery time/point

## Step 1: Verify Backup and WAL Availability

```bash
# On Barman server
# List available backups
barman list-backup <server-name>

# Check WAL archiving status
barman status <server-name>

# Verify WAL files are available
barman show-server <server-name> | grep -E "(last_archived|current_xlog)"

# Example
barman list-backup pg-primary
barman status pg-primary
```

**Expected output:**
- At least one backup available
- `Failures of WAL archiver: 0`
- `Last archived WAL` is recent

## Step 2: Choose Recovery Target

You can recover to:
- **Specific time**: `2026-01-04 15:45:00`
- **Specific WAL**: `000000010000000600000025`
- **Latest state**: `latest`
- **Transaction ID (XID)**: `12345678`

### Find Available Recovery Points

```bash
# On Barman server
# Show backup details to see WAL range
barman show-backup <server-name> <backup-id>

# Check current WAL position
barman show-server <server-name> | grep current_xlog

# Example
barman show-backup pg-primary 20260104T152519
```

## Step 3: Prepare Recovery Location

```bash
# Create recovery directory
mkdir -p /tmp/pitr_recovery
chmod 700 /tmp/pitr_recovery
```

## Step 4: Perform PITR Recovery

### Option A: Recover to Specific Time

```bash
# On Barman server
# Recover to a specific timestamp
barman recover \
  --target-time "2026-01-04 15:45:00" \
  <server-name> <backup-id> \
  /tmp/pitr_recovery

# Example
barman recover \
  --target-time "2026-01-04 15:45:00" \
  pg-primary 20260104T152519 \
  /tmp/pitr_recovery
```

### Option B: Recover to Specific WAL

```bash
# On Barman server
# Recover to a specific WAL file
barman recover \
  --target-wal 000000010000000600000025 \
  <server-name> <backup-id> \
  /tmp/pitr_recovery
```

### Option C: Recover to Latest State

```bash
# On Barman server
# Recover to the latest available state
barman recover \
  --target-time "latest" \
  <server-name> <backup-id> \
  /tmp/pitr_recovery
```

### Option D: Recover to Transaction ID

```bash
# On Barman server
# Recover to a specific transaction ID
barman recover \
  --target-xid 12345678 \
  <server-name> <backup-id> \
  /tmp/pitr_recovery
```

## Step 5: Copy Recovered Data to PostgreSQL Server

```bash
# On Barman server - copy to PostgreSQL server via rsync
# Replace <postgres-server> with your PostgreSQL server hostname/IP
rsync -av --progress /tmp/pitr_recovery/ postgres@<postgres-server>:/var/lib/postgresql/15/patroni1/

# Or use scp
scp -r /tmp/pitr_recovery/* postgres@<postgres-server>:/var/lib/postgresql/15/patroni1/
```

## Step 6: Configure PostgreSQL for Recovery

Create `recovery.signal` and configure recovery settings:

```bash
# On PostgreSQL server
DATA_DIR="/var/lib/postgresql/15/patroni1"

# Create recovery.signal file (PostgreSQL 12+)
sudo -u postgres touch "$DATA_DIR/recovery.signal"

# Configure recovery settings in postgresql.auto.conf
# See Step 7 in "Manual PITR Process for On-Premise Servers" section for details
```

## Step 7: Start PostgreSQL with Recovered Data

```bash
# On PostgreSQL server
DATA_DIR="/var/lib/postgresql/15/patroni1"
BACKUP_DIR="${DATA_DIR}.backup_$(date +%Y%m%d_%H%M%S)"

# Stop Patroni
sudo systemctl stop patroni
# Or if using supervisor
sudo supervisorctl stop patroni

# Ensure PostgreSQL is fully stopped
sudo systemctl stop postgresql 2>/dev/null || true
sudo pkill -9 postgres || true

# Wait for processes to stop
sleep 2

# Backup current data directory (if not already done)
if [ -d "$DATA_DIR" ]; then
    sudo mv "$DATA_DIR" "$BACKUP_DIR" || sudo cp -r "$DATA_DIR" "$BACKUP_DIR"
fi

# Set correct permissions
sudo chown -R postgres:postgres "$DATA_DIR"
sudo chmod 700 "$DATA_DIR"
sudo find "$DATA_DIR" -type f -exec chmod 600 {} \;
sudo find "$DATA_DIR" -type d -exec chmod 700 {} \;

# Start Patroni (which will start PostgreSQL)
sudo systemctl start patroni
# Or if using supervisor
sudo supervisorctl start patroni
```

## Step 8: Verify Recovery

```bash
# On PostgreSQL server
# Check recovery completed
psql -U postgres -h localhost -c "SELECT pg_is_in_recovery();"

# Should return 'f' (false) when recovery is complete

# Verify data matches expected state
# Run your verification queries
psql -U postgres -h localhost -c "SELECT COUNT(*) FROM your_table;"

# Compare with pre-PITR statistics if you saved them
```

## Step 9: Verify Data Integrity

```bash
# Check table counts match
docker exec db1 psql -U postgres -d maborak -p 5431 -h localhost -c "
SELECT 
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') as tables,
    (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'public') as columns,
    (SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables) as total_rows;
"

# Check specific tables
docker exec db1 psql -U postgres -d maborak -p 5431 -h localhost -c "
SELECT COUNT(*) FROM stress_table_001;
"
```

## Complete Example Workflow

```bash
# 1. List backups
docker exec barman barman list-backup db1

# 2. Choose backup (e.g., 20260104T153446)
BACKUP_ID="20260104T153446"

# 3. Recover to specific time
docker exec barman barman recover \
  --target-time "2026-01-04 15:45:00" \
  db1 $BACKUP_ID \
  /tmp/pitr_recovery

# 4. Verify recovery files
ls -lh /tmp/pitr_recovery/

# 5. Copy to container (if needed)
docker cp /tmp/pitr_recovery/. db1:/tmp/pitr_recovery/

# 6. Replace data directory (CAREFUL - backup first!)
docker exec db1 mv /var/lib/postgresql/15/patroni1 /var/lib/postgresql/15/patroni1.backup
docker exec db1 cp -r /tmp/pitr_recovery /var/lib/postgresql/15/patroni1
docker exec db1 chown -R postgres:postgres /var/lib/postgresql/15/patroni1

# 7. Restart container
docker-compose restart db1

# 8. Verify recovery
docker exec db1 psql -U postgres -p 5431 -h localhost -c "SELECT pg_is_in_recovery();"
./scripts/count_database_stats.sh
```

## Recovery Options

### Remote Recovery (Recover directly to PostgreSQL server)

```bash
docker exec barman barman recover \
  --remote-ssh-command "ssh postgres@db1" \
  --target-time "2026-01-04 15:45:00" \
  db1 <backup-id> \
  /var/lib/postgresql/15/patroni1_recovered
```

### Recovery with Custom Options

```bash
docker exec barman barman recover \
  --target-time "2026-01-04 15:45:00" \
  --get-wal \
  --no-check \
  db1 <backup-id> \
  /tmp/pitr_recovery
```

## Troubleshooting

### Recovery Stuck

```bash
# Check recovery logs
docker exec db1 tail -f /var/log/postgresql/*.log

# Check if WAL files are available
docker exec barman barman show-server db1 | grep last_archived
```

### Missing WAL Files

```bash
# List available WALs
docker exec barman ls -lh /data/pg-backup/db1/wals/

# Check WAL range in backup
docker exec barman barman show-backup db1 <backup-id> | grep -E "(Begin WAL|End WAL)"
```

### Recovery to Wrong Time

```bash
# Check recovery target in recovery.conf
docker exec db1 cat /var/lib/postgresql/15/patroni1/recovery.conf

# Verify target time is correct
```

## Important Notes

⚠️ **Warnings:**
- Always backup current data before recovery
- Recovery will overwrite existing data
- Ensure WAL files are available for target time
- Recovery time cannot be before backup start time
- Recovery time cannot be after last archived WAL

✅ **Best Practices:**
- Test PITR on a non-production environment first
- Document the exact recovery target before starting
- Verify data after recovery
- Keep recovery files until verification is complete
- Monitor recovery progress in logs

## Manual PITR Process for On-Premise Servers

This section describes the complete manual PITR process for on-premise PostgreSQL servers with Patroni, using Barman directly (not via Docker).

### Prerequisites

- Barman server accessible from PostgreSQL server
- SSH key-based authentication configured between PostgreSQL server and Barman
- PostgreSQL data directory path: `/var/lib/postgresql/15/patroni1` (adjust as needed)
- Patroni cluster name: `patroni1` (adjust as needed)
- Patroni configuration: `/etc/patroni/patroni.yml`

### Step 1: Verify Backup and Choose Target Time

```bash
# On Barman server
barman list-backup <server-name>
barman show-backup <server-name> <backup-id>

# Example
barman list-backup pg-primary
barman show-backup pg-primary 20260104T152519
```

### Step 2: Stop Patroni on Target Node

```bash
# On PostgreSQL server (target node)
sudo systemctl stop patroni
# Or if using supervisor
sudo supervisorctl stop patroni

# Verify Patroni is stopped
sudo supervisorctl status patroni
# Should show: STOPPED
```

### Step 3: Backup Current Data Directory

```bash
# On PostgreSQL server
DATA_DIR="/var/lib/postgresql/15/patroni1"
BACKUP_DIR="${DATA_DIR}.backup_$(date +%Y%m%d_%H%M%S)"

# Ensure PostgreSQL is fully stopped
sudo systemctl stop postgresql 2>/dev/null || true
sudo pkill -9 postgres || true

# Wait a moment for processes to stop
sleep 2

# Backup current data
sudo mv "$DATA_DIR" "$BACKUP_DIR" || sudo cp -r "$DATA_DIR" "$BACKUP_DIR"
echo "Current data backed up to: $BACKUP_DIR"
```

### Step 4: Perform PITR Recovery from Barman

```bash
# On Barman server
RECOVERY_DIR="/tmp/pitr_recovery_$(date +%Y%m%d_%H%M%S)"
BACKUP_ID="20260104T152519"
TARGET_TIME="2026-01-04 15:50:00"
SERVER_NAME="pg-primary"

# Create recovery directory
mkdir -p "$RECOVERY_DIR"
chmod 700 "$RECOVERY_DIR"

# Perform recovery
barman recover \
  --target-time "$TARGET_TIME" \
  "$SERVER_NAME" "$BACKUP_ID" \
  "$RECOVERY_DIR"

# Verify recovery files
ls -lh "$RECOVERY_DIR"
```

### Step 5: Copy Recovered Data to PostgreSQL Server

```bash
# On Barman server - copy to PostgreSQL server via rsync
# Replace <postgres-server> with your PostgreSQL server hostname/IP
rsync -av --progress "$RECOVERY_DIR/" postgres@<postgres-server>:/var/lib/postgresql/15/patroni1/

# Or use scp
scp -r "$RECOVERY_DIR"/* postgres@<postgres-server>:/var/lib/postgresql/15/patroni1/
```

### Step 6: Set Correct Permissions

```bash
# On PostgreSQL server
sudo chown -R postgres:postgres /var/lib/postgresql/15/patroni1
sudo chmod 700 /var/lib/postgresql/15/patroni1
sudo find /var/lib/postgresql/15/patroni1 -type f -exec chmod 600 {} \;
sudo find /var/lib/postgresql/15/patroni1 -type d -exec chmod 700 {} \;
```

### Step 7: Configure Recovery Settings

**Important:** You need to add the `restore_command` to fetch WAL files from Barman during recovery.

**Two methods are available:**

#### Method 1: barman-wal-restore (Recommended)

**Restore Command:**
```
restore_command = 'barman-wal-restore -U barman barman db2 %f %p'
```

**Replace:**
- `db2` → Your Barman server name

**Full configuration for `postgresql.auto.conf` (Method 1):**

```
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.

# Restore command options:
#   barman-wal-restore: barman-wal-restore -U barman barman db2 %f %p
#   barman get-wal: test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)
#
# Using: barman-wal-restore method

# Recovery settings (for reference):
# restore_command = 'barman-wal-restore -U barman barman db2 %f %p'
# recovery_target_timeline = 'latest'
# recovery_target_time = '2026-01-04 15:50:00+00:00'
# recovery_target_action = 'promote'

restore_command = 'barman-wal-restore -U barman barman db2 %f %p'
recovery_target_timeline = 'latest'
recovery_target_time = '2026-01-04 15:50:00+00:00'
recovery_target_action = 'promote'

# To start PostgreSQL manually for recovery, run:
# su - postgres -c "/usr/lib/postgresql/15/bin/postgres -D /var/lib/postgresql/15/patroni1 -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info"
```

#### Method 2: barman get-wal (Atomic-safe)

**Restore Command:**
```
restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)'
```

**Replace:**
- `barman` → Your Barman server hostname
- `db2` → Your Barman server name

**Full configuration for `postgresql.auto.conf` (Method 2):**

```
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.

# Restore command options:
#   barman-wal-restore: barman-wal-restore -U barman barman db2 %f %p
#   barman get-wal: test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)
#
# Using: barman get-wal method

# Recovery settings (for reference):
# restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)'
# recovery_target_timeline = 'latest'
# recovery_target_time = '2026-01-04 15:50:00+00:00'
# recovery_target_action = 'promote'

restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)'
recovery_target_timeline = 'latest'
recovery_target_time = '2026-01-04 15:50:00+00:00'
recovery_target_action = 'promote'

# To start PostgreSQL manually for recovery, run:
# su - postgres -c "/usr/lib/postgresql/15/bin/postgres -D /var/lib/postgresql/15/patroni1 -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info"
```

**Note:** Use `postgresql.auto.conf` for recovery settings. Do not modify `postgresql.conf` directly.

**Create recovery.signal file:**

```bash
# On PostgreSQL server
DATA_DIR="/var/lib/postgresql/15/patroni1"
sudo -u postgres touch "$DATA_DIR/recovery.signal"
sudo chmod 600 "$DATA_DIR/recovery.signal"
```

**Note:** Replace the following in the configuration above:
- `barman` with your Barman server hostname (for Method 2)
- `db2` with your Barman server name
- `2026-01-04 15:50:00+00:00` with your target recovery time

### Step 8: Remove Compressed WAL Files (if any)

```bash
# On PostgreSQL server
# Remove any compressed WAL files - restore_command will fetch them properly
sudo -u postgres find /var/lib/postgresql/15/patroni1/pg_wal -type f -size -1M -delete
```

### Step 9: Stop Other Cluster Nodes

```bash
# On each other node (db2, db3, db4, etc.)
# SSH to each node and stop Patroni
ssh postgres@db2 "sudo supervisorctl stop patroni"
ssh postgres@db3 "sudo supervisorctl stop patroni"
ssh postgres@db4 "sudo supervisorctl stop patroni"

# Or if using systemd
ssh postgres@db2 "sudo systemctl stop patroni"
```

### Step 10: Start PostgreSQL Recovery

```bash
# On PostgreSQL server (target node)
# Option A: Start PostgreSQL directly (to see recovery output)
sudo -u postgres /usr/lib/postgresql/15/bin/postgres \
  -D /var/lib/postgresql/15/patroni1 \
  -p 5432 \
  -c logging_collector=off \
  -c log_destination=stderr \
  -c log_min_messages=info

# Option B: Start via Patroni (recovery will happen automatically)
sudo systemctl start patroni
# Or
sudo supervisorctl start patroni
```

### Step 11: Monitor Recovery Progress

```bash
# On PostgreSQL server
# Check if in recovery
psql -U postgres -h localhost -p 5432 -c "SELECT pg_is_in_recovery();"

# Check recovery progress
psql -U postgres -h localhost -p 5432 -c "SELECT pg_last_wal_replay_lsn(), pg_last_wal_replay_receive_lsn();"

# Check recovery target
psql -U postgres -h localhost -p 5432 -c "SHOW recovery_target_time;"

# Monitor PostgreSQL logs
tail -f /var/log/postgresql/postgresql-15-main.log
```

### Step 12: Verify Target Node is Leader

```bash
# On PostgreSQL server (target node)
patronictl -c /etc/patroni/patroni.yml list

# Should show target node as Leader
# If not, promote it:
patronictl -c /etc/patroni/patroni.yml failover patroni1 --candidate <target-node> --force
```

### Step 13: Start Other Cluster Nodes

```bash
# On each other node
# SSH to each node and start Patroni
ssh postgres@db2 "sudo supervisorctl start patroni"
ssh postgres@db3 "sudo supervisorctl start patroni"
ssh postgres@db4 "sudo supervisorctl start patroni"

# Or if using systemd
ssh postgres@db2 "sudo systemctl start patroni"
```

### Step 14: Reinitialize Other Nodes

```bash
# On PostgreSQL server (target node - leader)
CLUSTER_NAME="patroni1"
TARGET_NODE="db1"  # Your target node name

# For each other node
for node in db2 db3 db4; do
    echo "Reinitializing $node..."
    
    # Check if Patroni is running on the node
    ssh postgres@$node "sudo supervisorctl status patroni" | grep -q RUNNING || {
        echo "Starting Patroni on $node..."
        ssh postgres@$node "sudo supervisorctl start patroni"
        sleep 5
    }
    
    # Reinitialize command
    REINIT_CMD="patronictl -c /etc/patroni/patroni.yml reinit $CLUSTER_NAME $node --force"
    echo "Executing: $REINIT_CMD"
    $REINIT_CMD
    sleep 2
done

# Monitor reinitialization progress
patronictl -c /etc/patroni/patroni.yml list
```

### Step 15: Verify Cluster Status

```bash
# On PostgreSQL server (any node)
patronictl -c /etc/patroni/patroni.yml list

# Should show:
# - Target node as Leader
# - Other nodes as Replica (or in reinitialization)
# - All nodes in sync
```

### Important Notes for On-Premise PITR

⚠️ **Before Starting:**
- Ensure SSH key authentication is configured between PostgreSQL server and Barman (for Method 2)
- For Method 1 (barman-wal-restore), ensure `barman-wal-restore` command is available on PostgreSQL server
- Verify Barman server name matches in `restore_command`
- Backup current data directory before recovery
- Stop all cluster nodes before starting recovery

⚠️ **During Recovery:**
- Monitor PostgreSQL logs for recovery progress
- Check WAL files are being fetched correctly
- Verify `restore_command` is working (check for errors in logs)

⚠️ **After Recovery:**
- Verify target node is leader
- Reinitialize other nodes to join cluster
- Monitor cluster status until all nodes are in sync
- Verify data integrity

### Troubleshooting On-Premise PITR

**SSH Connection Issues (Method 2):**
```bash
# Test SSH connection from PostgreSQL server to Barman
ssh -o BatchMode=yes barman@barman "barman get-wal db2 000000010000000000000001"

# Verify SSH key permissions (if using key-based auth)
chmod 600 /home/postgres/.ssh/barman_rsa
```

**barman-wal-restore Not Found (Method 1):**
```bash
# Check if barman-wal-restore is installed
which barman-wal-restore

# Install barman-cli if needed
# On Debian/Ubuntu: apt-get install barman-cli-cloud
# On RHEL/CentOS: yum install barman-cli-cloud
```

**WAL Files Not Found:**
```bash
# Check WAL path on Barman server
barman show-server db2 | grep wals_directory

# Verify WAL files exist
ls -lh /data/pg-backup/db2/wals/

# Check incoming directory (WALs waiting to be processed)
ls -lh /data/pg-backup/db2/incoming/
```

**Recovery Stuck:**
```bash
# Check PostgreSQL logs
tail -f /var/log/postgresql/postgresql-15-main.log

# Check if restore_command is being called
grep "restore_command" /var/log/postgresql/postgresql-15-main.log
```

## Quick Reference

```bash
# List backups
docker exec barman barman list-backup db1

# Show backup details
docker exec barman barman show-backup db1 <backup-id>

# Recover to time
docker exec barman barman recover --target-time "YYYY-MM-DD HH:MM:SS" db1 <backup-id> /path/to/recovery

# Recover to WAL
docker exec barman barman recover --target-wal <wal-file> db1 <backup-id> /path/to/recovery

# Recover to latest
docker exec barman barman recover --target-time "latest" db1 <backup-id> /path/to/recovery

# Check recovery status
docker exec db1 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Verify data
./scripts/count_database_stats.sh
```

