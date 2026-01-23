# PostgreSQL High Availability with Patroni + Barman Backup

A **production-grade Docker Compose playground** demonstrating PostgreSQL High Availability (HA) using Patroni with etcd, integrated with Barman for backup and Point-In-Time Recovery (PITR).

## Executive Summary

This repository demonstrates a complete PostgreSQL HA stack suitable for learning, development, and production reference:

### Patroni HA Behaviors

- **Leader Election**: Automatic leader selection via etcd DCS (Distributed Configuration Store)
- **Replication Management**: Automatic streaming replication setup and monitoring
- **Switchover**: Planned leader transitions (`patronictl switchover`)
- **Failover**: Automatic failover when leader becomes unavailable
- **pg_rewind**: Automatic timeline divergence repair (enabled via `use_pg_rewind: true`)

**Status**: ✅ Fully implemented

### Barman Capabilities

- **Base Backups**: Full database backups via `barman backup`
- **WAL Archiving**: Continuous WAL streaming from leader nodes via SSH/rsync
- **WAL Processing**: Automatic WAL compression and organization
- **Restore Drills**: Manual and automated recovery workflows
- **PITR**: Point-In-Time Recovery to any timestamp (fully automated via `scripts/pitr/perform_pitr.sh`)

**Status**: ✅ Fully implemented

### Why Docker Compose?

**Tradeoffs vs Kubernetes:**

| Aspect | Docker Compose (This Repo) | Kubernetes |
|--------|---------------------------|------------|
| **Learning Curve** | Low - single machine | High - requires k8s knowledge |
| **Resource Usage** | Lower overhead | Higher overhead |
| **Networking** | Simple bridge network | Complex CNI, services, ingress |
| **Storage** | Docker volumes (simple) | PersistentVolumes, StorageClasses |
| **Deployment** | `docker-compose up` | Helm charts, operators, manifests |
| **Use Case** | Development, testing, learning | Production at scale |

**This playground is ideal for:**
- Understanding Patroni HA mechanics
- Learning Barman backup/restore workflows
- Testing PITR scenarios safely
- Development environment for applications
- Reference implementation for production design

---

## Quickstart

### Prerequisites

- **Docker Engine** 20.10+ (with Compose V2 support)
- **Docker Compose** 2.0+ (or `docker compose` plugin)
- **8GB+ RAM** recommended (4GB minimum)
- **20GB+ disk space** for data volumes
- **macOS or Linux** (tested on both)

### One-Command Startup

```bash
# Clone and start
git clone <repository-url>
cd patroni-ha-dockerized
docker-compose up -d

# Wait ~30 seconds for initialization, then verify
./check_stack.sh
```

### How to Know It's Working

**1. Run the health check:**
```bash
./check_stack.sh
```

Expected output:
- ✅ All containers running
- ✅ etcd cluster healthy
- ✅ Patroni API responding (1 Leader, 3 Replicas)
- ✅ PostgreSQL ready on all nodes
- ✅ HAProxy configuration valid
- ✅ SSH keys and connectivity verified

**2. Check Patroni cluster status:**
```bash
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

Expected:
```
+ Cluster: patroni1 (7172341234567890123) --------+
| Member | Host      | Role    | State   | TL | Lag in MB |
+--------+-----------+---------+---------+----+-----------+
| db1    | db1:5431  | Leader  | running |  1 |           |
| db2    | db2:5431  | Replica | running |  1 |         0  |
| db3    | db3:5431  | Replica | running |  1 |         0  |
| db4    | db4:5431  | Replica | running |  1 |         0  |
+--------+-----------+---------+---------+----+-----------+
```

**3. Basic psql verification:**
```bash
# Connect via HAProxy (write endpoint - routes to leader)
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT version();"

# Connect via HAProxy (read endpoint - routes to replicas)
psql -h localhost -p 5552 -U postgres -d maborak -c "SELECT pg_is_in_recovery();"
```

**4. Verify WAL archiving:**
```bash
# Check archive log on leader
docker exec db1 tail -5 /var/log/postgresql/archive.log

# Check Barman received WALs
docker exec barman barman list-wals db1 | head -5
```

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Host                              │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐                         │
│  │    etcd1     │  │    etcd2     │  DCS (Distributed       │
│  │  :2379/:2380 │  │  :2379/:2380 │   Configuration Store) │
│  └──────┬───────┘  └──────┬───────┘                         │
│         │                 │                                 │
│         └────────┬─────────┘                                 │
│                  │                                           │
│  ┌───────────────┼───────────────┐                          │
│  │               │               │                          │
│  ▼               ▼               ▼                          │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐                         │
│  │ db1 │  │ db2 │  │ db3 │  │ db4 │  Patroni/PostgreSQL     │
│  │Leader│  │Repl│  │Repl│  │Repl│   Cluster (4 nodes)      │
│  └──┬──┘  └──┬──┘  └──┬──┘  └──┬──┘                         │
│     │        │        │        │                             │
│     └────────┼────────┼────────┘                             │
│              │        │                                       │
│              ▼        ▼                                       │
│         ┌─────────────────┐                                  │
│         │    HAProxy       │  Load Balancer                  │
│         │  Write: :5551    │  (Read/Write Split)             │
│         │  Read:  :5552    │                                  │
│         └─────────┬─────────┘                                 │
│                   │                                           │
│         ┌─────────┴─────────┐                                 │
│         │                    │                                 │
│         ▼                    ▼                                 │
│    ┌─────────┐         ┌─────────┐                           │
│    │ Clients │         │  Barman  │  Backup Server             │
│    │         │         │          │  (WAL Archiving)          │
│    └─────────┘         └──────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

### Components

#### PostgreSQL Nodes (db1-db4)

- **Image**: Custom build from `patroni/Dockerfile` (PostgreSQL 15 + Patroni)
- **Ports**: 
  - PostgreSQL: `15431-15434` (external), `5431` (internal)
  - Patroni API: `8001-8004` (external), `8001` (internal)
- **Data Directory**: `/var/lib/postgresql/15/patroni{N}/`
- **Configuration**: `configs/patroni{N}.yml` (mounted read-only)
- **SSH Keys**: `/home/postgres/.ssh/barman_rsa` (for WAL archiving)

**Responsibility**: 
- Run PostgreSQL with Patroni management
- Participate in leader election
- Stream WAL to Barman (leader only)
- Accept replication from leader

**Failure Domain**: Single node failure → automatic failover to another node

#### Patroni

- **Version**: Latest with etcd3 support
- **DCS Backend**: etcd (2-node cluster)
- **Scope**: `patroni1`
- **Namespace**: `/patroni1`

**Key Features**:
- Automatic leader election
- Replication slot management (`use_slots: true`)
- pg_rewind for timeline repair (`use_pg_rewind: true`)
- REST API on port 8001 (health checks, role info)

**Configuration Files**: `configs/patroni1.yml` through `patroni4.yml`

#### etcd (Distributed Configuration Store)

- **Nodes**: etcd1, etcd2
- **Ports**: 
  - Client: `2379` (internal), `2379`/`22379` (external)
  - Peer: `2380` (internal)
- **Data**: Persistent volumes (`etcd1_data`, `etcd2_data`)

**Responsibility**:
- Store Patroni cluster state (leader lock, member list)
- Coordinate leader election
- Maintain cluster topology

**Failure Domain**: 
- Single etcd failure → cluster continues (quorum maintained)
- Both etcd failures → cluster loses coordination (manual intervention required)

#### HAProxy (Load Balancer)

- **Image**: `haproxy:2.8`
- **Ports**:
  - Write: `5551` (routes to leader only)
  - Read: `5552` (round-robin to replicas)
  - Stats: `5553` (HTTP stats page)
- **Configuration**: `configs/haproxy.cfg`

**Health Checks**:
- Write backend: `GET /master` (returns 200 only for leader)
- Read backend: `GET /replica` (returns 200 only for replicas)

**Responsibility**:
- Route write traffic to current leader
- Distribute read traffic across replicas
- Provide connection pooling

**Failure Domain**: HAProxy failure → clients cannot connect (single point of failure for external access)

#### Barman (Backup Server)

- **Image**: Custom build from `barman/Dockerfile`
- **Port**: `5432` (PostgreSQL protocol, for streaming if configured)
- **Backup Storage**: `/data/pg-backup` (volume: `barman_backup`)
- **Configuration**: `configs/barman.conf`

**Responsibility**:
- Receive WAL files via SSH/rsync from leader
- Process and compress WAL files
- Store base backups
- Provide recovery tools (`barman recover`, `barman get-wal`)

**Failure Domain**: Barman failure → WAL archiving stops, backups unavailable

### Data Flow

#### Write Path (Leader)
```
Client → HAProxy:5551 → Leader (db1) → PostgreSQL
                              ↓
                         WAL Segment
                              ↓
                    archive_command (rsync)
                              ↓
                         Barman Server
```

#### Read Path (Replicas)
```
Client → HAProxy:5552 → Replica (db2/db3/db4) → PostgreSQL
                              ↑
                         Streaming Replication
                              ↑
                         Leader (db1)
```

#### WAL Archiving Flow
```
Leader PostgreSQL → archive_command → rsync over SSH → Barman:/data/pg-backup/{server}/incoming/
                                                              ↓
                                                    Barman cron (every minute)
                                                              ↓
                                                    /data/pg-backup/{server}/wals/{timeline}/
```

### Volumes

| Volume | Purpose | Location |
|--------|---------|----------|
| `etcd1_data`, `etcd2_data` | etcd cluster data | `/etcd-data` |
| `db1_data` - `db4_data` | PostgreSQL data directories | `/var/lib/postgresql/15/patroni{N}/` |
| `barman_data` | Barman metadata and logs | `/var/lib/barman` |
| `barman_backup` | Backup storage (WALs + base backups) | `/data/pg-backup` |

### Network

- **Network Name**: `patroni_network`
- **Driver**: `bridge`
- **Subnet**: Auto-assigned by Docker (typically `172.20.0.0/16`)
- **DNS**: Container hostnames resolve automatically

---

## Feature-by-Feature Explanation

### 1. Automatic Leader Election

**What it does**: Patroni uses etcd to coordinate leader election. Only one node can hold the leader lock at a time.

**Why it matters**: Ensures single-writer semantics. Prevents split-brain scenarios.

**Implementation**:
- **File**: `configs/patroni1.yml` (and patroni2-4.yml)
- **Key Settings**:
  ```yaml
  etcd3:
    hosts: etcd1:2379,etcd2:2379
  bootstrap:
    dcs:
      ttl: 30
      loop_wait: 10
  ```

**Validation**:
```bash
# Check current leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader

# Verify leader lock in etcd
docker exec etcd1 etcdctl get --prefix /patroni1/leader
```

**Failure Modes**:
- etcd quorum lost → election stops, current leader continues until TTL expires
- Leader crash → etcd releases lock, another node promotes within `loop_wait` seconds

**Tradeoffs**:
- `ttl: 30` → faster failover but more etcd traffic
- `loop_wait: 10` → balance between responsiveness and stability

---

### 2. Streaming Replication

**What it does**: Replicas continuously stream WAL from leader via PostgreSQL streaming replication.

**Why it matters**: Provides real-time data copies for read scaling and failover readiness.

**Implementation**:
- **File**: `configs/patroni{N}.yml`
- **Key Settings**:
  ```yaml
  postgresql:
    parameters:
      wal_level: replica
      max_wal_senders: 10
      max_replication_slots: 10
      hot_standby: on
  bootstrap:
    dcs:
      postgresql:
        use_slots: true
  ```

**Validation**:
```bash
# On leader, check replication slots
docker exec db1 psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"

# On replica, check lag
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

**Failure Modes**:
- Replica falls behind → Patroni monitors lag, can exclude from failover candidates if `maximum_lag_on_failover` exceeded
- Replication slot missing → Patroni creates it automatically (`use_slots: true`)

---

### 3. Planned Switchover

**What it does**: Gracefully transfer leadership from current leader to a chosen replica.

**Why it matters**: Zero-downtime maintenance, load balancing, testing failover procedures.

**Implementation**:
- **Command**: `patronictl switchover`
- **Status**: ✅ Implemented (manual command)

**Usage**:
```bash
# Switch from current leader to db2
docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover \
  patroni1 \
  --master db1 \
  --candidate db2
```

**Validation**:
```bash
# Before: db1 is leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# After: db2 is leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

**Failure Modes**:
- Candidate not ready → switchover fails, current leader remains
- Network partition during switchover → may result in two leaders (rare, mitigated by etcd lock)

---

### 4. Automatic Failover

**What it does**: When leader becomes unavailable, Patroni automatically promotes the best replica.

**Why it matters**: High availability - automatic recovery from leader failures.

**Implementation**:
- **Trigger**: Leader lock expires (TTL) or leader health check fails
- **Selection**: Patroni chooses replica with lowest lag
- **File**: `configs/patroni{N}.yml`
- **Key Settings**:
  ```yaml
  bootstrap:
    dcs:
      maximum_lag_on_failover: 1048576  # 1MB lag threshold
  ```

**Validation**:
```bash
# Simulate leader crash
docker stop db1

# Wait ~30 seconds, then check new leader
docker exec db2 patronictl -c /etc/patroni/patroni.yml list
```

**Failure Modes**:
- All replicas lagging → failover may promote stale replica (data loss risk)
- Split-brain → etcd quorum prevents this, but network partitions can cause issues

---

### 5. WAL Archiving to Barman

**What it does**: Leader node continuously streams WAL files to Barman via SSH/rsync.

**Why it matters**: Enables PITR. Provides off-site WAL storage.

**Implementation**:
- **File**: `configs/patroni1.yml` (and patroni2-4.yml)
- **Key Setting**:
  ```yaml
  postgresql:
    parameters:
      archive_mode: on
      archive_command: "/bin/bash -c 'HOSTNAME=$(/bin/hostname); if [ -n \"$(/usr/local/bin/patronictl -c /etc/patroni/patroni.yml list -e 2>/dev/null | /bin/grep -w \"$HOSTNAME\" | /bin/grep -w \"Leader\" | /bin/grep -w \"running\")\" ]; then /usr/bin/rsync -e \"ssh -i /home/postgres/.ssh/barman_rsa -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\" -a %p barman@barman:/data/pg-backup/$HOSTNAME/incoming/%f && echo \"$(/bin/date +\"%Y-%m-%d %H:%M:%S\") - Archived: %f\" >> /var/log/postgresql/archive.log 2>&1; else echo \"$(/bin/date +\"%Y-%m-%d %H:%M:%S\") - Not the leader or not running, skipping archive\" >> /var/log/postgresql/archive.log 2>&1; fi'"
  ```

**Why this design**:
- Only leader archives (replicas skip) → avoids duplicate WALs
- Full paths used → works in minimal PostgreSQL environment
- Error handling → logs failures without breaking PostgreSQL

**Validation**:
```bash
# Check archive log on leader
docker exec db1 tail -f /var/log/postgresql/archive.log

# Check WALs received by Barman
docker exec barman barman list-wals db1 | head -10

# Check Barman archiver status
docker exec barman barman status db1
```

**Failure Modes**:
- SSH key missing → archiving fails silently, check archive.log
- Barman unreachable → WALs accumulate in pg_wal, may fill disk
- Archive command fails → PostgreSQL continues, but PITR may be incomplete

---

### 6. Base Backups

**What it does**: Barman takes full database backups via `pg_basebackup` over SSH.

**Why it matters**: Starting point for PITR. Full database copy for disaster recovery.

**Implementation**:
- **Command**: `barman backup <server>`
- **Method**: rsync (configured in `configs/barman.conf`)
- **Storage**: `/data/pg-backup/{server}/base/{backup-id}/`

**Usage**:
```bash
# Create backup
docker exec barman barman backup db1

# List backups
docker exec barman barman list-backup db1

# Show backup details
docker exec barman barman show-backup db1 20260123T120000
```

**Validation**:
```bash
# Check backup status
docker exec barman barman check db1

# Verify backup exists
docker exec barman ls -lh /data/pg-backup/db1/base/
```

**Failure Modes**:
- Backup in progress during high load → may timeout or slow down database
- Disk full on Barman → backup fails, old backups may be deleted by retention policy

---

### 7. Point-In-Time Recovery (PITR)

**What it does**: Recover database to any timestamp between backup and last archived WAL.

**Why it matters**: Recover from accidental DELETE, data corruption, or restore to specific state.

**Implementation**:
- **Script**: `scripts/pitr/perform_pitr.sh` (comprehensive automation)
- **Methods**: 
  - Manual recovery (copy files, configure recovery)
  - Automated recovery (`--target` flag applies to node automatically)

**Usage**:
```bash
# Automated PITR (recommended)
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore

# Manual PITR (for learning)
bash scripts/pitr/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1
# Then follow instructions printed by script
```

**Validation**:
```bash
# After recovery, verify data
docker exec db2 psql -U postgres -d maborak -c "SELECT COUNT(*) FROM your_table;"

# Check recovery completed
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false) when recovery complete
```

**Failure Modes**:
- WAL gaps → recovery stops at gap, cannot proceed
- Target time before backup → recovery fails (validated by script)
- Timeline divergence → requires manual intervention

**See**: `docs/pitr.md` and `docs/tools/perform_pitr.md` for detailed documentation.

---

### 8. Read/Write Split (HAProxy)

**What it does**: Routes write queries to leader, read queries to replicas (round-robin).

**Why it matters**: Read scaling - distribute read load across replicas.

**Implementation**:
- **File**: `configs/haproxy.cfg`
- **Write Backend**: Health check `GET /master` (Patroni REST API)
- **Read Backend**: Health check `GET /replica` (Patroni REST API)

**Usage**:
```bash
# Write operations (leader only)
psql -h localhost -p 5551 -U postgres -d maborak

# Read operations (replicas, round-robin)
psql -h localhost -p 5552 -U postgres -d maborak
```

**Validation**:
```bash
# Check HAProxy stats
curl http://localhost:5553/stats | grep -A 5 "patroni_write_backend"

# Verify write goes to leader
psql -h localhost -p 5551 -U postgres -c "SELECT inet_server_addr();"
# Should return leader's IP

# Verify reads go to replicas
psql -h localhost -p 5552 -U postgres -c "SELECT inet_server_addr();"
# Should return replica IP (changes on each connection due to round-robin)
```

**Failure Modes**:
- HAProxy misconfiguration → may route writes to replicas (causes errors)
- All replicas down → read backend has no healthy servers (connection refused)

---

## Day-2 Operations Overview

### Planned Switchover

**Goal**: Transfer leadership from db1 to db2 for maintenance.

**Runbook**: See `docs/runbooks.md` → "Planned Switchover"

**Quick Steps**:
```bash
# 1. Verify cluster health
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# 2. Perform switchover
docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover \
  patroni1 --master db1 --candidate db2

# 3. Verify new leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

---

### Simulated Leader Crash

**Goal**: Test automatic failover behavior.

**Runbook**: See `docs/runbooks.md` → "Failover Drill"

**Quick Steps**:
```bash
# 1. Identify current leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader

# 2. Stop leader (simulate crash)
docker stop db1

# 3. Wait ~30 seconds, check new leader
docker exec db2 patronictl -c /etc/patroni/patroni.yml list

# 4. Restart old leader (it will rejoin as replica)
docker start db1
sleep 10
docker exec db1 patronictl -c /etc/patroni/patroni.yml list
```

---

### Backup + Verification

**Goal**: Create backup and verify it's usable.

**Runbook**: See `docs/runbooks.md` → "Backup Workflow"

**Quick Steps**:
```bash
# 1. Create backup
docker exec barman barman backup db1

# 2. Verify backup
docker exec barman barman check db1

# 3. List backups
docker exec barman barman list-backup db1

# 4. Show backup details
BACKUP_ID=$(docker exec barman barman list-backup db1 | head -2 | tail -1 | awk '{print $2}')
docker exec barman barman show-backup db1 $BACKUP_ID
```

---

### Restore + PITR

**Goal**: Recover database to specific point in time.

**Runbook**: See `docs/runbooks.md` → "PITR Workflow"

**Quick Steps**:
```bash
# Automated (recommended)
bash scripts/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 --target db2 --restore --wal-method barman-wal-restore

# Manual (for learning)
bash scripts/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1
# Follow printed instructions
```

**See**: `docs/pitr.md` for comprehensive PITR documentation.

---

### Replica Rebuild

**Goal**: Reinitialize a replica that's fallen behind or corrupted.

**Status**: ✅ Implemented via Patroni `reinit` command

**Usage**:
```bash
# Reinitialize db2 as replica from current leader
docker exec db1 patronictl -c /etc/patroni/patroni.yml reinit \
  patroni1 db2 --force
```

**What it does**:
- Stops PostgreSQL on target node
- Removes data directory
- Creates new base backup from leader
- Starts replication

**Validation**:
```bash
# Monitor reinit progress
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# Check replication lag
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

---

## Makefile Commands (Plug-and-Play Interface)

The `Makefile` provides a **workflow contract** for common operations. It abstracts Docker Compose complexity and provides guardrails.

### Why Make?

- **Repeatability**: Same commands work for all users
- **Onboarding**: New team members can contribute immediately
- **Guardrails**: Prevents common mistakes (e.g., forgetting `-v` flag)
- **Documentation**: Self-documenting via `make help`

### Current Targets

| Target | What It Does | Prerequisites |
|--------|--------------|---------------|
| `make up` | Start all services in background | Docker, docker-compose |
| `make down` | Stop all services | Stack running |
| `make restart` | Restart all services | Stack running |
| `make logs` | Follow all service logs | Stack running |
| `make ps` | Show container status | Stack running |
| `make build` | Rebuild all images (no cache) | Docker |
| `make clean` | Stop services + remove volumes + prune | Stack running |
| `make status` | Show Patroni cluster + etcd health | Stack running |
| `make shell-db1` | Open bash shell in db1 | db1 running |
| `make shell-barman` | Open bash shell in barman | barman running |

### Proposed Additional Targets

See `docs/runbooks.md` for detailed runbook workflows. The following Make targets would enhance the workflow:

#### Core Lifecycle (Already Implemented)
- ✅ `make up` - Start stack
- ✅ `make down` - Stop stack
- ✅ `make restart` - Restart services
- ✅ `make clean` - Remove volumes
- ✅ `make logs` - View logs
- ✅ `make ps` - Container status

#### Health & Verification
- ✅ `make status` - Cluster status (basic)
- **Proposed**: `make check` - Run `./check_stack.sh`
- **Proposed**: `make health` - Extended health check

#### Patroni / HA
- **Proposed**: `make patroni-list` - Show cluster status
- **Proposed**: `make switchover TARGET=db2` - Planned switchover
- **Proposed**: `make failover-drill` - Simulate leader crash
- **Proposed**: `make reinit-replica NODE=db2` - Rebuild replica

#### Backup & Restore
- **Proposed**: `make backup SERVER=db1` - Create backup
- **Proposed**: `make backups SERVER=db1` - List backups
- **Proposed**: `make restore BACKUP_ID=xxx TARGET_TIME='...'` - PITR
- **Proposed**: `make pitr BACKUP_ID=xxx TARGET_TIME='...' TARGET=db2` - Automated PITR

#### UX Polish
- **Proposed**: `make help` - Show all targets (default)
- **Proposed**: `make shell NODE=db1` - Generic shell access
- **Proposed**: `make psql` - Connect to leader via HAProxy
- **Proposed**: `make psql-replica` - Connect to replica via HAProxy
- **Proposed**: `make config` - Show current configuration
- **Proposed**: `make destroy` - Remove everything (with confirmation)

**Status**: Proposed targets are documented in `docs/runbooks.md`. Implementation left as exercise to avoid breaking existing workflows.

---

## Scripts Overview

The `scripts/` directory contains valuable but currently unorganized tooling. See `scripts/README.md` for complete documentation.

### Golden Path Scripts

**Critical scripts you'll use regularly:**

1. **`scripts/pitr/perform_pitr.sh`** ⭐
   - **Purpose**: Automated Point-In-Time Recovery
   - **When to use**: After accidental data loss, testing recovery procedures
   - **See**: `docs/tools/perform_pitr.md` for full documentation

2. **`check_stack.sh`** (root level)
   - **Purpose**: Comprehensive health check
   - **When to use**: After startup, before operations, troubleshooting
   - **See**: `docs/checks.md` for gap analysis and improvements

3. **`scripts/debug/get_stack_info.sh`**
   - **Purpose**: Detailed cluster information (JSON or human-readable)
   - **When to use**: Understanding current state, monitoring

### Script Classification

**Proposed organization** (see `scripts/README.md` for details):

- `scripts/ops/` → Lifecycle & HA operations
- `scripts/backup/` → Barman / backup tasks
- `scripts/pitr/` → PITR workflows
- `scripts/debug/` → Diagnostics & inspection
- `scripts/utils/` → Helpers

**Backward Compatibility**: Scripts remain in current location. Proposed organization is optional refactoring.

---

## Observability & Troubleshooting

### Symptom → Likely Cause → Fix

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| All nodes show "unknown" role | Patroni not started or etcd unreachable | Check `docker logs db1`, verify etcd health |
| Replica lagging significantly | Network issues or leader overload | Check network, verify `max_wal_senders` |
| WAL archiving failing | SSH key missing or Barman unreachable | Run `./check_stack.sh`, verify SSH connectivity |
| HAProxy routes writes to replica | Health check misconfiguration | Verify `/master` endpoint returns 200 only for leader |
| PITR recovery stops early | WAL gap or target time invalid | Check `barman list-wals`, verify target time |

### Where to Find Logs

**Docker Compose logs:**
```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f db1
docker-compose logs -f barman
```

**Patroni logs:**
```bash
# Via supervisor (inside container)
docker exec db1 supervisorctl tail -f patroni

# Via docker logs
docker logs db1 | grep patroni
```

**PostgreSQL logs:**
```bash
# Archive log (WAL archiving)
docker exec db1 tail -f /var/log/postgresql/archive.log

# PostgreSQL main log
docker exec db1 tail -f /var/log/postgresql/postgresql-*.log
```

**Barman logs:**
```bash
# Barman main log
docker exec barman tail -f /var/log/barman/barman.log

# Check archiver status
docker exec barman barman status db1
```

---

## Security Notes (Playground vs Production)

### ⚠️ Playground Assumptions

This repository is designed for **learning and development**, not production. Security is intentionally simplified.

**Insecure for Production:**

1. **Exposed Ports**
   - All PostgreSQL ports exposed to host (`15431-15434`)
   - Patroni API exposed (`8001-8004`)
   - etcd exposed (`2379`, `22379`)
   - **Production**: Use firewall rules, restrict to internal network

2. **Credential Handling**
   - Passwords in `docker-compose.yml` (default values)
   - SSH keys in repository (`ssh_keys/`)
   - **Production**: Use secrets management (Docker secrets, Vault, etc.)

3. **TLS / Auth**
   - No TLS encryption (plain TCP)
   - Weak authentication (password-based)
   - **Production**: Enable SSL/TLS, use certificate-based auth

4. **Network Boundaries**
   - All services on same network (no isolation)
   - **Production**: Use network policies, separate networks per tier

5. **Hardening Recommendations**
   - Change all default passwords
   - Rotate SSH keys regularly
   - Enable PostgreSQL SSL
   - Use etcd TLS
   - Implement network segmentation
   - Enable audit logging
   - Use read-only root filesystems where possible

### What's Safe for Production Reference

- **Architecture patterns**: Leader election, replication setup
- **Configuration tuning**: PostgreSQL parameters, Patroni settings
- **Backup workflows**: Barman configuration, PITR procedures
- **Operational procedures**: Switchover, failover, recovery

---

## Additional Documentation

- **[Architecture Deep Dive](docs/architecture.md)** - Component details, diagrams, ports/volumes tables
- **[Runbooks](docs/runbooks.md)** - Step-by-step operational procedures
- **[Health Checks](docs/checks.md)** - `check_stack.sh` analysis and improvements
- **[PITR Guide](docs/pitr.md)** - Consolidated PITR documentation
- **[perform_pitr.sh Reference](docs/tools/perform_pitr.md)** - Complete script documentation
- **[Scripts Directory](scripts/README.md)** - All scripts documented and organized

---

## Quick Reference

### Connection Strings

**Write (Leader):**
```bash
psql -h localhost -p 5551 -U postgres -d maborak
# URL: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5551/maborak
```

**Read (Replicas):**
```bash
psql -h localhost -p 5552 -U postgres -d maborak
# URL: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:5552/maborak
```

**Direct to Node:**
```bash
psql -h localhost -p 15431 -U postgres -d maborak  # db1
psql -h localhost -p 15432 -U postgres -d maborak  # db2
```

### Essential Commands

```bash
# Cluster status
docker exec db1 patronictl -c /etc/patroni/patroni.yml list

# Health check
./check_stack.sh

# Create backup
docker exec barman barman backup db1

# PITR
bash scripts/pitr/perform_pitr.sh <backup-id> <target-time> --server db1 --target db2 --restore

# Switchover
docker exec db1 patronictl -c /etc/patroni/patroni.yml switchover patroni1 --master db1 --candidate db2
```

---

## Contributing

This is a learning/development playground. Contributions welcome for:
- Additional health checks
- More comprehensive runbooks
- Performance tuning guides
- Security hardening examples
- Monitoring integration examples

---

## License

[Specify license if applicable]
