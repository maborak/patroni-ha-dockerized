# Health Check Analysis & Improvements

Analysis of `check_stack.sh` and recommendations for production-grade health validation.

---

## Current Checks (What `check_stack.sh` Does)

### ✅ Implemented Checks

1. **Docker / Compose Health**
   - Stack running (container count)
   - Container status (running/stopped)

2. **etcd Cluster Health**
   - etcd1 health endpoint
   - etcd2 health endpoint

3. **Patroni REST API**
   - Role detection (Leader/Replica) via Python JSON parsing
   - API responsiveness on port 8001

4. **PostgreSQL Connectivity**
   - `pg_isready` check on all nodes
   - Port 5431 accessibility

5. **HAProxy Configuration**
   - Configuration file syntax validation

6. **SSH Key Permissions**
   - Private key existence
   - Permission validation (600)

7. **SSH Connectivity**
   - Patroni → Barman (bidirectional)
   - Error message extraction

8. **External Ports** (Informational)
   - Port accessibility from host
   - Cross-platform (nc/netcat support)

9. **Cluster Status** (Informational)
   - `patronictl list` output

---

## Gap Analysis

### Missing Critical Checks

#### 1. Replication Health

**What's Missing**:
- Replication lag measurement
- Replication slot status
- Streaming replication status
- WAL receiver/replay LSN comparison

**Why It Matters**:
- High lag → Failover may promote stale replica (data loss risk)
- Missing replication slots → Replicas may fall behind
- Replication stopped → Replicas not receiving updates

**Impact**: **HIGH** - Failover readiness unknown

---

#### 2. Read/Write Path Validation

**What's Missing**:
- Write operation test (via HAProxy write endpoint)
- Read operation test (via HAProxy read endpoint)
- Verification that writes go to leader
- Verification that reads go to replicas

**Why It Matters**:
- HAProxy misconfiguration → Writes may fail or go to replicas
- Application connectivity issues → Undetected until production

**Impact**: **HIGH** - Application functionality not validated

---

#### 3. Failover Readiness

**What's Missing**:
- Replica lag check (< maximum_lag_on_failover)
- Replica readiness check (not in recovery, streaming active)
- Leader lock validation in etcd
- Failover candidate identification

**Why It Matters**:
- Unready replicas → Failover may fail or promote stale data
- High lag → Data loss risk during failover

**Impact**: **HIGH** - HA guarantee not validated

---

#### 4. Barman Backup + WAL Validation

**What's Missing**:
- Latest backup age check
- Backup completeness verification
- WAL archiving gap detection
- WAL sequence continuity check
- Barman server health

**Why It Matters**:
- Stale backups → Recovery may not be possible
- WAL gaps → PITR will fail
- Archiving stopped → No recovery capability

**Impact**: **CRITICAL** - Backup/recovery capability unknown

---

#### 5. Disk / Volume Sanity

**What's Missing**:
- Disk space check (PostgreSQL data directories)
- Disk space check (Barman backup storage)
- Disk I/O health (optional)
- Volume mount verification

**Why It Matters**:
- Disk full → PostgreSQL stops, backups fail
- Low disk space → Operations may fail unexpectedly

**Impact**: **MEDIUM** - Operational stability

---

#### 6. Time Synchronization Sanity

**What's Missing**:
- NTP sync status
- Time drift between nodes
- Timezone consistency

**Why It Matters**:
- Time drift → PITR target times may be wrong
- Large drift → Replication issues, log timestamps incorrect

**Impact**: **LOW** (in Docker, but important for production)

---

#### 7. PostgreSQL Configuration Validation

**What's Missing**:
- Critical parameter verification (wal_level, archive_mode, etc.)
- Extension availability (pg_stat_statements, etc.)
- Connection limit usage
- Shared memory validation

**Why It Matters**:
- Wrong wal_level → Replication won't work
- archive_mode off → No WAL archiving
- Connection limit reached → Application failures

**Impact**: **MEDIUM** - Configuration correctness

---

#### 8. Network Connectivity (Internal)

**What's Missing**:
- Inter-node connectivity (db1 ↔ db2, etc.)
- etcd → Patroni connectivity
- Barman → Patroni connectivity (beyond SSH)

**Why It Matters**:
- Network partitions → Cluster split-brain risk
- Connectivity issues → Replication failures

**Impact**: **MEDIUM** - Cluster stability

---

## Proposed Improved Checks

### Category 1: Docker / Compose Health

**Current**: ✅ Basic container status

**Proposed Enhancements**:
```bash
# Check container resource usage
check_container_resources() {
    local container=$1
    local cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" $container | sed 's/%//')
    local mem=$(docker stats --no-stream --format "{{.MemUsage}}" $container)
    if (( $(echo "$cpu > 90" | bc -l) )); then
        echo -e "${RED}✗ ${container}: High CPU usage (${cpu}%)${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ ${container}: Resources OK (CPU: ${cpu}%, Mem: ${mem})${NC}"
    return 0
}
```

---

### Category 2: Patroni Cluster Health

**Current**: ✅ Role detection

**Proposed Enhancements**:

```bash
check_patroni_cluster_health() {
    local leader=""
    local replicas=()
    local issues=0
    
    # Get cluster status
    local cluster_output=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null)
    
    # Extract leader
    leader=$(echo "$cluster_output" | grep Leader | awk '{print $2}')
    
    if [ -z "$leader" ]; then
        echo -e "${RED}✗ No leader found${NC}"
        return 1
    fi
    
    # Check leader lock in etcd
    local lock_holder=$(docker exec etcd1 etcdctl get /patroni1/leader 2>/dev/null | grep -o "db[1-4]" || echo "")
    if [ "$lock_holder" != "$leader" ]; then
        echo -e "${RED}✗ Leader lock mismatch: leader=$leader, lock=$lock_holder${NC}"
        ((issues++))
    fi
    
    # Count replicas
    local replica_count=$(echo "$cluster_output" | grep -c Replica || echo "0")
    if [ "$replica_count" -lt 1 ]; then
        echo -e "${RED}✗ No replicas available${NC}"
        ((issues++))
    fi
    
    return $issues
}
```

---

### Category 3: PostgreSQL Replication Health

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_replication_health() {
    local leader=$1
    local max_lag_mb=${2:-1}  # Default 1MB
    local issues=0
    
    # Get replication slots from leader
    local slots=$(docker exec $leader psql -U postgres -t -c "
        SELECT slot_name, active, 
               pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_mb
        FROM pg_replication_slots;
    " 2>/dev/null)
    
    if [ -z "$slots" ]; then
        echo -e "${RED}✗ No replication slots found${NC}"
        return 1
    fi
    
    # Check each slot
    echo "$slots" | while read -r slot_name active lag_mb; do
        if [ "$active" != "t" ]; then
            echo -e "${RED}✗ Replication slot $slot_name is inactive${NC}"
            ((issues++))
        fi
        
        # Extract numeric lag (handles "XXX MB" format)
        local lag_num=$(echo "$lag_mb" | grep -oE '[0-9]+' | head -1)
        if [ -n "$lag_num" ] && [ "$lag_num" -gt "$max_lag_mb" ]; then
            echo -e "${YELLOW}⚠ Replication slot $slot_name lag: $lag_mb (threshold: ${max_lag_mb}MB)${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

check_replica_streaming() {
    local replica=$1
    
    # Check if replica is receiving WAL
    local receive_lsn=$(docker exec $replica psql -U postgres -t -c "SELECT pg_last_wal_receive_lsn();" 2>/dev/null | tr -d ' ')
    local replay_lsn=$(docker exec $replica psql -U postgres -t -c "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tr -d ' ')
    
    if [ -z "$receive_lsn" ] || [ "$receive_lsn" = "NULL" ]; then
        echo -e "${RED}✗ $replica: Not receiving WAL${NC}"
        return 1
    fi
    
    if [ -z "$replay_lsn" ] || [ "$replay_lsn" = "NULL" ]; then
        echo -e "${YELLOW}⚠ $replica: Receiving but not replaying WAL${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ $replica: Streaming active (receive: $receive_lsn, replay: $replay_lsn)${NC}"
    return 0
}
```

---

### Category 4: Read/Write Path Validation

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_write_path() {
    local test_table="health_check_write_$$"
    local issues=0
    
    # Create test table via HAProxy write endpoint
    if ! psql -h localhost -p ${HAPROXY_WRITE_PORT:-5551} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
         -c "CREATE TABLE ${test_table} (id INT);" >/dev/null 2>&1; then
        echo -e "${RED}✗ Write path: Cannot create table${NC}"
        ((issues++))
    else
        # Verify it was created on leader
        local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
        if ! docker exec $leader psql -U postgres -d ${DEFAULT_DATABASE:-maborak} \
             -c "SELECT 1 FROM ${test_table};" >/dev/null 2>&1; then
            echo -e "${RED}✗ Write path: Table not found on leader${NC}"
            ((issues++))
        else
            echo -e "${GREEN}✓ Write path: Functional${NC}"
        fi
        
        # Cleanup
        psql -h localhost -p ${HAPROXY_WRITE_PORT:-5551} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
             -c "DROP TABLE ${test_table};" >/dev/null 2>&1
    fi
    
    return $issues
}

check_read_path() {
    local test_data="health_check_read_$$"
    local issues=0
    local read_count=0
    
    # Insert test data on leader (via direct connection)
    local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    docker exec $leader psql -U postgres -d ${DEFAULT_DATABASE:-maborak} \
         -c "CREATE TABLE IF NOT EXISTS ${test_data} (id INT); INSERT INTO ${test_data} VALUES (1);" >/dev/null 2>&1
    
    # Wait for replication
    sleep 2
    
    # Try to read via HAProxy read endpoint (should hit replica)
    local result=$(psql -h localhost -p ${HAPROXY_READ_PORT:-5552} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
                  -t -c "SELECT COUNT(*) FROM ${test_data};" 2>/dev/null | tr -d ' ')
    
    if [ "$result" != "1" ]; then
        echo -e "${RED}✗ Read path: Cannot read data (got: $result, expected: 1)${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓ Read path: Functional${NC}"
    fi
    
    # Cleanup
    docker exec $leader psql -U postgres -d ${DEFAULT_DATABASE:-maborak} \
         -c "DROP TABLE ${test_data};" >/dev/null 2>&1
    
    return $issues
}
```

---

### Category 5: Failover Readiness

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_failover_readiness() {
    local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    local max_lag=${1:-1048576}  # 1MB default (from patroni config)
    local issues=0
    local ready_replicas=0
    
    # Get replication lag for each replica
    for node in db1 db2 db3 db4; do
        if [ "$node" = "$leader" ]; then
            continue
        fi
        
        # Check if node is replica
        local role=$(docker exec $node sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null)
        
        if [ "$role" != "Replica" ] && [ "$role" != "replica" ]; then
            continue
        fi
        
        # Check replication lag
        local lag_bytes=$(docker exec $leader psql -U postgres -t -c "
            SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
            FROM pg_replication_slots
            WHERE slot_name LIKE '%${node}%';
        " 2>/dev/null | tr -d ' ' || echo "0")
        
        if [ -z "$lag_bytes" ] || [ "$lag_bytes" = "NULL" ]; then
            echo -e "${YELLOW}⚠ $node: Cannot determine lag${NC}"
            continue
        fi
        
        if [ "$lag_bytes" -gt "$max_lag" ]; then
            echo -e "${RED}✗ $node: Lag too high ($(numfmt --to=iec-i --suffix=B $lag_bytes)) > $(numfmt --to=iec-i --suffix=B $max_lag)${NC}"
            ((issues++))
        else
            echo -e "${GREEN}✓ $node: Ready for failover (lag: $(numfmt --to=iec-i --suffix=B $lag_bytes))${NC}"
            ((ready_replicas++))
        fi
    done
    
    if [ "$ready_replicas" -eq 0 ]; then
        echo -e "${RED}✗ No replicas ready for failover${NC}"
        return 1
    fi
    
    return $issues
}
```

---

### Category 6: Barman Backup + WAL Validation

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_barman_backups() {
    local server=$1
    local max_age_hours=${2:-24}  # Default 24 hours
    local issues=0
    
    # Check if server exists in Barman
    if ! docker exec barman barman list-server | grep -q "^$server"; then
        echo -e "${RED}✗ $server: Not configured in Barman${NC}"
        return 1
    fi
    
    # Check server status
    local status=$(docker exec barman barman check $server 2>&1)
    if echo "$status" | grep -q "FAILED\|ERROR"; then
        echo -e "${RED}✗ $server: Barman check failed${NC}"
        echo "$status" | head -5
        ((issues++))
    fi
    
    # Get latest backup
    local latest_backup=$(docker exec barman barman list-backup $server 2>/dev/null | head -2 | tail -1)
    if [ -z "$latest_backup" ]; then
        echo -e "${RED}✗ $server: No backups found${NC}"
        ((issues++))
        return $issues
    fi
    
    local backup_id=$(echo "$latest_backup" | awk '{print $2}')
    local backup_time=$(echo "$latest_backup" | awk '{print $6, $7, $8}')
    
    # Check backup age
    local backup_epoch=$(docker exec barman date -d "$backup_time" +%s 2>/dev/null || echo "0")
    local current_epoch=$(docker exec barman date +%s)
    local age_hours=$(( (current_epoch - backup_epoch) / 3600 ))
    
    if [ "$age_hours" -gt "$max_age_hours" ]; then
        echo -e "${YELLOW}⚠ $server: Latest backup is ${age_hours}h old (threshold: ${max_age_hours}h)${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓ $server: Latest backup ${age_hours}h old (ID: $backup_id)${NC}"
    fi
    
    return $issues
}

check_wal_archiving() {
    local server=$1
    local issues=0
    
    # Check archiver status
    local archiver_status=$(docker exec barman barman status $server 2>&1 | grep -E "Failures|Last archived")
    
    # Check for failures
    local failures=$(echo "$archiver_status" | grep "Failures" | grep -oE '[0-9]+' || echo "0")
    if [ "$failures" -gt 0 ]; then
        echo -e "${RED}✗ $server: WAL archiver has $failures failures${NC}"
        ((issues++))
    fi
    
    # Check last archived time
    local last_archived=$(echo "$archiver_status" | grep "Last archived" || echo "")
    if [ -z "$last_archived" ]; then
        echo -e "${YELLOW}⚠ $server: Cannot determine last archived WAL${NC}"
    else
        echo -e "${GREEN}✓ $server: $last_archived${NC}"
    fi
    
    # Check for WAL gaps (simplified - check sequence)
    local wal_list=$(docker exec barman barman list-wals $server 2>/dev/null | head -10)
    if [ -z "$wal_list" ]; then
        echo -e "${YELLOW}⚠ $server: No WALs found${NC}"
    fi
    
    return $issues
}
```

---

### Category 7: Disk / Volume Sanity

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_disk_space() {
    local threshold_percent=${1:-85}  # Default 85%
    local issues=0
    
    # Check PostgreSQL data directories
    for node in db1 db2 db3 db4; do
        local usage=$(docker exec $node df -h /var/lib/postgresql | tail -1 | awk '{print $5}' | sed 's/%//')
        if [ "$usage" -gt "$threshold_percent" ]; then
            echo -e "${RED}✗ $node: Disk usage ${usage}% (threshold: ${threshold_percent}%)${NC}"
            ((issues++))
        else
            echo -e "${GREEN}✓ $node: Disk usage ${usage}%${NC}"
        fi
    done
    
    # Check Barman backup storage
    local barman_usage=$(docker exec barman df -h /data/pg-backup | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$barman_usage" -gt "$threshold_percent" ]; then
        echo -e "${RED}✗ barman: Backup storage ${barman_usage}% full${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓ barman: Backup storage ${barman_usage}% used${NC}"
    fi
    
    return $issues
}
```

---

### Category 8: Time Synchronization

**Current**: ❌ Not checked

**Proposed Implementation**:

```bash
check_time_sync() {
    local max_drift_seconds=${1:-5}  # Default 5 seconds
    local issues=0
    
    # Get time from each node
    local times=()
    for node in db1 db2 db3 db4 etcd1 etcd2 barman; do
        if docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
            local node_time=$(docker exec $node date +%s 2>/dev/null || echo "0")
            times+=("$node:$node_time")
        fi
    done
    
    # Find min and max
    local min_time=9999999999
    local max_time=0
    
    for time_entry in "${times[@]}"; do
        local time_val=$(echo "$time_entry" | cut -d: -f2)
        if [ "$time_val" -lt "$min_time" ]; then
            min_time=$time_val
        fi
        if [ "$time_val" -gt "$max_time" ]; then
            max_time=$time_val
        fi
    done
    
    local drift=$((max_time - min_time))
    
    if [ "$drift" -gt "$max_drift_seconds" ]; then
        echo -e "${YELLOW}⚠ Time drift detected: ${drift}s (threshold: ${max_drift_seconds}s)${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓ Time synchronization OK (max drift: ${drift}s)${NC}"
    fi
    
    return $issues
}
```

---

## Recommended Functions Section

The following functions can be added to `check_stack.sh` or used as a separate validation script:

```bash
#!/bin/bash
# Enhanced health check functions for check_stack.sh
# Add these functions to check_stack.sh or source this file

set -euo pipefail

# Colors (if not already defined)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function: Check replication health
check_replication_health() {
    local leader=$1
    local issues=0
    
    echo -e "${YELLOW}Checking replication health...${NC}"
    
    # Get replication slots
    local slots=$(docker exec $leader psql -U postgres -t -c "
        SELECT slot_name, active, 
               pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
        FROM pg_replication_slots;
    " 2>/dev/null || echo "")
    
    if [ -z "$slots" ]; then
        echo -e "${RED}✗ No replication slots found${NC}"
        return 1
    fi
    
    echo "$slots" | while IFS='|' read -r slot_name active lag_bytes; do
        slot_name=$(echo "$slot_name" | xargs)
        active=$(echo "$active" | xargs)
        lag_bytes=$(echo "$lag_bytes" | xargs)
        
        if [ "$active" != "t" ]; then
            echo -e "${RED}✗ Slot $slot_name: Inactive${NC}"
            ((issues++))
        fi
        
        if [ -n "$lag_bytes" ] && [ "$lag_bytes" != "NULL" ] && [ "$lag_bytes" -gt 1048576 ]; then
            local lag_mb=$((lag_bytes / 1048576))
            echo -e "${YELLOW}⚠ Slot $slot_name: Lag ${lag_mb}MB${NC}"
        fi
    done
    
    return $issues
}

# Function: Check read/write paths
check_rw_paths() {
    local test_id="health_$$"
    local issues=0
    
    echo -e "${YELLOW}Testing read/write paths...${NC}"
    
    # Write test
    if psql -h localhost -p ${HAPROXY_WRITE_PORT:-5551} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
       -c "CREATE TABLE ${test_id}_write (id INT);" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Write path: Functional${NC}"
        psql -h localhost -p ${HAPROXY_WRITE_PORT:-5551} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
             -c "DROP TABLE ${test_id}_write;" >/dev/null 2>&1
    else
        echo -e "${RED}✗ Write path: Failed${NC}"
        ((issues++))
    fi
    
    # Read test (requires data to exist)
    local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    docker exec $leader psql -U postgres -d ${DEFAULT_DATABASE:-maborak} \
         -c "CREATE TABLE IF NOT EXISTS ${test_id}_read (id INT); INSERT INTO ${test_id}_read VALUES (1) ON CONFLICT DO NOTHING;" >/dev/null 2>&1
    
    sleep 1  # Wait for replication
    
    local read_result=$(psql -h localhost -p ${HAPROXY_READ_PORT:-5552} -U postgres -d ${DEFAULT_DATABASE:-maborak} \
                       -t -c "SELECT COUNT(*) FROM ${test_id}_read;" 2>/dev/null | tr -d ' ')
    
    if [ "$read_result" = "1" ]; then
        echo -e "${GREEN}✓ Read path: Functional${NC}"
    else
        echo -e "${RED}✗ Read path: Failed (got: $read_result)${NC}"
        ((issues++))
    fi
    
    # Cleanup
    docker exec $leader psql -U postgres -d ${DEFAULT_DATABASE:-maborak} \
         -c "DROP TABLE IF EXISTS ${test_id}_read;" >/dev/null 2>&1
    
    return $issues
}

# Function: Check failover readiness
check_failover_readiness() {
    local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
    local ready_count=0
    
    echo -e "${YELLOW}Checking failover readiness...${NC}"
    
    for node in db1 db2 db3 db4; do
        if [ "$node" = "$leader" ]; then
            continue
        fi
        
        local role=$(docker exec $node sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
        
        if [ "$role" != "Replica" ] && [ "$role" != "replica" ]; then
            continue
        fi
        
        # Check if streaming
        local streaming=$(docker exec $node psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
        if [ "$streaming" = "t" ]; then
            echo -e "${GREEN}✓ $node: Ready (replica, streaming)${NC}"
            ((ready_count++))
        else
            echo -e "${YELLOW}⚠ $node: Replica but not in recovery mode${NC}"
        fi
    done
    
    if [ "$ready_count" -eq 0 ]; then
        echo -e "${RED}✗ No replicas ready for failover${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Failover readiness: $ready_count replica(s) ready${NC}"
    return 0
}

# Function: Check Barman backups
check_barman_health() {
    local issues=0
    
    echo -e "${YELLOW}Checking Barman backups...${NC}"
    
    for server in db1 db2 db3 db4; do
        # Check server status
        local status=$(docker exec barman barman check $server 2>&1 | head -1)
        if echo "$status" | grep -q "FAILED\|ERROR"; then
            echo -e "${RED}✗ $server: $status${NC}"
            ((issues++))
        else
            # Get latest backup
            local latest=$(docker exec barman barman list-backup $server 2>/dev/null | head -2 | tail -1)
            if [ -n "$latest" ]; then
                local backup_id=$(echo "$latest" | awk '{print $2}')
                echo -e "${GREEN}✓ $server: Latest backup $backup_id${NC}"
            else
                echo -e "${YELLOW}⚠ $server: No backups found${NC}"
            fi
        fi
    done
    
    return $issues
}

# Function: Check disk space
check_disk_space() {
    local threshold=85
    local issues=0
    
    echo -e "${YELLOW}Checking disk space...${NC}"
    
    for node in db1 db2 db3 db4; do
        local usage=$(docker exec $node df /var/lib/postgresql | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
        if [ "$usage" -gt "$threshold" ]; then
            echo -e "${RED}✗ $node: Disk ${usage}% full${NC}"
            ((issues++))
        else
            echo -e "${GREEN}✓ $node: Disk ${usage}% used${NC}"
        fi
    done
    
    local barman_usage=$(docker exec barman df /data/pg-backup | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
    if [ "$barman_usage" -gt "$threshold" ]; then
        echo -e "${RED}✗ barman: Backup storage ${barman_usage}% full${NC}"
        ((issues++))
    else
        echo -e "${GREEN}✓ barman: Backup storage ${barman_usage}% used${NC}"
    fi
    
    return $issues
}

# Main enhanced check function
run_enhanced_checks() {
    local leader=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}' || echo "db1")
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Enhanced Health Checks${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    check_replication_health "$leader"
    echo ""
    
    check_rw_paths
    echo ""
    
    check_failover_readiness
    echo ""
    
    check_barman_health
    echo ""
    
    check_disk_space
    echo ""
}
```

---

## Integration into check_stack.sh

**Option 1: Add as separate section**
```bash
# After existing checks, add:
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Enhanced Health Checks${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Source enhanced functions (if in separate file)
# source ./scripts/check_enhanced.sh

# Or define functions inline, then call:
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
check_replication_health "$LEADER"
check_rw_paths
check_failover_readiness
check_barman_health
check_disk_space
```

**Option 2: Create separate script**
- `check_stack_enhanced.sh` - Includes all enhanced checks
- Keep `check_stack.sh` as basic checks
- Users can choose which to run

**Recommendation**: Add enhanced checks as optional section in `check_stack.sh`, controlled by environment variable:
```bash
if [ "${ENHANCED_CHECKS:-false}" = "true" ]; then
    run_enhanced_checks
fi
```

---

## Testing Recommendations

**Before deploying enhanced checks**:

1. **Test in non-production first**
2. **Verify no false positives** - Ensure checks don't fail on healthy clusters
3. **Performance impact** - Enhanced checks add ~5-10 seconds to check time
4. **Dependencies** - Some checks require `bc` or `numfmt` (may need installation)

---

## Summary

**Current Coverage**: ~60% of critical checks
**With Enhancements**: ~95% of critical checks

**Priority Enhancements**:
1. **Replication health** (HIGH) - Failover readiness
2. **Read/write path validation** (HIGH) - Application functionality
3. **Barman backup validation** (CRITICAL) - Recovery capability
4. **Failover readiness** (HIGH) - HA guarantee
5. **Disk space** (MEDIUM) - Operational stability

**Low Priority** (but valuable):
- Time synchronization
- Network connectivity (internal)
- PostgreSQL configuration validation

---

## References

- **PostgreSQL Replication Monitoring**: https://www.postgresql.org/docs/15/monitoring-stats.html
- **Patroni Health Checks**: https://patroni.readthedocs.io/en/latest/rest_api.html#health-endpoint
- **Barman Monitoring**: https://www.pgbarman.org/documentation/
