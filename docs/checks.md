# Health Checks

How to verify the stack is healthy, what the automated check actually validates,
and what's still on the wish list.

---

## `make check` (check_stack.sh)

`make check` runs [`check_stack.sh`](../check_stack.sh), which prints a
✓ / ✗ / ⚠ report. It is topology-aware: node and etcd lists are derived from
`PATRONI_REPLICAS` and `ETCD_COUNT` in `.env` (via `scripts/lib/common.sh`), so it
works for any cluster size.

### What it validates

| Area | What is checked |
|---|---|
| Stack up | At least one compose container running |
| Containers | Running state of `etcd1..etcdN`, each `db1..dbN`, `haproxy`, `barman`, `pgbouncer`, `pgbouncer-ro` |
| etcd health | `etcdctl endpoint health` against every etcd member (loop over `ETCD_COUNT`) |
| Patroni API | REST API responds on each node and reports a sane role (`Leader` / `Replica`) |
| Split-brain | Exactly one node reports the primary role via the Patroni API; 0 or >1 raises CRITICAL |
| Replication lag | On the leader, `pg_stat_replication` per-stream `sent_lsn` vs `replay_lsn`; lag > 1MB is flagged |
| Barman | `barman check <server> --nagios` per database node — OK / WARNING / CRITICAL |
| PostgreSQL | `pg_isready` on every node (internal port 5431) |
| PgBouncer | Authenticated `SELECT 1` through both the RW (6432) and RO (6433) pools |
| HAProxy | Config syntax validation (`haproxy -c`) |
| SSH keys | Key files exist with 600 perms and `.ssh` dirs with 700, for `postgres` and `barman` users, including the PITR-expected key locations |
| SSH connectivity | DB → Barman, Barman → DB, and DB ↔ DB, as both `postgres`/`barman` and `root` users |
| Exposed ports | From the host: etcd client ports (2379/22379/32379…), per-node PG + Patroni API ports, HAProxy write/read/stats, PgBouncer RW/RO |
| Cluster status | `patronictl list` output plus a summary of connection endpoints |

SSH failures matter most in practice: they mean WAL archiving, backups, and PITR
will fail next.

### When to run it

- After `make up` / `make wizard`, before declaring the stack ready.
- Before any operational procedure (switchover, reinit, backup, maintenance) —
  most runbooks in [docs/runbooks.md](runbooks.md) list `make check` as a
  precondition.
- After any failover, restart, or config regeneration (`make generate`).
- On a schedule (e.g. cron / monitoring) as a poor-man's synthetic check: any
  `✗` or `CRITICAL` line is actionable output to alert on.

### Interpreting the output

- `✗` (red) marks a failed check — investigate before doing anything else.
- `⚠` (yellow) marks a warning (e.g. Barman `--nagios` WARNING state, a missing
  optional SSH key) — usually tolerable, never ignore it in a pre-maintenance run.
- Port checks from the host are informational: a closed port can be normal while
  containers are still starting, so re-run once the stack settles.

---

## Related Commands

| Command | What it gives you |
|---|---|
| `make status` | Patroni cluster status, etcd health, all connection endpoints, latest backups |
| `make info` | Detailed stack info from `scripts/debug/get_stack_info.sh` (`FORMAT=json` for machine-readable) |
| `make leader` | Current leader node only |
| `make disk` | Disk usage report; cleanup modes via `CLEANUP=logs\|dumps\|docker\|snapshots\|temp\|barman\|all` with `DRYRUN=1` |
| `make check-archive` | WAL archiving status on the leader |
| `make test-ssh` | SSH connectivity matrix (all nodes ↔ Barman) via `scripts/utils/` |
| `make test-connectivity` | PostgreSQL connectivity from Barman to the nodes |
| `make smoke-test` | Sandboxed end-to-end tests of the setup wizard and PITR wizard tooling itself (no Docker needed) |

**HAProxy stats page**: open `http://localhost:${HAPROXY_STATS_PORT:-5553}/stats`
in a browser. It is protected by HTTP basic auth using `HAPROXY_STATS_USER` /
`HAPROXY_STATS_PASSWORD` from `.env`. The page shows per-backend UP/DOWN state —
useful for seeing failovers as they happen.

---

## Known Gaps / Ideas

These are the genuinely-open items — things `make check` does **not** yet cover:

**End-to-end read/write validation.** The check confirms ports respond and
PgBouncer authenticates, but never performs an actual write through HAProxy and
reads it back through the read endpoint. A small round-trip test would catch
routing misconfigurations that currently only surface in applications.
`make smoke-test` covers the tooling, not the running cluster.

**Failover readiness precheck.** Lag is reported per stream, but there is no
single verdict like "at least one replica is within
`maximum_lag_on_failover` and would accept promotion" before planned
maintenance. `detect_healthy_replica()` in `scripts/lib/common.sh` already
encapsulates the right signal — it is just not part of the report.

**Backup-age alerting.** `barman check --nagios` verifies archiving health, but
nothing warns when the newest base backup is older than a threshold (e.g. 24h).
A stale-but-healthy archive gives a false sense of recoverability.

**WAL-gap detection.** No continuous verification that archived WAL segments form
an unbroken sequence on the Barman side. Gaps silently limit how far back (or
forward) PITR can reach.

**Time-sync check.** Container clocks are assumed to agree with the host and each
other. Significant drift breaks PITR target-time reasoning and muddies log
correlation across nodes.

**PostgreSQL config drift.** Nothing compares effective settings (`wal_level`,
`archive_mode`, `max_connections`, …) across nodes, so a hand-edited node can
drift from the template-generated baseline unnoticed.

---

## Extending check_stack.sh

- The script sources [`scripts/lib/common.sh`](../scripts/lib/common.sh), which
  provides the building blocks for new checks:
  `get_db_nodes`, `get_db_port` / `get_api_port`, `get_patroni_data_dir`,
  `validate_node`, `detect_leader`, `detect_leader_api`, and
  `detect_healthy_replica`. Use these instead of hardcoding node lists.
- Respect `.env` configuration (`PATRONI_REPLICAS`, `ETCD_COUNT`,
  `PATRONI_CLUSTER_NAME`) so checks work at any topology.
- Follow the existing output convention (`GREEN ✓` / `RED ✗` / `YELLOW ⚠` with
  the color variables from `common.sh`).
- Before shipping changes, run `make smoke-test` — it exercises the wizard and
  PITR scripts in a sandbox and catches shell-level regressions in the tooling.
