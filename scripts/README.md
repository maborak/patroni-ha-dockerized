# Scripts Directory Documentation

This directory contains operational tooling for the Patroni HA + Barman stack. Scripts are currently organized flatly but serve distinct purposes.

## Script Classification (Proposed)

For better organization, scripts can be categorized as follows:

### Proposed Structure

```
scripts/
├── ops/              # Lifecycle & HA operations
│   ├── check_replica.sh
│   └── (future: switchover.sh, failover.sh)
├── backup/           # Barman / backup tasks
│   ├── check_archive_command.sh
│   └── (future: backup_schedule.sh)
├── pitr/             # PITR workflows
│   └── perform_pitr.sh  ⭐ (DO NOT MOVE - critical script)
├── debug/            # Diagnostics & inspection
│   ├── get_stack_info.sh
│   ├── pg_activity_monitor.sh
│   ├── pg_stat_statements_query.sh
│   ├── pgmetrics_collect.sh
│   └── count_database_stats.sh
└── utils/            # Helpers
    ├── setup_ssh_keys.sh
    ├── test_ssh_to_barman.sh
    ├── test_barman_ssh_to_patroni.sh
    └── test_barman_postgres_connectivity.sh
```

**Backward Compatibility**: Scripts remain in current location. Proposed organization is optional refactoring. If moving scripts:
- Keep original files as symlinks, OR
- Add wrapper scripts that call new locations

**Recommendation**: Keep current structure for now. Document scripts here instead of reorganizing.

---

## Script Inventory

### ⭐ Critical Scripts

#### `perform_pitr.sh` ⭐⭐⭐

**Purpose**: Automated Point-In-Time Recovery with full Patroni integration.

**When to use**: 
- After accidental data deletion
- Testing recovery procedures
- Restoring to specific timestamp

**Prerequisites**:
- Backup exists (`barman list-backup <server>`)
- WAL archiving active
- Target node available

**Example Usage**:
```bash
# Automated PITR (recommended)
bash scripts/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' \
  --server db1 \
  --target db2 \
  --restore \
  --wal-method barman-wal-restore \
  --auto-start

# Manual PITR (for learning)
bash scripts/perform_pitr.sh 20260123T120000 '2026-01-23 12:30:00' --server db1
```

**Expected Outcome**: 
- Recovery files created in Barman container
- If `--target` specified: PITR applied to target node, node promoted to leader
- If `--auto-start`: Other nodes reinitialized as replicas

**Common Failure Modes**:
- WAL gaps → Recovery stops, script warns before proceeding
- Target time before backup → Script validates and exits
- SSH connectivity issues → Check `./check_stack.sh` first

**See**: `docs/tools/perform_pitr.md` for complete documentation.

---

### Operations & HA Scripts

#### `check_replica.sh`

**Purpose**: HAProxy health check script - determines if node is a replica.

**When to use**: Called automatically by HAProxy for read backend health checks.

**Prerequisites**: Node running, Patroni API accessible

**Example Usage**:
```bash
# Called by HAProxy (not directly)
# HAProxy config: option httpchk GET /replica
```

**Expected Outcome**: Exit code 0 if replica, 1 otherwise

**Common Failure Modes**: Patroni API unreachable → returns 1 (node marked unhealthy)

---

### Backup & Archive Scripts

#### `check_archive_command.sh`

**Purpose**: Verify WAL archiving is working on the leader node.

**When to use**: 
- After stack startup
- When WAL archiving appears to have stopped
- Troubleshooting backup issues

**Prerequisites**: Stack running, leader identified

**Example Usage**:
```bash
bash scripts/check_archive_command.sh
```

**Expected Outcome**: 
- Shows current leader
- Verifies `archive_mode` is on
- Tests archive command execution
- Shows recent archive log entries

**Common Failure Modes**:
- Leader not found → Exits with error
- Archive command fails → Shows error details

---

### Diagnostics & Monitoring Scripts

#### `get_stack_info.sh`

**Purpose**: Comprehensive stack health check with JSON or human-readable output.

**When to use**: 
- Understanding current cluster state
- Integration with monitoring systems (JSON output)
- Quick health overview

**Prerequisites**: Stack running

**Example Usage**:
```bash
# Human-readable output
bash scripts/get_stack_info.sh --human

# JSON output (for automation)
bash scripts/get_stack_info.sh --json
```

**Expected Outcome**: 
- Container status
- Patroni roles
- etcd health
- Port accessibility
- Connection strings

**Common Failure Modes**: Containers not running → Shows "not running" status

---

#### `pg_activity_monitor.sh`

**Purpose**: Real-time PostgreSQL activity monitoring using `pg_activity`.

**When to use**: 
- Investigating slow queries
- Monitoring active connections
- Understanding current workload

**Prerequisites**: 
- `pg_activity` installed in barman container (not currently installed)
- Stack running

**Example Usage**:
```bash
# Monitor leader
bash scripts/pg_activity_monitor.sh --node db1

# Auto-detect leader
bash scripts/pg_activity_monitor.sh
```

**Expected Outcome**: Interactive `pg_activity` session showing queries, connections, locks

**Common Failure Modes**: `pg_activity` not installed → Script reports missing dependency

**Status**: ⚠️ Requires `pg_activity` installation (not in Dockerfile currently)

---

#### `pg_stat_statements_query.sh`

**Purpose**: Query `pg_stat_statements` extension for query performance analysis.

**When to use**: 
- Identifying slow queries
- Understanding query patterns
- Performance tuning

**Prerequisites**: 
- `pg_stat_statements` enabled (✅ enabled in patroni configs)
- Stack running

**Example Usage**:
```bash
# Query top 10 slowest queries
bash scripts/pg_stat_statements_query.sh

# Target specific node
bash scripts/pg_stat_statements_query.sh --node db2
```

**Expected Outcome**: Query statistics (total time, calls, mean time, etc.)

**Common Failure Modes**: Extension not loaded → Returns empty results

---

#### `pgmetrics_collect.sh`

**Purpose**: Collect PostgreSQL metrics using `pgmetrics` tool.

**When to use**: 
- Performance analysis
- Capacity planning
- Health monitoring

**Prerequisites**: 
- `pgmetrics` installed in barman container (not currently installed)
- Stack running

**Example Usage**:
```bash
# Collect from leader (default)
bash scripts/pgmetrics_collect.sh

# Collect from all nodes
bash scripts/pgmetrics_collect.sh --all-nodes

# JSON output
bash scripts/pgmetrics_collect.sh --format json --output-dir ./reports
```

**Expected Outcome**: Metrics files in specified output directory

**Common Failure Modes**: `pgmetrics` not installed → Script reports missing dependency

**Status**: ⚠️ Requires `pgmetrics` installation (not in Dockerfile currently)

---

#### `count_database_stats.sh`

**Purpose**: Count tables, rows, and database statistics for verification.

**When to use**: 
- After PITR to verify data restored
- After data imports
- General database inspection

**Prerequisites**: Stack running, database accessible

**Example Usage**:
```bash
# Count stats on leader
bash scripts/count_database_stats.sh

# Target specific node
bash scripts/count_database_stats.sh db2
```

**Expected Outcome**: Table counts, row counts, database size

**Common Failure Modes**: Database unreachable → Connection error

---

#### `monitor_analyze.sh`

**Purpose**: Monitor `ANALYZE` progress in real-time.

**When to use**: 
- During large ANALYZE operations
- Understanding analyze performance
- Troubleshooting slow statistics updates

**Prerequisites**: Stack running, ANALYZE in progress

**Example Usage**:
```bash
# Monitor leader
bash scripts/monitor_analyze.sh

# Target specific node
bash scripts/monitor_analyze.sh db2
```

**Expected Outcome**: Real-time progress of ANALYZE operations

**Common Failure Modes**: No ANALYZE running → Shows empty results

---

#### `monitor_recovery.sh`

**Purpose**: Monitor PostgreSQL recovery progress.

**When to use**: 
- During PITR recovery
- After crash recovery
- Understanding recovery performance

**Prerequisites**: Node in recovery mode

**Example Usage**:
```bash
# Monitor recovery on db2
bash scripts/monitor_recovery.sh db2
```

**Expected Outcome**: Recovery LSN progress, time remaining estimates

**Common Failure Modes**: Node not in recovery → Shows "not in recovery"

---

### Testing & Validation Scripts

#### `test_ssh_to_barman.sh`

**Purpose**: Test SSH connectivity from all Patroni nodes to Barman.

**When to use**: 
- After stack startup
- Troubleshooting WAL archiving failures
- Verifying SSH key setup

**Prerequisites**: Stack running, SSH keys configured

**Example Usage**:
```bash
bash scripts/test_ssh_to_barman.sh
```

**Expected Outcome**: Success/failure for each node → barman connection

**Common Failure Modes**: 
- SSH keys missing → Permission denied
- Barman unreachable → Connection refused

---

#### `test_barman_ssh_to_patroni.sh`

**Purpose**: Test SSH connectivity from Barman to all Patroni nodes.

**When to use**: 
- After stack startup
- Troubleshooting backup failures
- Verifying bidirectional SSH

**Prerequisites**: Stack running, SSH keys configured

**Example Usage**:
```bash
bash scripts/test_barman_ssh_to_patroni.sh
```

**Expected Outcome**: Success/failure for each barman → node connection

**Common Failure Modes**: 
- SSH keys missing → Permission denied
- Node unreachable → Connection refused

---

#### `test_barman_postgres_connectivity.sh`

**Purpose**: Test PostgreSQL connectivity from Barman to Patroni nodes.

**When to use**: 
- Verifying Barman can connect for backups
- Troubleshooting backup failures

**Prerequisites**: Stack running, PostgreSQL accessible

**Example Usage**:
```bash
bash scripts/test_barman_postgres_connectivity.sh
```

**Expected Outcome**: Connection success/failure for each node

**Common Failure Modes**: 
- Wrong credentials → Authentication failed
- Network issues → Connection timeout

---

### Maintenance Scripts

#### `vacuum_optimize.sh`

**Purpose**: Run VACUUM and ANALYZE operations across cluster.

**When to use**: 
- Regular maintenance
- After large data changes
- Performance optimization

**Prerequisites**: Stack running

**Example Usage**:
```bash
# Vacuum all databases on leader
bash scripts/vacuum_optimize.sh

# Target specific node
bash scripts/vacuum_optimize.sh --node db2
```

**Expected Outcome**: VACUUM and ANALYZE completed, statistics updated

**Common Failure Modes**: 
- Database locked → VACUUM waits or times out
- Insufficient disk space → Operation fails

---

#### `generate_pgbadger_report.sh`

**Purpose**: Generate pgBadger reports from PostgreSQL logs.

**When to use**: 
- Performance analysis
- Query pattern analysis
- Log analysis

**Prerequisites**: 
- PostgreSQL logs available
- pgBadger installed (✅ in barman container)

**Example Usage**:
```bash
# Generate report for leader
bash scripts/generate_pgbadger_report.sh

# Target specific node
bash scripts/generate_pgbadger_report.sh --node db2
```

**Expected Outcome**: HTML report in `./reports/` directory

**Common Failure Modes**: 
- No logs found → Empty report
- Log format incorrect → Parsing errors

---

### Data Management Scripts

#### `import_external_database.sh`

**Purpose**: Import external database dump into cluster.

**When to use**: 
- Migrating data from another system
- Loading test data
- Restoring from pg_dump

**Prerequisites**: 
- Dump file available
- Stack running
- Sufficient disk space

**Example Usage**:
```bash
bash scripts/import_external_database.sh /path/to/dump.sql
```

**Expected Outcome**: Database imported, tables created, data loaded

**Common Failure Modes**: 
- Dump file corrupted → Import fails
- Insufficient privileges → Permission errors

---

#### `create_databases.sh`

**Purpose**: Create databases and users (called by Patroni post_bootstrap).

**When to use**: Automatically called during cluster initialization.

**Prerequisites**: Patroni bootstrap process

**Example Usage**: Not called directly - part of Patroni bootstrap

**Expected Outcome**: Default database created

---

### Stress Testing Scripts

#### `stress_test_db.sh` / `stress_test_db.py`

**Purpose**: Generate large amounts of test data for performance testing.

**When to use**: 
- Testing backup/restore performance
- Load testing
- Capacity planning

**Prerequisites**: Stack running

**Example Usage**:
```bash
# Bash version
bash scripts/stress_test_db.sh

# Python version (more features)
python3 scripts/stress_test_db.py
```

**Expected Outcome**: 
- Multiple tables created
- Large volumes of data inserted
- Performance metrics reported

**Common Failure Modes**: 
- Disk full → Insertions fail
- Memory exhaustion → OOM errors

**See**: `scripts/README_stress_test.md` for detailed usage.

---

#### `cleanup_stress_test.sh`

**Purpose**: Clean up data created by stress test scripts.

**When to use**: After stress testing, to free disk space

**Prerequisites**: Stress test data exists

**Example Usage**:
```bash
bash scripts/cleanup_stress_test.sh
```

**Expected Outcome**: Stress test tables dropped, disk space freed

---

### Setup Scripts

#### `setup_ssh_keys.sh`

**Purpose**: Generate SSH key pair for Patroni → Barman communication.

**When to use**: 
- Initial setup (one-time)
- After key rotation
- When keys are missing

**Prerequisites**: Write access to `ssh_keys/` directory

**Example Usage**:
```bash
bash scripts/setup_ssh_keys.sh
```

**Expected Outcome**: 
- `ssh_keys/barman_rsa` (private key)
- `ssh_keys/barman_rsa.pub` (public key)

**Common Failure Modes**: 
- Directory not writable → Permission denied
- Keys already exist → Script reports and exits

**Note**: Keys are mounted into containers via `docker-compose.yml`

---

## Deprecated / Overlapping Scripts

**None currently identified.** All scripts serve distinct purposes.

---

## Script Dependencies

### External Tools Required

| Tool | Used By | Status |
|------|---------|--------|
| `pg_activity` | `pg_activity_monitor.sh` | ⚠️ Not installed |
| `pgmetrics` | `pgmetrics_collect.sh` | ⚠️ Not installed |
| `pgbadger` | `generate_pgbadger_report.sh` | ✅ Installed in barman |
| `python3` | Multiple scripts | ✅ Installed |
| `curl` | Multiple scripts | ✅ Installed |
| `nc` (netcat) | `get_stack_info.sh`, `check_stack.sh` | ✅ Installed |

### Internal Dependencies

- `perform_pitr.sh` → Uses `monitor_recovery.sh` (if available)
- `check_stack.sh` → Uses all test scripts conceptually
- Most scripts → Depend on `docker` and `docker-compose`

---

## Environment Variables

Most scripts respect these environment variables (from `.env` or defaults):

- `PATRONI_DB1_PORT` - `15431` (default)
- `PATRONI_DB1_API_PORT` - `8001` (default)
- `POSTGRES_PASSWORD` - Database password
- `DEFAULT_DATABASE` - `maborak` (default)
- `PATRONI_CLUSTER_NAME` - `patroni1` (default, for `perform_pitr.sh`)

---

## Best Practices

1. **Always run `./check_stack.sh` first** - Ensures stack is healthy before operations
2. **Use `--target` flag for PITR** - Automated application is safer than manual
3. **Check logs on failure** - Scripts provide error messages, but logs have details
4. **Verify prerequisites** - Many scripts fail silently if prerequisites not met
5. **Test in non-production first** - Especially for PITR and maintenance operations

---

## Contributing New Scripts

When adding new scripts:

1. **Add shebang**: `#!/bin/bash` or `#!/usr/bin/env python3`
2. **Use `set -euo pipefail`** (bash) for error handling
3. **Document in this README** - Add entry with Purpose, Usage, Prerequisites
4. **Follow naming convention**: `verb_noun.sh` (e.g., `check_replica.sh`)
5. **Add color output** - Use standard colors (RED, GREEN, YELLOW, BLUE, CYAN, NC)
6. **Handle errors gracefully** - Show helpful error messages

---

## Migration Path (If Reorganizing)

If you choose to reorganize scripts into subdirectories:

**Option 1: Symlinks (Recommended)**
```bash
mkdir -p scripts/{ops,backup,pitr,debug,utils}
mv scripts/perform_pitr.sh scripts/pitr/
ln -s ../pitr/perform_pitr.sh scripts/perform_pitr.sh
```

**Option 2: Wrapper Scripts**
```bash
# scripts/perform_pitr.sh becomes:
#!/bin/bash
exec "$(dirname "$0")/pitr/perform_pitr.sh" "$@"
```

**Option 3: Keep Current Structure**
- Simplest approach
- All scripts remain accessible
- No breaking changes

**Recommendation**: Keep current structure. Documentation (this file) provides organization without filesystem changes.
