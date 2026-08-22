# Patroni HA Dockerized

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Patroni](https://img.shields.io/badge/HA-Patroni-orange)](https://github.com/patroni/patroni)
[![Barman](https://img.shields.io/badge/Backup-Barman-blue)](https://pgbarman.org)
[![etcd](https://img.shields.io/badge/DCS-etcd_3.5-419eda)](https://etcd.io)

A production-grade, single-command **PostgreSQL High-Availability lab and toolbox**, fully dockerized:

- **Patroni** automated failover with a **3-node etcd** quorum
- **HAProxy** read/write split with health-checked routing
- **PgBouncer** connection pooling (RW + read-only)
- **Barman** backups, WAL archiving and **Point-In-Time Recovery**
- **Interactive setup wizard**, interactive PITR wizard, and cross-cluster **DR switchover** tooling
- Everything is **configurable from one `.env` file** — node count, cluster name, ports, tuning, retention

> **Scope**: this project runs an entire HA stack on a single Docker host (laptop, homelab, or a beefy server). It is perfect for learning, demos, CI, and operating real-but-modest workloads. It is *not* a multi-host Kubernetes-style deployment.

---

## Table of Contents

1. [Features](#features)
2. [Quickstart](#quickstart)
   - [Interactive wizard (recommended)](#interactive-wizard-recommended)
   - [Non-interactive setup](#non-interactive-setup)
   - [Verify the cluster](#verify-the-cluster)
3. [Architecture](#architecture)
4. [Configuration](#configuration)
5. [Everyday operations](#everyday-operations)
6. [Backup & PITR](#backup--pitr)
7. [Disaster recovery (remote standby)](#disaster-recovery-remote-standby)
8. [Testing](#testing)
9. [Troubleshooting](#troubleshooting)
10. [Security notes](#security-notes)
11. [Project layout](#project-layout)
12. [Documentation index](#documentation-index)
13. [FAQ](#faq)
14. [Contributing](#contributing)
15. [License](#license)

---

## Features

| Area | What you get |
|---|---|
| **High availability** | N-node Patroni cluster (1 leader + N−1 replicas, default 4 nodes) with automated leader election and failover |
| **Consensus** | 3-node etcd cluster (quorum of 2, tolerates one failure) |
| **Routing** | HAProxy: `:5551` writes → current leader, `:5552` reads → replicas (health-checked via the Patroni API) |
| **Pooling** | 2× PgBouncer in transaction mode: `:6432` read-write, `:6433` read-only |
| **Backups** | Barman with per-node WAL archiving, retention policy, parallel jobs, bandwidth limits |
| **Log analytics** | pgBadger container: cron-driven JSON log collection from all nodes, source cleanup after verified pull, retention, and a built-in web UI (`:8080`) |
| **PITR** | Interactive recovery wizard: pick backup → target node → WAL method → target time → done |
| **DR** | Cross-cluster switchover runbooks + scripts to promote a remote standby cluster and back |
| **Ops toolbox** | ~45 `make` targets: health checks, switchover/failover, replica reinit, vacuum, pgBadger, dumps, stress tests |
| **Testing** | Sandboxed smoke tests (`make smoke-test`) that exercise the setup and PITR wizards with stubbed Docker — no cluster required |

## Quickstart

Requirements: Docker (with Compose v2), `make`, `openssl`, `python3`.

### Interactive wizard (recommended)

```bash
git clone <this-repo> patroni-ha && cd patroni-ha
make wizard
```

The wizard detects your state (fresh / stopped-with-data / running) and walks you through six steps:

1. **Cluster identity** — name (default `patroni1`)
2. **Database nodes** — replica count (e.g. `3` → `db1..db4`)
3. **Administrator** — superuser name and generated or custom passwords
4. **Default database** — created on first bootstrap
5. **Ports** — HAProxy / PgBouncer / node port bases
6. **Review** — nothing is written until you confirm

It then generates all configs, starts the stack, and waits for the cluster to elect a leader (~1–2 min on first bootstrap).

### Non-interactive setup

```bash
cp .env.example .env
$EDITOR .env        # at minimum: POSTGRES_PASSWORD, REPLICATOR_PASSWORD
make up             # generate configs + start
```

### Verify the cluster

```bash
make status         # Patroni + etcd health, endpoints, backups
make check          # comprehensive health check (replication, WAL, pooling, split-brain…)
make psql           # write via HAProxy → psql on the leader
make psql-read      # read via HAProxy → psql on a replica
```

Expected `make status` output (default topology):

```
+ Cluster: patroni1 (6970000000000000001) ---+
| Member | Host     | Role    | State     |
+--------+----------+---------+-----------+
| db1    | db1:5431 | Replica | streaming |
| db2    | db2:5431 | Leader  | running   |
| db3    | db3:5431 | Replica | streaming |
| db4    | db4:5431 | Replica | streaming |
+--------+----------+---------+-----------+
```

## Architecture

```text
                        ┌────────────────────────────────────────────┐
   apps / psql          │                 Docker host                │
  ────────────────►     │                                            │
                        │   HAProxy :5551 (write) :5552 (read)       │
                        │   PgBouncer :6432 (rw)  :6433 (ro)         │
                        │        │                                   │
                        │   ┌────┴───────────────────────────┐       │
                        │   │  db1 … dbN   (Patroni + PG 15) │       │
                        │   │  data dir per node, WAL →      │       │
                        │   └────┬──────────────────┬───────┘       │
                        │        │ DCS              │ rsync WAL     │
                        │   etcd1 etcd2 etcd3   Barman (:54320)     │
                        └────────┴──────────────────┴───────────────┘
```

- **Patroni** keeps member state in etcd; the leader holds the DCS lock. If it dies, a replica is promoted automatically (~10–30 s) and HAProxy follows the health checks.
- **HAProxy** routes `:5551` to whoever answers `GET /primary` and `:5552` round-robin across `GET /replica` healthy nodes.
- **Every node** ships WAL to Barman continuously (`archive_command`), so you can restore from any node's vantage point.
- **Config pipeline**: `templates/*.tpl` → `make generate` → `configs/`, `docker-compose.yml` (gitignored artifacts). The Patroni config itself is rendered *inside* each container at startup.

Full details: [docs/architecture.md](docs/architecture.md).

### Ports (defaults — all configurable in `.env`)

| Service | Host port(s) | Purpose |
|---|---|---|
| HAProxy | `5551` / `5552` / `5553` | write / read / stats page (auth required) |
| PgBouncer | `6432` / `6433` | pooled rw / pooled ro |
| Barman | `54320` | backup server API |
| pgBadger | `8080` | web UI for generated log-analysis reports |
| etcd | `2379`, `22379`, `32379` | DCS client ports (peers `+1`) |
| PostgreSQL nodes | `15431…1543N` | direct node access (bypasses failover) |
| Patroni API | `8001…800N` | per-node REST API |

## Configuration

Everything lives in **`.env`** (copy from `.env.example`). Key variables:

| Variable | Default | Notes |
|---|---|---|
| `PATRONI_CLUSTER_NAME` | `patroni1` | DCS scope + data-dir name. Changing requires destroy + re-bootstrap |
| `PATRONI_REPLICAS` | `3` | Replicas; leader is additional (total = N+1, hostnames `db1..dbN`) |
| `ETCD_COUNT` | `3` | Must be odd; changing requires destroy + re-bootstrap |
| `POSTGRES_VERSION` | `15` | Drives data dir & bin dir paths |
| `POSTGRES_PASSWORD` / `REPLICATOR_USER` / `REPLICATOR_PASSWORD` | — | **Set before first use** |
| `DEFAULT_DATABASE` | `maborak` | Created on bootstrap |
| `HAPROXY_*_PORT`, `PGBOUNCER_*_PORT`, `BARMAN_PORT` | see above | Host port mappings |
| `PG_SHARED_BUFFERS`, `PG_MAX_CONNECTIONS`, … | tuned defaults | PostgreSQL tuning, applied at bootstrap |
| `BARMAN_RETENTION_POLICY` | `RECOVERY WINDOW OF 7 DAYS` | Backup retention |
| `PGBADGER_CRON_EXPRESSION` | `*/30 * * * *` | pgBadger collection schedule (see `.env` examples) |
| `PGBADGER_PORT` | `8080` | pgBadger web UI port |
| `PGBADGER_RETENTION_DAYS` | `7` | Days of raw JSON logs kept for re-parsing |
| `PGBADGER_SAFETY_MINUTES` | `10` | Only pull log files untouched for ≥ N minutes |
| `REMOTE_*`, `MAC_VPN_HOST` | placeholders | Cross-cluster DR section — see [docs/switchover.md](docs/switchover.md) |

Scaling is an `.env` edit away:

```bash
# grow from 4 to 6 nodes
sed -i.bak 's/^PATRONI_REPLICAS=.*/PATRONI_REPLICAS=5/' .env
make up        # new nodes join as replicas and sync automatically
```

## Everyday operations

| Task | Command |
|---|---|
| Cluster status + endpoints | `make status` |
| Full health check | `make check` |
| Current leader | `make leader` |
| PSQL sessions | `make psql` / `make psql-read` / `make psql-node NODE=db3` |
| Planned switchover | `make switchover NEW_LEADER=db2` |
| Emergency failover | `make failover NEW_LEADER=db3` |
| Rebuild a replica | `make reinit NODE=db2` |
| Logs / shells | `make logs` / `make shell NODE=db1` |
| Disk usage | `make disk` |
| Vacuum / analyze / pgBadger | `make vacuum ALL=1` / `make analyze` / `make pgbadger` (UI at `http://localhost:8080/`) |
| Stop / restart / destroy | `make down` / `make restart` / `make destroy` (types `DESTROY`) |

Run `make help` for the full list (~45 targets).

## Backup & PITR

```bash
make backup                        # Barman base backup of the leader
make list-backups                  # list backups per server
make show-backups SERVER=db2 BACKUP_ID=20260821T120000
make check-archive                 # WAL archiving health
make import-db DSN='postgresql://user:pass@host:port/db'   # import an external DB (wizard if no DSN)
```

Point-in-time recovery is wizard-driven:

```bash
make pitr
# 1. select a backup (with re-scan)
# 2. select a target node
# 3. choose WAL method (barman-wal-restore recommended / barman-get-wal)
# 4. target time ('latest' or '2026-08-21 12:30:00')
# 5. review summary → confirm
```

Non-interactive equivalents:

```bash
make pitr BACKUP_ID=20260821T120000 TARGET_TIME='2026-08-21 12:30:00' \
          SERVER=db2 TARGET=db1 RESTORE=1 AUTO_START=1
```

Remote recovery (ship restored data to any host over SSH):

```bash
bash scripts/pitr/perform_pitr.sh 20260821T120000 latest \
    --target ssh://postgres@db.example.com/var/lib/postgresql/15/main
```

Guides: [docs/pitr.md](docs/pitr.md) · [docs/tools/perform_pitr.md](docs/tools/perform_pitr.md) · [docs/runbooks.md](docs/runbooks.md)

## Log analytics (pgBadger)

All nodes log in **JSON format** (`jsonlog` — configured at bootstrap). A dedicated `pgbadger` container:

1. **Collects** rotated JSON logs from every node on a cron schedule (`PGBADGER_CRON_EXPRESSION`, default every 30 min)
2. **Verifies** each copy byte-for-byte, then **deletes the source file** on the DB node — nodes never accumulate logs
3. **Re-parses** the full retained window (`PGBADGER_RETENTION_DAYS`, default 7) into a cluster-wide report
4. **Serves** the report at `http://localhost:8080/`

```bash
make pgbadger   # on-demand collection cycle + UI URL
```

Only files untouched for `PGBADGER_SAFETY_MINUTES` (default 10) are eligible, so a log the collector still has open is never pulled or deleted.

## Disaster recovery (remote standby)

The stack ships cross-cluster tooling to run a **standby Patroni cluster on remote hardware** and switch over in both directions:

```bash
make switchover-to-remote DRY_RUN=1   # rehearse
make switchover-to-remote             # promote the remote cluster (asks to confirm)
make switchover-from-remote           # and back
```

Setup guide: [docs/remote_standby.md](docs/remote_standby.md) · Runbook: [docs/switchover.md](docs/switchover.md)

## Testing

```bash
make smoke-test
```

Runs the setup-wizard and PITR-wizard smoke tests in a sandbox with stubbed `docker` binaries — no daemon, no containers, no risk to a running stack. Useful as a fast regression check after touching the wizard, config generation, or Makefile routing.

Also available: [stress testing tools](scripts/testing/README_stress_test.md).

## Troubleshooting

| Symptom | First checks |
|---|---|
| No leader elected | `docker logs db1`; etcd health in `make status` |
| Writes fail on `:5551` | HAProxy stats `:5553`; `make leader`; Patroni API `:800N` |
| Replicas lagging | `make check` (replication lag section); `make stats` |
| WAL archive failures | `make check-archive`; `docker exec barman barman check db1` |
| PgBouncer auth errors | `.env` credentials vs `configs/userlist.txt` regeneration (`make generate`) |
| Node stuck in `creating replica` | `make reinit NODE=dbN` |

More: [docs/runbooks.md](docs/runbooks.md#troubleshooting) · [docs/checks.md](docs/checks.md)

## Security notes

- **Secrets live in `.env`** (gitignored). Generated configs interpolate them at build time.
- **SSH keys** for Barman ↔ node communication are auto-generated into `ssh_keys/` (gitignored) on first run.
- **HAProxy stats page** requires basic auth (`HAPROXY_STATS_USER`/`HAPROXY_STATS_PASSWORD` — change the default).
- **Exposed ports**: this is a lab-friendly stack — etcd, node APIs and Barman are bound to localhost host ports. For anything beyond localhost, front it with a firewall or VPN and change all default passwords.
- Play with it freely; **do not expose it directly to the internet** as-shipped.

## Project layout

```
├── Makefile                 # ~45 operational targets (make help)
├── .env.example             # full configuration reference
├── templates/               # config templates (rendered by make generate / entrypoint)
├── patroni/                 # Patroni node image (entrypoint renders per-node config)
├── barman/                  # Barman image + supervisord
├── pgbadger/                # pgBadger image (cron collection + web UI)
├── remote-standby/          # standby-cluster Patroni template + Arch Linux PG15 build guide
├── scripts/
│   ├── utils/wizard.sh      # interactive setup wizard (make wizard)
│   ├── generate_configs.sh  # template renderer
│   ├── lib/common.sh        # shared helpers (node discovery, leader detection)
│   ├── checks/              # make check (health check suite)
│   ├── ops/                 # switchover / replica checks / cross-cluster DR
│   ├── pitr/                # PITR wizard + recovery monitor
│   ├── backup/ debug/ maintenance/ testing/
└── docs/                    # the documentation set (see index below)
```

## Documentation index

| Doc | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Components, data flow, failure modes, design decisions |
| [docs/runbooks.md](docs/runbooks.md) | Step-by-step ops runbooks (switchover, failover, backup, recovery, emergencies) |
| [docs/checks.md](docs/checks.md) | What `make check` validates + how to extend it |
| [docs/pitr.md](docs/pitr.md) | Point-in-time recovery guide |
| [docs/tools/perform_pitr.md](docs/tools/perform_pitr.md) | PITR script reference (options, transcripts) |
| [docs/switchover.md](docs/switchover.md) | Cross-cluster switchover runbook (manual fallback) |
| [docs/remote_standby.md](docs/remote_standby.md) | Building the remote standby cluster |
| [scripts/README.md](scripts/README.md) | Every script, its purpose, and its make target |

## FAQ

**Why 3 etcd nodes?** Quorum of 2 tolerates one failure — the smallest size that gives any fault tolerance. `ETCD_COUNT` is configurable but must stay odd.

**Can I change the node count later?** Yes — edit `PATRONI_REPLICAS` and `make up`; new nodes join as replicas. Shrinking deletes the removed nodes' data.

**Can I rename the cluster / change etcd size / change PG major version?** Only with `make destroy` and a fresh bootstrap — these are baked into the DCS state and data directories.

**Mac / Windows?** Developed on macOS; works anywhere Docker + Compose v2 runs. `remote-standby/` includes an Arch Linux guide for the DR side.

**Does a switchover drop connections?** HAProxy's `on-marked-down shutdown-sessions` forces clients to reconnect through the new leader — expect a blip, not data loss.

## Contributing

Issues and PRs are welcome. For code changes:

1. `make smoke-test` must pass (sandboxed, no Docker daemon needed).
2. Keep scripts `bash -n` clean and follow existing conventions in `scripts/`.
3. Docs changes: keep [docs/](docs/) consistent with behavior — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Wilmer Adalid
