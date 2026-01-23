# PITR with Patroni Cluster - Best Practice Guide

## Recommended Approach: Isolated PITR Node

When performing PITR in a Patroni cluster, it's best to:
1. **Stop one replica node** (isolate it from the cluster)
2. **Apply PITR to the isolated node**
3. **Verify the recovery** on the isolated node
4. **Disconnect other nodes** (if needed)
5. **Start the PITR node** and promote it to leader

This approach:
- ✅ Avoids disrupting the current primary
- ✅ Allows testing PITR before promoting
- ✅ Provides a rollback path
- ✅ Minimizes cluster downtime

## Step-by-Step Process

### Step 1: Identify and Prepare a Replica Node

```bash
# Check current cluster status
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# Identify a replica node (e.g., db2, db3, or db4)
# We'll use db2 as example
TARGET_NODE="db2"
```

### Step 2: Stop Patroni Service (Keep Container Running)

```bash
# Option 1: Stop Patroni process (recommended - will stop PostgreSQL automatically)
docker exec $TARGET_NODE pkill -f "patroni /etc/patroni/patroni.yml"

# Option 2: Stop PostgreSQL directly
docker exec $TARGET_NODE su - postgres -c "pg_ctl -D ${PATRONI_DATA_DIR} stop"

# Option 3: Disable Patroni config (prevents auto-restart)
docker exec $TARGET_NODE mv /etc/patroni/patroni.yml /etc/patroni/patroni.yml.disabled
docker exec $TARGET_NODE pkill -HUP supervisord  # Reload supervisor

# Verify services are stopped
docker exec $TARGET_NODE ps aux | grep -E "(patroni|postgres)" | grep -v grep
```

### Step 4: Perform PITR on the Isolated Node

```bash
# Run PITR script targeting the isolated node
./scripts/perform_pitr.sh 20260104T152519 '2026-01-04 15:26:00' $TARGET_NODE

# Or manually:
# 1. Backup current data (container must be running for docker exec)
docker exec $TARGET_NODE mv /var/lib/postgresql/15/patroni2 /var/lib/postgresql/15/patroni2.backup

# 2. Copy recovered data (works even if PostgreSQL is stopped)
docker cp barman:/tmp/pitr_recovery_*/. $TARGET_NODE:/var/lib/postgresql/15/patroni2/

# 3. Set permissions
docker exec $TARGET_NODE chown -R postgres:postgres /var/lib/postgresql/15/patroni2
```

### Step 5: Start PostgreSQL and Complete Recovery

```bash
# Start PostgreSQL manually (Patroni is stopped, so it won't interfere)
docker exec $TARGET_NODE su - postgres -c "pg_ctl -D ${PATRONI_DATA_DIR} start"

# Monitor recovery progress
docker exec $TARGET_NODE tail -f /var/log/postgresql/*.log

# Check recovery status
docker exec $TARGET_NODE psql -U postgres -p 5432 -h localhost -c "SELECT pg_is_in_recovery();"

# Wait for recovery to complete (should return 'f' when done)
# Keep checking until it returns false
```

### Step 6: Verify PITR Data

```bash
# Verify data matches expected state
docker exec db2 psql -U postgres -d maborak -p 5432 -h localhost -c "
SELECT 
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public') as tables,
    (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'public') as columns,
    (SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables) as total_rows;
"

# Compare with pre-PITR statistics
cat db_stats_before_pitr_*.json
```

### Step 7: Prepare PITR Node as New Leader

```bash
# 1. Stop other nodes to isolate the cluster
docker-compose stop db1 db3 db4

# 2. Clear etcd cluster state (optional, if needed)
docker exec etcd1 etcdctl del --prefix /service/patroni/

# 3. Re-enable Patroni on PITR node
docker exec $TARGET_NODE mv /etc/patroni/patroni.yml.disabled /etc/patroni/patroni.yml

# 4. Restart supervisor (Patroni will start automatically)
docker exec $TARGET_NODE pkill -HUP supervisord

# 5. Wait for Patroni to initialize
sleep 10

# 6. Check cluster status
docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml list

# 7. If needed, manually promote to leader
docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml switchover --master $TARGET_NODE --candidate $TARGET_NODE --force
```

### Step 8: Rejoin Other Nodes (Optional)

If you want to rebuild the cluster with the PITR node as leader:

```bash
# 1. Clear data on other nodes (they're out of sync)
docker exec db1 rm -rf /var/lib/postgresql/15/patroni1/*
docker exec db3 rm -rf /var/lib/postgresql/15/patroni3/*
docker exec db4 rm -rf /var/lib/postgresql/15/patroni4/*

# 2. Start other nodes - they will sync from new leader
docker-compose start db1 db3 db4

# 3. Verify cluster status
docker exec db2 patronictl -c /etc/patroni/patroni.yml list
```

## Alternative: Complete Cluster Isolation

If you want to completely isolate the cluster during PITR:

```bash
# 1. Stop all nodes
docker-compose stop db1 db2 db3 db4

# 2. Stop etcd (prevents Patroni from managing cluster)
docker-compose stop etcd1 etcd2

# 3. Perform PITR on chosen node (e.g., db1)
./scripts/perform_pitr.sh <backup-id> <target-time> db1

# 4. Start only the PITR node
docker-compose start db1

# 5. Verify recovery
docker exec db1 psql -U postgres -p 5432 -h localhost -c "SELECT pg_is_in_recovery();"

# 6. Start etcd
docker-compose start etcd1 etcd2

# 7. Start Patroni on PITR node (it will become leader)
docker-compose restart db1

# 8. Rebuild other nodes as replicas
docker-compose start db2 db3 db4
```

## Important Considerations

### Patroni Configuration

Before starting recovery, ensure Patroni won't interfere:

```yaml
# In patroni.yml, temporarily disable:
bootstrap:
  dcs:
    # Comment out or modify to prevent auto-join
    # etcd_host: etcd1
    # etcd_port: 2379
```

### Recovery Configuration

The PITR recovery will create `postgresql.auto.conf` with:
```conf
restore_command = 'barman get-wal -P db1 %f > %p'
recovery_target_time = '2026-01-04 15:26:00+00:00'
```

### Timeline Considerations

- **Timeline divergence**: After PITR, the node will be on a new timeline
- **Replication**: Other nodes cannot replicate from a PITR node without reinitialization
- **Cluster state**: etcd may need to be cleared if cluster state is inconsistent

## Quick Reference Commands

```bash
# 1. Stop Patroni on target node (keeps container running)
docker exec db2 pkill -f "patroni /etc/patroni/patroni.yml"
docker exec db2 mv /etc/patroni/patroni.yml /etc/patroni/patroni.yml.disabled

# 2. Perform PITR
./scripts/perform_pitr.sh <backup-id> <target-time> db2

# 3. Apply recovery
docker exec db2 mv /var/lib/postgresql/15/patroni2 /var/lib/postgresql/15/patroni2.backup
docker cp barman:/tmp/pitr_recovery_*/. db2:/var/lib/postgresql/15/patroni2/
docker exec db2 chown -R postgres:postgres /var/lib/postgresql/15/patroni2

# 4. Start PostgreSQL and verify
docker exec db2 su - postgres -c "pg_ctl -D /var/lib/postgresql/15/patroni2 start"
docker exec db2 psql -U postgres -p 5432 -h localhost -c "SELECT pg_is_in_recovery();"

# 5. Stop other nodes (optional - to isolate cluster)
docker-compose stop db1 db3 db4

# 6. Clear etcd state (optional - if cluster state is inconsistent)
docker exec etcd1 etcdctl del --prefix /service/patroni/

# 7. Re-enable Patroni and promote PITR node
docker exec db2 mv /etc/patroni/patroni.yml.disabled /etc/patroni/patroni.yml
docker exec db2 pkill -HUP supervisord
docker exec db2 patronictl -c /etc/patroni/patroni.yml list
```

## Note: `demote-cluster` is NOT for PITR

The `patronictl demote-cluster` command is used to make your cluster a **standby cluster** that replicates from another primary cluster. It requires connection information to a remote primary and is NOT what you need for PITR.

For PITR, simply:
- Stop Patroni on individual nodes, OR
- Stop the entire cluster, OR  
- Clear etcd cluster state

You don't need to "demote" the cluster.

## Safety Checklist

- [ ] Backup current cluster state
- [ ] Stop chosen replica node
- [ ] Disable Patroni on PITR node
- [ ] Perform PITR recovery
- [ ] Verify recovery completed
- [ ] Verify data matches expected state
- [ ] Stop other cluster nodes
- [ ] Start PITR node as new leader
- [ ] Verify cluster status
- [ ] Rebuild other nodes as replicas (if needed)

