# Monitoring & Backup Verification

## Backup verification (`make verify-backup`)

Proves a backup is restorable — the only test that matters.

```bash
make verify-backup                    # latest backup of stanza db1
make verify-backup SERVER=db2 BACKUP_ID=20260824-144511F_20260824-155917I DEEP=1
```

What it does: snapshots the repo volume → launches an ephemeral container from the DB image
→ `pgbackrest restore` into it → boots PostgreSQL on a private unix socket → checks version,
database inventory, tables; with `DEEP=1` also compares schema dump hash against a live node.
Artifacts are auto-removed on success, kept for debugging on failure.

## Monitoring stack (opt-in)

Enable in `.env`: `ENABLE_MONITORING=1`, then:

```bash
make generate        # re-render compose + configs/prometheus.yml
make monitoring-up   # prometheus, grafana, alertmanager, exporters
make monitoring-status
make monitoring-down
```

Endpoints (ports from `.env`):

| Service | URL | Auth |
|---|---|---|
| Grafana | http://localhost:$GRAFANA_PORT | admin / GRAFANA_ADMIN_PASSWORD |
| Prometheus | http://localhost:$PROMETHEUS_PORT/targets | — |
| Alertmanager | http://localhost:$ALERTMANAGER_PORT | — |

Dashboard **"PostgreSQL HA — Swiss Knife"** (auto-provisioned): Patroni topology table,
leader presence, replication lag bytes/seconds, WAL archiver health, TPS, cache hit ratio,
connections vs max, temp files, deadlocks, checkpoints, HAProxy session rates, per-node
DB sizes.

Alerts (`monitoring/prometheus-alerts.yml`): no leader >1m, node down >2m, replication lag
>64MB for 5m, WAL archive failures, archive staleness >10min, postgres restart,
connection saturation >85%. Wire a real receiver in `monitoring/alertmanager.yml`
(webhook/Slack) — default is a null sink.
