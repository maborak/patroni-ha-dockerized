# Scripts Directory Documentation

Operational tooling for the Patroni HA + Barman stack, organized by purpose.

## Directory Structure

```
scripts/
├── generate_configs.sh        # Render configs/ from templates (.env values)
├── lib/
│   └── common.sh              # Shared lib: colors, .env loading, node discovery, leader detection
├── ops/                       # Lifecycle & HA operations
│   ├── check_replica.sh       # HAProxy health check (replica endpoint)
│   ├── lib/
│   │   └── cross_cluster.sh   # Shared helpers for cross-cluster switchover
│   ├── switchover_to_remote.sh
│   └── switchover_from_remote.sh
├── backup/                    # Barman / backup tasks
│   ├── check_archive_command.sh
│   ├── dump_database.sh
│   └── restore_database.sh
├── pitr/                      # Point-In-Time Recovery workflows
│   ├── perform_pitr.sh        # ⭐ critical PITR script (also powers `make pitr`)
│   └── monitor_recovery.sh
├── debug/                     # Diagnostics & inspection
│   ├── count_database_stats.sh
│   ├── disk_usage.sh
│   ├── get_stack_info.sh
│   ├── list_databases.sh
│   ├── monitor_analyze.sh
│   ├── pg_activity_monitor.sh
│   ├── pg_stat_statements_query.sh
│   └── pgmetrics_collect.sh
├── maintenance/               # Maintenance tasks
│   ├── vacuum_optimize.sh
│   ├── generate_pgbadger_report.sh
│   └── import_external_database.sh
├── utils/                     # Helpers
│   ├── setup_ssh_keys.sh
│   ├── test_ssh_to_barman.sh
│   ├── test_barman_ssh_to_patroni.sh
│   ├── test_barman_postgres_connectivity.sh
│   └── wizard.sh              # Guided setup wizard (powers `make wizard`)
└── testing/                   # Testing & stress testing
    ├── smoke_test_wizard.sh   # Powers `make smoke-test`
    ├── smoke_test_pitr.sh     # Powers `make smoke-test`
    ├── stress_test_db.sh
    ├── stress_test_db.py
    ├── cleanup_stress_test.sh
    └── README_stress_test.md
```

Generated artifacts such as `scripts/db_stats_*.json` and `__pycache__/` may appear here at runtime; they are not tracked tooling.

Most scripts are reachable through Makefile targets — the per-script entries below note the target when one exists. Calling scripts directly is also fine:

```bash
bash scripts/pitr/perform_pitr.sh ...
bash scripts/debug/get_stack_info.sh --human
bash scripts/utils/setup_ssh_keys.sh
```

**Note**: old flat paths (e.g., `scripts/perform_pitr.sh`) no longer exist — always use the organized paths above.

---

## Script Inventory

### Root

#### `generate_configs.sh` — `make generate`

Renders all configuration files under `configs/` from templates using values from `.env`. Runs automatically as part of `make up`.

---

### Setup & Utilities

#### `wizard.sh` — `make wizard`

Interactive step-by-step setup wizard: configure → review values → confirm → build. Preferred guided entry point for first-time startup.

#### `setup_ssh_keys.sh` — `make setup-keys`

Generates the SSH keypair used for Patroni ↔ Barman communication into `ssh_keys/` (mounted into containers via `docker-compose.yml`). One-time setup; also runs automatically before config generation.

#### `test_ssh_to_barman.sh` / `test_barman_ssh_to_patroni.sh` — `make test-ssh`

Verify SSH connectivity in both directions (all nodes → Barman, and Barman → all nodes). Use after startup or when WAL archiving/backups fail.

#### `test_barman_postgres_connectivity.sh` — `make test-connectivity`

Verifies Barman can reach PostgreSQL on all Patroni nodes (required for backups).

---

### Backup & Restore

#### `check_archive_command.sh` — `make check-archive`

Verifies WAL archiving is working on the leader: shows current leader, checks `archive_mode`, tests the archive command, and shows recent archive log entries.

#### `dump_database.sh` — `make dump-db`

Logical `.tgz` backup of a single database from a healthy replica (`make dump-db DB=name [NODE=db3] [JOBS=8]`, or `make dump-db` for interactive selection). Keeps load off the leader.

#### `restore_database.sh` — `make restore-db`

Restores a database from a `.tgz` archive produced by `dump_database.sh`, into a local node or a remote target URI (`make restore-db ARCHIVE=path [TARGET=name|URI] [CLEAN=1]`, or interactive).

---

### PITR

#### `perform_pitr.sh` ⭐ — `make pitr`

Automated Point-In-Time Recovery with full Patroni integration.

- **No arguments**: interactive wizard (select backup → target node → WAL method → target time → summary → confirm). Re-scan backups with `r` at the selection prompt.
- **Full arguments**: direct execution — `make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' SERVER=db1 TARGET=db2 RESTORE=1 AUTO_START=1`.
- **Partial arguments**: usage help is printed.
- **Remote mode**: `--target ssh://user@host[:port]/abs/path` ships the recovered `PGDATA` to a non-cluster host via SSH + rsync and prints manual next steps. Incompatible with `--restore`/`--auto-start`; refuses shallow paths like `/var` or `/tmp`.

Full reference: `docs/tools/perform_pitr.md`. Guide (scenarios, WAL methods, troubleshooting): `docs/pitr.md`.

#### `monitor_recovery.sh` — `make monitor-recovery NODE=db2`

Monitors PostgreSQL recovery progress on a node: replay LSN, progress, time estimates.

---

### Diagnostics & Monitoring

#### `get_stack_info.sh` — `make info`

Comprehensive stack health check (`--human` or `--json`): container status, Patroni roles, etcd health, port accessibility, connection strings.

#### `disk_usage.sh` — `make disk`

Disk usage report and targeted cleanup (`make disk CLEANUP=logs|dumps|docker|snapshots|temp|barman|all [KEEP_DAYS=N] [DRYRUN=1]`, or `make disk FORMAT=json`).

#### `list_databases.sh` — `make list-dbs`

Lists databases on the leader (or any node via `NODE=`), with `FORMAT=json` and `TEMPLATES=1` options.

#### `count_database_stats.sh` — `make stats`

Counts tables, rows, and database sizes. Useful for verifying data after PITR or imports (`make stats NODE=db2`; auto-detects leader when `NODE` is omitted).

#### `pg_activity_monitor.sh` — `make activity`

Real-time activity monitoring via `pg_activity`. ⚠️ Requires `pg_activity` to be installed in the barman container (not currently in the Dockerfile).

#### `pg_stat_statements_query.sh` — `make slow-queries`

Queries `pg_stat_statements` (enabled in the Patroni configs) for top slow queries: `make slow-queries NODE=db1 LIMIT=10`.

#### `monitor_analyze.sh`

Monitors `ANALYZE` progress in real time. Use during large statistics updates.

#### `pgmetrics_collect.sh`

Collects metrics with `pgmetrics`. ⚠️ Requires `pgmetrics` to be installed in the barman container (not currently in the Dockerfile).

---

### Maintenance

#### `vacuum_optimize.sh` — `make vacuum` / `make analyze`

Runs VACUUM/ANALYZE across the cluster: `make vacuum NODE=db1`, `make vacuum ALL=1`, or `make analyze ALL=1` for ANALYZE only.

#### `generate_pgbadger_report.sh` — `make pgbadger`

Generates an HTML pgBadger report from PostgreSQL logs (pgBadger is installed in the barman container). `make pgbadger NODE=db1`; auto-detects leader when `NODE` is omitted.

#### `import_external_database.sh`

Imports an external database dump into the cluster:

```bash
bash scripts/maintenance/import_external_database.sh /path/to/dump.sql
```

---

### Operations

#### `check_replica.sh`

HAProxy health-check script for the read backend — called by HAProxy against the Patroni API (`/replica`), not by users. Exits 0 if the node is a replica.

#### `switchover_to_remote.sh` — `make switchover-to-remote`

Cross-cluster switchover, local → remote standby cluster (forward direction). Supports `YES=1` (skip prompts), `DRY_RUN=1`, `SKIP_BACKUP=1`. See `docs/switchover.md`.

#### `switchover_from_remote.sh` — `make switchover-from-remote`

Cross-cluster switchover, remote → local (reverse direction). Same flags as above. See `docs/switchover.md`.

---

### Testing

#### `smoke_test_wizard.sh` / `smoke_test_pitr.sh` — `make smoke-test`

End-to-end smoke tests for the setup wizard and the PITR wizard, using sandboxed docker stubs — no Docker or running stack needed.

#### `stress_test_db.sh` / `stress_test_db.py`

Generate large volumes of test data for performance/load testing. The Python version is strongly recommended (10-100x faster). See `testing/README_stress_test.md` for details.

```bash
bash scripts/testing/stress_test_db.sh
python3 scripts/testing/stress_test_db.py --tables 10 --rows 10000 --threads 8
```

#### `cleanup_stress_test.sh`

Drops the tables created by the stress tests and frees the disk space:

```bash
bash scripts/testing/cleanup_stress_test.sh
```

---

### Referenced from outside `scripts/`

- `patroni/create_databases.sh` — creates the default database during Patroni bootstrap. Not called directly; built into the Patroni image at `/etc/patroni/create_databases.sh` and wired via `post_bootstrap` in `configs/patroni*.yml`. Database name comes from `DEFAULT_DATABASE`.

---

## Shared Library

### `lib/common.sh`

Source at the top of any script that needs node discovery, colors, `.env` loading, or leader detection:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
```

Provides: color constants, `get_db_nodes` (db1..dbN from `PATRONI_REPLICAS`), `get_patroni_data_dir` (`/var/lib/postgresql/<PG_VERSION>/<CLUSTER_NAME>/`), leader detection, and node validation.

---

## Environment Variables

Scripts read these from `.env` (auto-loaded by `lib/common.sh`) or the environment:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PATRONI_REPLICAS` | `2` | Number of replicas; nodes are db1..dbN where N = replicas + 1 |
| `PATRONI_CLUSTER_NAME` | `patroni1` | Patroni cluster name (also the data dir name) |
| `POSTGRES_VERSION` | probed / `15` | PostgreSQL major version (data dir path) |
| `PATRONI_BASE_PORT` | `15431` | Host port for db1; dbN = base + N - 1 |
| `PATRONI_API_BASE_PORT` | `8001` | Host Patroni API port for db1 |
| `HAPROXY_WRITE_PORT` | `5551` | HAProxy write endpoint |
| `HAPROXY_READ_PORT` | `5552` | HAProxy read endpoint |
| `HAPROXY_STATS_PORT` | `5553` | HAProxy stats page |
| `PGBOUNCER_PORT` / `PGBOUNCER_RO_PORT` | `6432` / `6433` | PgBouncer write / read endpoints |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | — | Database superuser credentials |
| `DEFAULT_DATABASE` | `maborak` | Default database name |
| `PITR_ALLOW_PIPED` | `0` | `1` lets the PITR wizard run with piped stdin (testing) |
| `KEEP_TMP_ON_FAILURE` | `0` | `1` keeps PITR staging dirs after a failed run |

---

## Script Dependencies

| Tool | Used by | Status |
|------|---------|--------|
| `docker` / `docker-compose` | Most scripts | ✅ Required |
| `rsync` | `perform_pitr.sh` (remote mode), `restore_database.sh` | ✅ Required for remote PITR |
| `psycopg2-binary` | `stress_test_db.py` | ✅ Via root `requirements.txt` |
| `pgbadger` | `generate_pgbadger_report.sh` | ✅ Installed in barman container |
| `python3` | `stress_test_db.py` | ✅ Required |
| `pg_activity` | `pg_activity_monitor.sh` | ⚠️ Not installed |
| `pgmetrics` | `pgmetrics_collect.sh` | ⚠️ Not installed |

Internal: `perform_pitr.sh` uses `monitor_recovery.sh` (if available); `switchover_*.sh` share `ops/lib/cross_cluster.sh`; most scripts source `lib/common.sh`.

---

## Best Practices

1. **Run `make check` first** — ensures the stack is healthy before operations.
2. **Prefer the interactive wizards** — `make wizard` for setup, `make pitr` for recovery; they validate as you go.
3. **Check logs on failure** — scripts print error messages, but container logs have the details.
4. **Verify prerequisites** — many scripts fail early (not silently) if prerequisites are missing.
5. **Test in non-production first** — especially for PITR and cross-cluster switchover.

---

## Contributing New Scripts

1. **Shebang**: `#!/bin/bash` or `#!/usr/bin/env python3`
2. **Error handling**: `set -euo pipefail` (bash)
3. **Shared helpers**: source `lib/common.sh` for colors, `.env`, and node discovery instead of re-implementing them
4. **Naming**: `verb_noun.sh`; place in the appropriate subdirectory
5. **Document here**: add an entry with purpose and usage
6. **Makefile**: add or reuse a target when the script is user-facing
