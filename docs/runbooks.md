# Operational Runbooks

DBA-style runbooks for common operational procedures. Each runbook includes preconditions, step-by-step commands, verification, rollback, and "red flags."

---

## Runbook: Planned Switchover

**Goal**: Gracefully transfer leadership from current leader to chosen replica.

**Use Cases**:
- Maintenance on current leader
- Load balancing
- Testing failover procedures

### Preconditions

- ✅ Cluster is healthy (`./check_stack.sh` passes)
- ✅ Target replica is caught up (lag < 1MB)
- ✅ No long-running transactions on leader
- ✅ Application can tolerate brief connection interruption (~5 seconds)

### Steps

**1. Identify current leader:**
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader
# Expected: | db1 | db1:5431 | Leader | running | ...
```

**2. Verify target replica is ready:**
```bash
# Check replication lag
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Verify target is replica (not in recovery)
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false) - replicas are not in recovery, they're streaming
```

**3. Perform switchover:**
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover \
  patroni1 \
  --master db1 \
  --candidate db2
```

**4. Verify switchover completed:**
```bash
# Wait 10 seconds
sleep 10

# Check new leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader
# Expected: | db2 | db2:5431 | Leader | running | ...

# Verify old leader is now replica
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep db1
# Expected: | db1 | db1:5431 | Replica | running | ...
```

**5. Verify HAProxy routing:**
```bash
# Connect via HAProxy write endpoint
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT inet_server_addr();"
# Should return db2's IP (new leader)
```

### Verification Commands

```bash
# Cluster status
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# HAProxy stats
curl http://localhost:5553/stats | grep -A 5 "patroni_write_backend"

# Test write operation
psql -h localhost -p 5551 -U postgres -d maborak -c "CREATE TABLE test_switchover (id INT); DROP TABLE test_switchover;"
```

### Rollback

**If switchover fails mid-process:**

1. Check cluster status:
   ```bash
   docker exec db1 patronictl -c /etc/patroni/patroni.yml list
   ```

2. If cluster is inconsistent, restart Patroni on affected nodes:
   ```bash
   docker exec db1 supervisorctl restart patroni
   docker exec db2 supervisorctl restart patroni
   ```

3. Wait for cluster to stabilize (~30 seconds)

4. Verify leader is consistent:
   ```bash
   docker exec db1 patronictl -c /etc/patroni/patroni.yml list
   ```

### Red Flags / Do Not Do This

❌ **Do not switchover during:**
- Large data loads
- Long-running transactions
- Critical business operations
- Backup operations

❌ **Do not force switchover if:**
- Replica has high lag (> 1MB)
- Replica is not ready (check `pg_is_in_recovery()`)
- Cluster is unstable

❌ **Do not manually promote** (use `patronictl switchover`):
- Manual promotion bypasses Patroni coordination
- Can cause split-brain
- Breaks cluster state

---

## Runbook: Failover Drill

**Goal**: Test automatic failover by simulating leader crash.

**Use Cases**:
- Validating failover procedures
- Testing application resilience
- Capacity planning

### Preconditions

- ✅ Cluster is healthy
- ✅ At least one replica is available
- ✅ Replicas are caught up (lag < 1MB)
- ✅ Test environment (not production)

### Steps

**1. Identify current leader:**
```bash
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
echo "Current leader: $LEADER"
```

**2. Identify replicas:**
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Replica
```

**3. Simulate leader crash:**
```bash
# Stop leader container (simulates crash)
docker stop $LEADER
```

**4. Monitor failover:**
```bash
# Watch cluster status (run in another terminal)
watch -n 2 "docker exec db2 patronictl -c /etc/patroni/patroni.yml list"
```

**5. Wait for failover (~30-40 seconds):**
```bash
# Check new leader
sleep 35
docker exec db2 patronictl -c /etc/patroni/patroni.yml list | grep Leader
# Expected: New leader should be one of the replicas
```

**6. Verify new leader:**
```bash
NEW_LEADER=$(docker exec db2 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
echo "New leader: $NEW_LEADER"

# Verify writes work
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT version();"
```

**7. Restart old leader (it will rejoin as replica):**
```bash
docker start $LEADER
sleep 15

# Verify it rejoined as replica
docker exec db2 patronictl -c /etc/patroni/patroni.yml list | grep $LEADER
# Expected: | $LEADER | ... | Replica | running | ...
```

### Verification Commands

```bash
# Cluster status
docker exec db2 patronictl -c /etc/patroni/patroni.yml list

# Verify no data loss (if you had test data)
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT COUNT(*) FROM your_test_table;"

# Check replication slots
docker exec $NEW_LEADER psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

### Rollback

**If failover doesn't complete:**

1. Check etcd health:
   ```bash
   docker exec etcd1 etcdctl endpoint health
   docker exec etcd2 etcdctl endpoint health
   ```

2. Restart leader:
   ```bash
   docker start $LEADER
   ```

3. Wait for cluster to stabilize:
   ```bash
   sleep 30
   docker exec db1 patronictl -c /etc/patroni/patroni.yml list
   ```

### Red Flags / Do Not Do This

❌ **Do not run in production** without:
- Maintenance window
- Application coordination
- Backup verification

❌ **Do not stop multiple nodes** simultaneously:
- May cause quorum loss
- Cluster may become unavailable

❌ **Do not stop etcd during failover**:
- Cluster coordination will fail
- May cause split-brain

---

## Runbook: Backup Workflow

**Goal**: Create base backup and verify it's usable.

**Use Cases**:
- Regular backup schedule
- Before major changes
- Disaster recovery preparation

### Preconditions

- ✅ Cluster is healthy
- ✅ Leader is identified
- ✅ Barman is accessible
- ✅ Sufficient disk space on Barman

### Steps

**1. Identify leader:**
```bash
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
echo "Backing up leader: $LEADER"
```

**2. Verify WAL archiving is active:**
```bash
# Check archive log
docker exec $LEADER tail -5 /var/log/postgresql/archive.log

# Check Barman archiver status
docker exec barman barman status $LEADER | grep -E "(Failures|Last archived)"
# Expected: Failures: 0, Last archived shows recent time
```

**3. Create backup:**
```bash
docker exec barman barman backup $LEADER
```

**4. Monitor backup progress:**
```bash
# Watch backup status
watch -n 2 "docker exec barman barman list-backup $LEADER | head -3"
```

**5. Verify backup:**
```bash
# Get backup ID
BACKUP_ID=$(docker exec barman barman list-backup $LEADER | head -2 | tail -1 | awk '{print $2}')
echo "Backup ID: $BACKUP_ID"

# Show backup details
docker exec barman barman show-backup $LEADER $BACKUP_ID

# Verify backup status
docker exec barman barman check $LEADER
```

**6. Test backup (optional but recommended):**
```bash
# List WALs available for this backup
docker exec barman barman list-wals $LEADER | head -10

# Verify backup is not corrupted (barman check does this)
docker exec barman barman check $LEADER
```

### Verification Commands

```bash
# Backup exists and is DONE
docker exec barman barman list-backup $LEADER

# Backup details
docker exec barman barman show-backup $LEADER $BACKUP_ID

# Barman server health
docker exec barman barman check $LEADER
```

### Rollback

**If backup fails:**

1. Check Barman logs:
   ```bash
   docker exec barman tail -50 /var/log/barman/barman.log
   ```

2. Check disk space:
   ```bash
   docker exec barman df -h /data/pg-backup
   ```

3. Check SSH connectivity:
   ```bash
   bash scripts/test_ssh_to_barman.sh
   ```

4. Retry backup:
   ```bash
   docker exec barman barman backup $LEADER
   ```

### Red Flags / Do Not Do This

❌ **Do not backup during:**
- High write load (may slow down database)
- Long-running transactions (backup may wait)
- Maintenance operations

❌ **Do not delete old backups** without:
- Verifying newer backups exist
- Checking retention policy
- Understanding recovery requirements

❌ **Do not backup replicas** (backup leader only):
- Replicas may have incomplete data
- Leader has authoritative state

---

## Runbook: PITR Workflow

**Goal**: Recover database to specific point in time.

**Use Cases**:
- Accidental data deletion
- Data corruption
- Restore to known good state

### Preconditions

- ✅ Backup exists (`barman list-backup <server>`)
- ✅ WAL archiving was active during target time
- ✅ WAL files available for target time
- ✅ Target node available (or can be stopped)

### Steps

**1. Identify backup:**
```bash
# List available backups
docker exec barman barman list-backup db1

# Show backup details
BACKUP_ID="20260123T120000"
docker exec barman barman show-backup db1 $BACKUP_ID
```

**2. Verify WAL availability:**
```bash
# Check WAL archiving status
docker exec barman barman status db1

# List WALs
docker exec barman barman list-wals db1 | head -20
```

**3. Choose target node:**
```bash
# Prefer replica (isolates from cluster)
TARGET_NODE="db2"
```

**4. Perform PITR (Automated - Recommended):**
```bash
bash scripts/perform_pitr.sh $BACKUP_ID '2026-01-23 12:30:00' \
  --server db1 \
  --target $TARGET_NODE \
  --restore \
  --wal-method barman-wal-restore \
  --auto-start
```

**5. Verify recovery:**
```bash
# Check recovery completed
docker exec $TARGET_NODE psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false)

# Verify data
docker exec $TARGET_NODE psql -U postgres -d maborak -c "SELECT COUNT(*) FROM your_table;"
```

**6. Verify cluster status:**
```bash
docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml list
# Should show $TARGET_NODE as Leader
```

### Verification Commands

```bash
# Recovery status
docker exec $TARGET_NODE psql -U postgres -c "SELECT pg_is_in_recovery();"

# Data verification
bash scripts/count_database_stats.sh $TARGET_NODE

# Cluster status
docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml list
```

### Rollback

**If PITR fails or wrong time:**

1. Stop target node:
   ```bash
   docker exec $TARGET_NODE supervisorctl stop patroni
   ```

2. Restore from backup (script creates backup automatically):
   ```bash
   # Script backs up to ${PATRONI_DATA_DIR}.backup_${TIMESTAMP}
   # Restore from backup
   docker exec $TARGET_NODE mv ${PATRONI_DATA_DIR}.backup_* ${PATRONI_DATA_DIR}
   ```

3. Restart node:
   ```bash
   docker exec $TARGET_NODE supervisorctl start patroni
   ```

### Red Flags / Do Not Do This

❌ **Do not recover to time before backup:**
- Recovery will fail
- Script validates this, but manual recovery may not

❌ **Do not recover on leader without stopping it first:**
- May cause cluster split-brain
- Always use `--target` flag or stop node manually

❌ **Do not skip WAL gap warnings:**
- Recovery will fail at gap
- Check WAL availability before proceeding

❌ **Do not recover during active operations:**
- Stop applications first
- Coordinate with team

**See**: `docs/pitr.md` and `docs/tools/perform_pitr.md` for comprehensive PITR documentation.

---

## Runbook: Replica Rebuild

**Goal**: Reinitialize a replica that's fallen behind or corrupted.

**Use Cases**:
- Replica corruption
- Replica too far behind (pg_rewind not possible)
- Fresh replica setup

### Preconditions

- ✅ Leader is healthy
- ✅ Target replica can be stopped
- ✅ Sufficient disk space
- ✅ Network connectivity

### Steps

**1. Identify leader and target:**
```bash
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
TARGET="db2"
echo "Leader: $LEADER, Target: $TARGET"
```

**2. Verify leader is ready:**
```bash
docker exec $LEADER psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false - leader is not in recovery)
```

**3. Perform reinit:**
```bash
docker exec $LEADER patronictl -c /etc/patroni/patroni.yml reinit \
  patroni1 $TARGET --force
```

**4. Monitor reinit progress:**
```bash
# Watch cluster status
watch -n 2 "docker exec $LEADER patronictl -c /etc/patroni/patroni.yml list"
```

**5. Verify replica is caught up:**
```bash
# Wait for reinit to complete (~5-10 minutes for large databases)
# Check replication lag
docker exec $TARGET psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Verify replica status
docker exec $LEADER patronictl -c /etc/patroni/patroni.yml list | grep $TARGET
# Expected: | $TARGET | ... | Replica | running | ...
```

### Verification Commands

```bash
# Cluster status
docker exec $LEADER patronictl -c /etc/patroni/patroni.yml list

# Replication lag
docker exec $TARGET psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Replication slots
docker exec $LEADER psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name LIKE '%$TARGET%';"
```

### Rollback

**If reinit fails:**

1. Check logs:
   ```bash
   docker logs $TARGET | tail -50
   ```

2. Check disk space:
   ```bash
   docker exec $TARGET df -h /var/lib/postgresql
   ```

3. Retry reinit:
   ```bash
   docker exec $LEADER patronictl -c /etc/patroni/patroni.yml reinit \
     patroni1 $TARGET --force
   ```

### Red Flags / Do Not Do This

❌ **Do not reinit during:**
- High write load (slows down leader)
- Backup operations
- Other maintenance

❌ **Do not reinit multiple replicas simultaneously:**
- Overloads leader
- May cause performance issues

❌ **Do not force reinit if:**
- Replica is healthy (use pg_rewind instead if possible)
- Leader is unstable

---

## Runbook: Cluster Health Check

**Goal**: Comprehensive health verification of entire stack.

**Use Cases**:
- After startup
- Before operations
- Troubleshooting
- Regular monitoring

### Preconditions

- ✅ Stack is running (`docker-compose ps`)

### Steps

**1. Run automated health check:**
```bash
./check_stack.sh
```

**2. Verify all checks pass:**
- ✅ Containers running
- ✅ etcd healthy
- ✅ Patroni API responding
- ✅ PostgreSQL ready
- ✅ HAProxy valid
- ✅ SSH connectivity

**3. Check cluster status:**
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

**4. Verify replication:**
```bash
# On leader, check replication slots
docker exec db1 psql -U postgres -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag FROM pg_replication_slots;"

# On replicas, check lag
for node in db2 db3 db4; do
  echo "=== $node ==="
  docker exec $node psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
done
```

**5. Verify WAL archiving:**
```bash
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
docker exec $LEADER tail -10 /var/log/postgresql/archive.log

docker exec barman barman status $LEADER
```

### Verification Commands

```bash
# Full health check
./check_stack.sh

# Detailed stack info
bash scripts/get_stack_info.sh --human

# Cluster status
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

### Red Flags / Do Not Do This

❌ **Do not proceed if:**
- Any container is not running
- etcd is unhealthy
- Replication lag > 1MB
- WAL archiving has failures

❌ **Do not ignore warnings:**
- SSH connectivity issues → WAL archiving will fail
- High replication lag → Failover may promote stale replica

---

## Runbook: Troubleshooting Common Issues

### Issue: Replica Not Catching Up

**Symptoms**:
- Replication lag increasing
- Replica shows "streaming" but lagged

**Diagnosis**:
```bash
# Check lag
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Check replication slot
docker exec db1 psql -U postgres -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag FROM pg_replication_slots;"

# Check PostgreSQL logs
docker logs db2 | grep -i "replication\|error"
```

**Fix**:
```bash
# If lag is too high, reinit replica
docker exec db1 patronictl -c /etc/patroni/patroni.yml reinit patroni1 db2 --force
```

---

### Issue: WAL Archiving Failing

**Symptoms**:
- Archive log shows errors
- Barman shows failures
- WALs not appearing in Barman

**Diagnosis**:
```bash
# Check archive log
docker exec db1 tail -20 /var/log/postgresql/archive.log

# Check SSH connectivity
bash scripts/test_ssh_to_barman.sh

# Check Barman status
docker exec barman barman status db1
```

**Fix**:
```bash
# Fix SSH keys if needed
bash scripts/setup_ssh_keys.sh

# Restart PostgreSQL to retry archiving
docker exec db1 supervisorctl restart patroni
```

---

### Issue: Cluster Split-Brain

**Symptoms**:
- Multiple nodes claim to be leader
- etcd shows inconsistent state

**Diagnosis**:
```bash
# Check cluster status from each node
for node in db1 db2 db3 db4; do
  echo "=== $node ==="
  docker exec $node patronictl -c /etc/patroni/patroni.yml list
done

# Check etcd
docker exec etcd1 etcdctl get --prefix /patroni1/leader
```

**Fix**:
```bash
# Stop all nodes
docker-compose stop db1 db2 db3 db4

# Clear etcd cluster state
docker exec etcd1 etcdctl del --prefix /patroni1/

# Restart nodes
docker-compose start db1 db2 db3 db4

# Wait for cluster to stabilize
sleep 30
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

---

## Proposed Makefile Targets

The following Make targets would enhance operational workflows:

### Health & Verification

```makefile
.PHONY: check health
check:
	@./check_stack.sh

health: check
	@echo "=== Extended Health Check ==="
	@bash scripts/get_stack_info.sh --human
```

### Patroni / HA

```makefile
.PHONY: patroni-list switchover failover-drill reinit-replica

patroni-list:
	@docker exec db1 patronictl -c /etc/patroni/patroni.yml list

switchover:
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make switchover TARGET=db2"; \
		exit 1; \
	fi
	@LEADER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	docker exec $$LEADER patronictl -c /etc/patroni/patroni.yml switchover patroni1 --master $$LEADER --candidate $(TARGET)

failover-drill:
	@echo "⚠️  This will stop the current leader. Continue? (y/N)"
	@read -r confirm && [ "$$confirm" = "y" ] || exit 1
	@LEADER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	echo "Stopping leader: $$LEADER"; \
	docker stop $$LEADER; \
	echo "Waiting for failover..."; \
	sleep 35; \
	docker exec db2 patronictl -c /etc/patroni/patroni.yml list

reinit-replica:
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make reinit-replica NODE=db2"; \
		exit 1; \
	fi
	@LEADER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	docker exec $$LEADER patronictl -c /etc/patroni/patroni.yml reinit patroni1 $(NODE) --force
```

### Backup & Restore

```makefile
.PHONY: backup backups restore pitr

backup:
	@if [ -z "$(SERVER)" ]; then \
		SERVER=$$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	else \
		SERVER=$(SERVER); \
	fi
	@echo "Creating backup of $$SERVER..."
	@docker exec barman barman backup $$SERVER
	@echo "Backup created. List backups with: make backups SERVER=$$SERVER"

backups:
	@if [ -z "$(SERVER)" ]; then \
		echo "Usage: make backups SERVER=db1"; \
		exit 1; \
	fi
	@docker exec barman barman list-backup $(SERVER)

restore:
	@if [ -z "$(BACKUP_ID)" ] || [ -z "$(TARGET_TIME)" ]; then \
		echo "Usage: make restore BACKUP_ID=xxx TARGET_TIME='2026-01-23 12:30:00' TARGET=db2"; \
		exit 1; \
	fi
	@bash scripts/perform_pitr.sh $(BACKUP_ID) "$(TARGET_TIME)" \
		--server $(SERVER) \
		--target $(TARGET) \
		--restore \
		--wal-method barman-wal-restore

pitr: restore
	@echo "PITR initiated. See docs/pitr.md for details."
```

### UX Polish

```makefile
.PHONY: help shell psql psql-replica config destroy

help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

shell:
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make shell NODE=db1"; \
		exit 1; \
	fi
	@docker exec -it $(NODE) bash

psql:
	@psql -h localhost -p 5551 -U postgres -d maborak

psql-replica:
	@psql -h localhost -p 5552 -U postgres -d maborak

config:
	@echo "=== Environment Variables ==="
	@cat .env 2>/dev/null || echo "No .env file (using defaults)"
	@echo ""
	@echo "=== Port Configuration ==="
	@echo "HAProxy Write: $${HAPROXY_WRITE_PORT:-5551}"
	@echo "HAProxy Read: $${HAPROXY_READ_PORT:-5552}"
	@echo "PostgreSQL (db1): $${PATRONI_DB1_PORT:-15431}"

destroy:
	@echo "⚠️  WARNING: This will destroy ALL data!"
	@echo "Type 'DELETE' to confirm:"
	@read -r confirm && [ "$$confirm" = "DELETE" ] || exit 1
	@docker-compose down -v
	@docker system prune -f
	@echo "Stack destroyed."
```

**Note**: These are proposed targets. Current Makefile has basic targets only. See existing `Makefile` for implemented targets.

---

## Emergency Procedures

### Complete Cluster Failure

**Scenario**: All nodes down, etcd down, data potentially corrupted.

**Recovery Steps**:

1. **Assess damage:**
   ```bash
   docker-compose ps
   docker logs db1 | tail -50
   ```

2. **Restart etcd:**
   ```bash
   docker-compose start etcd1 etcd2
   sleep 5
   docker exec etcd1 etcdctl endpoint health
   ```

3. **Clear cluster state (if corrupted):**
   ```bash
   docker exec etcd1 etcdctl del --prefix /patroni1/
   ```

4. **Start nodes one by one:**
   ```bash
   docker-compose start db1
   sleep 10
   docker exec db1 patronictl -c /etc/patroni/patroni.yml list
   
   docker-compose start db2 db3 db4
   sleep 15
   docker exec db1 patronictl -c /etc/patroni/patroni.yml list
   ```

5. **If data is corrupted, restore from backup:**
   ```bash
   # See PITR runbook
   bash scripts/perform_pitr.sh <backup-id> latest --server db1 --target db1 --restore
   ```

---

## Maintenance Windows

### Planned Maintenance Checklist

**Before Maintenance:**
- [ ] Create backup
- [ ] Verify backup (`barman check`)
- [ ] Document current cluster state
- [ ] Notify stakeholders
- [ ] Schedule maintenance window

**During Maintenance:**
- [ ] Perform switchover if needed
- [ ] Execute maintenance tasks
- [ ] Verify cluster health after each step

**After Maintenance:**
- [ ] Run `./check_stack.sh`
- [ ] Verify replication
- [ ] Test application connectivity
- [ ] Document changes

---

## References

- **Patroni Operations**: https://patroni.readthedocs.io/en/latest/rest_api.html
- **PostgreSQL Replication**: https://www.postgresql.org/docs/15/high-availability.html
- **Barman Operations**: https://www.pgbarman.org/documentation/
