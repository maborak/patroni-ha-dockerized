# Scripts Directory Organization

This document describes the organization of scripts in the `scripts/` directory.

## Directory Structure

```
scripts/
├── ops/                    # Lifecycle & HA operations
│   └── check_replica.sh
│
├── backup/                 # Barman / backup tasks
│   └── check_archive_command.sh
│
├── pitr/                   # Point-In-Time Recovery workflows
│   ├── perform_pitr.sh     ⭐ Critical script
│   └── monitor_recovery.sh
│
├── debug/                  # Diagnostics & inspection
│   ├── get_stack_info.sh
│   ├── pg_activity_monitor.sh
│   ├── pg_stat_statements_query.sh
│   ├── pgmetrics_collect.sh
│   ├── count_database_stats.sh
│   └── monitor_analyze.sh
│
├── utils/                  # Helper utilities
│   ├── setup_ssh_keys.sh
│   └── (create_databases.sh moved to patroni/ - critical Patroni script)
│   ├── test_ssh_to_barman.sh
│   ├── test_barman_ssh_to_patroni.sh
│   └── test_barman_postgres_connectivity.sh
│
├── maintenance/            # Maintenance tasks
│   ├── vacuum_optimize.sh
│   ├── generate_pgbadger_report.sh
│   └── import_external_database.sh
│
└── testing/                # Testing & stress testing
    ├── stress_test_db.sh
    ├── stress_test_db.py
    ├── cleanup_stress_test.sh
    └── README_stress_test.md
```

## Script Paths

**All scripts must be accessed via their organized paths:**

- `scripts/pitr/perform_pitr.sh`
- `scripts/debug/get_stack_info.sh`
- `scripts/utils/setup_ssh_keys.sh`
- `patroni/create_databases.sh` (built into image)
- `scripts/debug/count_database_stats.sh`
- `scripts/debug/monitor_analyze.sh`
- `scripts/pitr/monitor_recovery.sh`
- `scripts/testing/cleanup_stress_test.sh`

**Note**: Backward compatibility symlinks have been removed. Update all references to use the new organized paths.

## Usage Examples

### Using Organized Paths
```bash
# PITR
bash scripts/pitr/perform_pitr.sh 20260123T120000 latest --server db1 --target db2 --restore

# Debugging
bash scripts/debug/get_stack_info.sh --human

# Testing
bash scripts/testing/stress_test_db.sh

# Maintenance
bash scripts/maintenance/vacuum_optimize.sh

# Utilities
bash scripts/utils/setup_ssh_keys.sh
```

## Migration Notes

- **Date**: 2026-01-23
- **All scripts moved** to organized subdirectories
- **Symlinks created** for critical scripts
- **No breaking changes** - all existing references work
- **Patroni configs** reference `/etc/patroni/create_databases.sh` (built into Patroni Docker image from `patroni/create_databases.sh`)

## Script Count by Category

- **ops/**: 1 script
- **backup/**: 1 script
- **pitr/**: 2 scripts
- **debug/**: 6 scripts
- **utils/**: 5 scripts
- **maintenance/**: 3 scripts
- **testing/**: 3 scripts (2 shell, 1 Python)

**Total**: 21 scripts + 1 Python script + 1 README
