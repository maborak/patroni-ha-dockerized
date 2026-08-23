# Operational Runbooks

DBA-style runbooks for common operational procedures on this stack: preconditions,
steps, verification, rollback, and red flags.

The canonical way to operate this stack is through the **make targets**
(see the [Make Target Reference](#make-target-reference), or run `make help`).
Raw `docker exec ... patronictl ...` commands appear only where no make target
exists. Where both are shown, prefer the make target — it handles leader
detection, confirmations, and safety checks for you.

---

## Conventions and Environment

The topology is **configurable** via `.env` — never assume a fixed node count or
hardcoded names:

| Variable | Default | Meaning |
|---|---|---|
| `PATRONI_REPLICAS` | `2` | Number of replicas. Members = replicas + leader, named `db1..dbN` |
| `PATRONI_CLUSTER_NAME` | `patroni1` | Patroni cluster name (also the etcd namespace) |
| `ETCD_COUNT` | `3` | etcd members `etcd1..etcdN` (client ports 2379, 22379, 32379, ...) |

Throughout this document, `db2..dbN` means "your replica nodes as configured by
`PATRONI_REPLICAS`", and `$PATRONI_CLUSTER_NAME` means your cluster name from `.env`.

**Useful facts:**

- PostgreSQL data directory inside each container:
  `/var/lib/postgresql/<PG_VERSION>/$PATRONI_CLUSTER_NAME/` (not `patroni{N}`).
- Patroni API: internal port `8001` per node; host ports from `PATRONI_API_BASE_PORT` (default 8001).
- PostgreSQL: internal port `5431`; host ports from `PATRONI_BASE_PORT` (default 15431).
- HAProxy: write `${HAPROXY_WRITE_PORT:-5551}`, read `${HAPROXY_READ_PORT:-5552}`,
  stats `${HAPROXY_STATS_PORT:-5553}`.
- etcd keys live under the namespace `/$PATRONI_CLUSTER_NAME/` — the leader lock
  is at `/$PATRONI_CLUSTER_NAME/leader`.

**Identify the current leader:** `make leader` (or
`docker exec db1 patronictl -c /etc/patroni/patroni.yml list`).

**Check a node's role (correct semantics):**

```bash
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# 't' on a streaming replica (it is continuously applying WAL)
# 'f' on the leader
```

> A replica returning `'t'` from `pg_is_in_recovery()` is **healthy and expected**.
> A replica returning `'f'` means it thinks it is a primary — investigate before
> doing anything else (possible split-brain).

---

## Runbook: Planned Switchover

**Goal**: gracefully transfer leadership from the current leader to a chosen
replica — e.g. for maintenance on the leader, load balancing, or failover rehearsal.

**Preconditions:**

- ✅ Cluster is healthy (`make check` passes)
- ✅ Target replica is caught up (lag < 1MB), no long-running transactions on the leader
- ✅ Application can tolerate a brief connection interruption (~5 seconds)

### Steps

**1. Identify the current leader:** `make leader`

**2. Verify the target replica is ready:**

```bash
# Must return 't' — a streaming replica is always in recovery
docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Check replication lag from the leader
docker exec db1 psql -U postgres -p 5431 -c \
  "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

**3. Perform the switchover:** `make switchover NEW_LEADER=db2`

The target refuses to run if `db2` is already the leader or no leader can be
detected. Under the hood it runs
`patronictl switchover --leader <current> --candidate db2 --force`
(the modern flag is `--leader`, not `--master`).

**4. Verify the switchover completed and routing follows the new leader:**

```bash
sleep 10
make status    # new leader should be db2
make check

# The write endpoint must land on the new leader
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT pg_is_in_recovery();"
# Must return 'f' — the write port always routes to the leader
```

### Rollback

If the switchover fails or you need to reverse it, switchover back:
`make switchover NEW_LEADER=db1`.

If the cluster is stuck mid-switch, restart Patroni on the affected nodes
(`docker exec db1 supervisorctl restart patroni`, same on `db2`), wait ~30
seconds, then re-check `make status`.

### Red Flags / Do Not Do This

❌ **Do not switchover during** large data loads, long-running transactions,
critical business operations, or backup operations.

❌ **Do not switchover if** the candidate has high lag (> 1MB), the cluster is
unstable, or `make check` reports no healthy replica.

❌ **Do not manually promote a replica** (`pg_ctl promote` or similar): manual
promotion bypasses Patroni coordination and can cause split-brain.

---

## Runbook: Failover Drill

**Goal**: test automatic failover by simulating a leader crash (test
environments only).

**Preconditions:**

- ✅ Cluster is healthy (`make check`)
- ✅ At least one replica is available and caught up
- ✅ Test environment (not production)

### Steps

**1. Identify the current leader:**

```bash
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $2}')
echo "Current leader: $LEADER"
```

**2. Simulate a leader crash:** `docker stop $LEADER`

**3. Monitor failover (~30-40 seconds), in another terminal:** `watch -n 2 make status`

**4. Verify the new leader and that writes work:**

```bash
make leader
make check
psql -h localhost -p 5551 -U postgres -d maborak -c "SELECT 1;"

# Verify no data loss if you seeded test data (via make psql):
#   SELECT COUNT(*) FROM your_test_table;

# Replication slots on the new leader
docker exec db2 psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

**5. Restart the old leader (it rejoins as a replica):** `docker start $LEADER`,
wait ~15 seconds, then `make status` — it should show as Replica / streaming.

**Alternative — controlled force failover.** Instead of crashing the container,
force Patroni to fail over (prompts for the word `FAILOVER`):
`make failover NEW_LEADER=db2`. Reserve `make failover` for emergencies; prefer
`make switchover` for planned moves.

### Rollback

If failover doesn't complete:

1. Check etcd health (adjust the range to your `ETCD_COUNT`):
   ```bash
   for i in 1 2 3; do docker exec etcd$i etcdctl endpoint health --endpoints="http://etcd$i:2379"; done
   ```
2. Restart the stopped leader: `docker start $LEADER`
3. Wait ~30 seconds and re-check `make status`.

### Red Flags / Do Not Do This

❌ **Do not run in production** without a maintenance window, application
coordination, and a verified backup.

❌ **Do not stop multiple nodes simultaneously** — you may lose quorum and
cluster availability.

❌ **Do not stop etcd members during failover** — coordination will fail and
split-brain becomes possible.

---

## Runbook: Backup Workflow

**Goal**: create a Backup base backup and verify it is usable.

**Preconditions:**

- ✅ Cluster is healthy (`make check`)
- ✅ Backup is reachable and SSH connectivity works (`make test-ssh`)
- ✅ Sufficient disk space on the Backup volume (`make disk`)

### Steps

**1. Create the backup** (leader is auto-detected): `make backup`,
or `make backup SERVER=db1` for a specific node. The target runs
`barman check` first (warns on issues), then `barman backup <server>`, then
lists the resulting backups.

**2. Verify WAL archiving is active:** `make check-archive`

**3. List and inspect backups:**

```bash
make list-backups                      # auto-detects the leader
make list-backups SERVER=db1           # explicit server
make show-backups SERVER=db1 BACKUP_ID=20260123T120000
```

**4. Verify Backup server health:** `docker exec backup barman check db1`

**5. Optional — logical dumps as a complement:**
`make dump-db DB=mydb NODE=db3` (logical `.tgz` dump from a healthy replica),
`make restore-db ARCHIVE=./backups/mydb-*.tgz TARGET=mydb`.

### Rollback / Troubleshooting

If the backup fails:

1. Check Backup logs: `docker logs backup --tail 50`
2. Check disk space: `make disk`
3. Check SSH connectivity (the usual culprit for WAL archiving failures):
   `make test-ssh` (equivalent direct script:
   `bash scripts/utils/test_ssh_to_backup.sh`)
4. Retry: `make backup`

### Red Flags / Do Not Do This

❌ **Do not delete old backups** without verifying newer backups exist, checking
the retention policy, and understanding your recovery requirements.

❌ **Avoid backing up during** peak write load or long-running transactions.

---

## Runbook: Point-in-Time Recovery (PITR)

**Goal**: recover the database to a specific point in time after accidental data
loss or corruption.

> This is a summary. The **canonical, comprehensive documentation** — including
> the interactive wizard walkthrough, remote PITR, and troubleshooting — lives in
> [docs/pitr.md](pitr.md) and [docs/tools/perform_pitr.md](tools/perform_pitr.md).

**Preconditions:**

- ✅ A base backup exists (`make list-backups`)
- ✅ WAL archiving was active at the target time and the WALs are still retained
- ✅ The target node can be taken offline for the restore

### Steps

**1. Run the interactive wizard (recommended):** `make pitr` — with no arguments
it walks you through choosing a backup, target time, server, and target node via
`scripts/pitr/perform_pitr.sh`.

**2. Or run it non-interactively:**

```bash
make pitr BACKUP_ID=20260123T120000 TARGET_TIME='2026-01-23 12:30:00' \
  SERVER=db1 TARGET=db2 RESTORE=1 AUTO_START=1 WAL_METHOD=backup-wal-restore
```

**3. Monitor recovery:** `make monitor-recovery NODE=db2`

**4. Verify recovery:** `docker exec db2 psql -U postgres -c "SELECT pg_is_in_recovery();"`
(returns `'t'` during recovery; `'f'` when the node is a primary again) and
`make status`.

### Rollback

`perform_pitr.sh` automatically backs up the existing data directory before
restoring (as `<data-dir>.backup_<timestamp>`). If recovery goes wrong, stop
Patroni on the target node, move the timestamped backup back over the data
directory, and restart. Details in [docs/pitr.md](pitr.md).

### Red Flags / Do Not Do This

❌ **Do not choose a target time before the base backup** — recovery will fail.

❌ **Do not ignore WAL gap warnings** — recovery stops at the first gap.

❌ **Do not PITR onto the running leader** without taking it over first — use a
dedicated target node.

---

## Runbook: Replica Rebuild

**Goal**: reinitialize a replica that has fallen behind or is corrupted.

**Preconditions:**

- ✅ Leader is healthy (`make leader`, `make check`)
- ✅ Target replica's data can be destroyed (reinit wipes it)
- ✅ Sufficient disk space and network capacity for a fresh base copy

### Steps

**1. Confirm the leader is healthy:** `make leader`, then
`docker exec db1 psql -U postgres -c "SELECT pg_is_in_recovery();"` — must
return `'f'` (the leader is never in recovery).

**2. Reinitialize the replica:** `make reinit NODE=db2` — you must type
`REINIT` to confirm; this destroys all data on `db2` and re-clones it from the
leader.

**3. Monitor progress** (takes ~5-10 minutes for large databases): `make status`

**4. Verify the replica is caught up:**

```bash
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
docker exec db1 psql -U postgres -p 5431 -c \
  "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

### Rollback

If reinit fails: check logs (`docker logs db2 --tail 50`), check disk
(`make disk`), retry (`make reinit NODE=db2`).

### Red Flags / Do Not Do This

❌ **Do not reinit during** high write load, backup operations, or other maintenance.

❌ **Do not reinit multiple replicas simultaneously** — it overloads the leader.

❌ **Do not reinit a healthy replica** just to fix lag; check slots and network first.

---

## Runbook: Scaling the Cluster

**Goal**: grow or shrink the number of PostgreSQL nodes with automated
health gating (`make scale`, powered by `scripts/ops/scale_cluster.sh`).

**Preconditions:**

- ✅ Stack is running and healthy (`make check`)
- ✅ For shrink: you accept permanent loss of the removed nodes' data,
  volumes, and Backup backups for those servers
- ✅ Sufficient disk space when growing (each new node clones the dataset)

### Grow (add replicas)

**1. Preview:** `make scale REPLICAS=5 DRY_RUN=1` — prints the plan without
touching anything.

**2. Apply:** `make scale REPLICAS=5` — regenerates configs, appends port
entries to `.env`, starts the new nodes, rebuilds the Backup image so its
backup loop covers them, then waits until every member reports
`running`/`streaming` (timeout `TIMEOUT=900` by default; new nodes clone the
leader via basebackup, which takes longer on large datasets).

**3. Verify:** `make status` shows N+1 members with exactly one leader;
`make check` is green.

### Shrink (remove replicas)

Shrink always removes the **highest-numbered** nodes (`db1..dbN` stay
contiguous). If the current leader is among them, the script performs a
planned switchover to a surviving replica first and aborts without deleting
anything if the promotion doesn't complete.

**1. Preview:** `make scale REPLICAS=2 DRY_RUN=1`

**2. Apply:** `make scale REPLICAS=2` — type `SCALE` to confirm (or `YES=1`
for unattended runs). After `compose up --remove-orphans` prunes the orphaned
containers, the script deletes their `_data`/`_logs` volumes and the matching
Backup server data.

**3. Verify:** `make status`; confirm HAProxy/PgBouncer still serve reads and
writes (`make psql`, `make psql-read`).

### Rollback

- **Grow**: `make scale REPLICAS=<old> YES=1` removes what was added.
- **Shrink**: deleted volumes are gone — restore from Backup backups of a
  surviving server by rejoining the node as a fresh replica
  (`PATRONI_REPLICAS=<old> make up`), or PITR if needed.

### Red Flags / Do Not Do This

❌ **Do not shrink during heavy write load or an in-progress PITR/backup.**

❌ **Do not edit `PATRONI_REPLICAS` in `.env` manually while the cluster runs** —
use `make scale`, which also cleans up ports, volumes, and Backup state.
(Manual edit + `make up` still works for grow, but skips volume/Backup hygiene.)

❌ **Do not shrink below 2 members** for anything beyond throwaway experiments —
a single-node cluster has no failover protection.

---

## Runbook: Cluster Health Check

**Goal**: comprehensive health verification of the entire stack.

**Preconditions:**

- ✅ Stack is running (`make ps`)

### Steps

**1. Run the automated health check:** `make check`

This runs `scripts/checks/check_stack.sh`, which validates (see [docs/checks.md](checks.md) for
the full list): containers, etcd health per member, Patroni API roles,
split-brain detection, replication lag, Backup status per server, PostgreSQL and
PgBouncer readiness, HAProxy config, SSH keys/connectivity, and exposed ports.

**2. Review cluster status and endpoints:** `make status`

**3. Detailed stack info and disk usage:** `make info` (or `make info FORMAT=json`),
`make disk` (or `make disk CLEANUP=all DRYRUN=1`).

**4. Spot-check replication manually** (on the leader: per-replica lag and state):

```bash
docker exec db1 psql -U postgres -p 5431 -c \
  "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

**5. Spot-check WAL archiving:** `make check-archive`

### Red Flags / Do Not Do This

❌ **Do not proceed with operations if** any container is not running, etcd is
unhealthy, replication lag is high, or WAL archiving shows failures.

❌ **Do not ignore SSH warnings** — SSH failures mean WAL archiving and backups
will fail next.

---

## Runbook: Troubleshooting Common Issues

### Issue: Replica Not Catching Up

**Symptoms**: replication lag increasing; replica shows `streaming` but falls behind.

**Diagnosis**:

```bash
# Lag as seen from the leader
docker exec db1 psql -U postgres -p 5431 -c \
  "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Replica-side WAL position
docker exec db2 psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Logs
docker logs db2 --tail 100
```

**Fix**: if lag persists and `pg_rewind` can't help, rebuild:
`make reinit NODE=db2` (type `REINIT` to confirm).

### Issue: WAL Archiving Failing

**Symptoms**: archive command errors in PostgreSQL logs; Backup reports failures
or missing WALs; `make check-archive` complains.

**Diagnosis**: `make check-archive`, `make test-ssh` (runs
`scripts/utils/test_ssh_to_backup.sh` and the reverse path),
`docker exec backup backup status db1`.

**Fix**: regenerate/verify SSH keys if needed (`make setup-keys`, then
`make generate` to regenerate configs including key distribution), then retry
with `make backup`.

### Issue: Cluster Split-Brain

**Symptoms**: more than one node claims to be leader; `make check` reports
"SPLIT-BRAIN DETECTED"; writes conflict or fail unexpectedly.

**Diagnosis**:

```bash
# Role as seen by each node (loop over your db1..dbN)
for node in db1 db2 db3; do
  echo "=== $node ==="
  docker exec $node patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -E "Leader|Replica" || echo "unreachable"
done

# Leader lock in etcd
docker exec etcd1 etcdctl get --prefix /$PATRONI_CLUSTER_NAME/leader
```

**Fix** (last resort — data on the losing side may be lost):

```bash
# 1. Stop all database nodes (replace db1 db2 db3 with your db1..dbN)
docker-compose stop db1 db2 db3

# 2. Clear the Patroni cluster state in etcd
docker exec etcd1 etcdctl del --prefix /$PATRONI_CLUSTER_NAME/

# 3. Start nodes one at a time; Patroni re-elects a leader
docker-compose start db1
sleep 10
docker-compose start db2 db3

# 4. Verify
make status
make check
```

### Issue: PgBouncer Problems

**Symptoms**: connection failures or auth errors on ports
`${PGBOUNCER_PORT:-6432}` (RW) / `${PGBOUNCER_RO_PORT:-6433}` (RO); "no more
connections" / pool exhaustion; `make check` shows "PgBouncer (RW/RO): Not ready".

**Diagnosis**:

```bash
make check                                             # authenticated query through both pools
docker logs pgbouncer --tail 50                        # PgBouncer logs
docker logs pgbouncer-ro --tail 50
docker exec -it pgbouncer psql -U postgres -d pgbouncer -c "SHOW POOLS;"   # pool stats
```

**Fix**:

- Auth failures: verify `POSTGRES_PASSWORD` in `.env` matches, then `make generate && make restart`.
- Pool exhaustion: raise pool size / connection limits in the PgBouncer config
  and `make restart`.
- Backend down: check that HAProxy and the leader are healthy (`make check`,
  `make leader`) — PgBouncer fronts HAProxy, so backend issues surface here first.

---

## Make Target Reference

Run `make help` for the always-current list. Most-used targets:

### Lifecycle

| Target | Description |
|---|---|
| `make wizard` | Guided setup: configure → review → confirm → build |
| `make up` | Start all containers (non-interactive) |
| `make down` / `make restart` / `make logs` / `make ps` | Stop / restart / follow logs / show status |
| `make build` | Rebuild all images (no cache) |
| `make generate` | Regenerate all configs from templates (uses `.env`) |
| `make setup-keys` | Ensure SSH keypair exists in `ssh_keys/` |
| `make destroy` | ⚠️ Destroy stack **and all data/volumes**. Type `DESTROY` to confirm; `YES=1` skips the prompt; `PRUNE=1` also prunes Docker system-wide |

### Health & Monitoring

| Target | Description |
|---|---|
| `make check` | Full health check (`scripts/checks/check_stack.sh`) |
| `make status` | Cluster status + all access endpoints + recent backups |
| `make info` | Detailed stack info (`FORMAT=json` optional) |
| `make leader` | Show current leader node |
| `make disk` | Disk usage (`CLEANUP=logs\|dumps\|docker\|snapshots\|temp\|backup\|all`, `KEEP_DAYS=N`, `DRYRUN=1`) |
| `make smoke-test` | Sandboxed end-to-end tests of the tooling (no Docker needed) |

### Backup & Recovery

| Target | Description |
|---|---|
| `make backup` | Backup base backup (`SERVER=dbN` optional; auto-detects leader) |
| `make list-backups` | List backups (auto-detects leader, or `SERVER=dbN`) |
| `make show-backups` | Backup details: `SERVER=dbN BACKUP_ID=<id>` |
| `make check-archive` | WAL archiving status on the leader |
| `make dump-db` / `make restore-db` | Logical `.tgz` dump / restore of a single database |
| `make import-db` | Import an external PostgreSQL DB (`DSN=postgresql://user:pass@host:port/db`), wizard when no DSN given |
| `make pitr` | PITR wizard (no args = interactive; or `BACKUP_ID= TARGET_TIME='...' SERVER= TARGET= RESTORE=1 AUTO_START=1 WAL_METHOD=`) |
| `make monitor-recovery` | Monitor recovery progress (`NODE=dbN`) |

### Database Access & Diagnostics

| Target | Description |
|---|---|
| `make psql` / `make psql-read` | Connect via HAProxy write / read endpoint |
| `make psql-node` | Connect directly to a node (`NODE=dbN`) |
| `make shell` | Shell into a container (`NODE=dbN`) |
| `make list-dbs` | List databases (`NODE=`, `FORMAT=json`, `TEMPLATES=1`) |
| `make stats` | Database statistics (`NODE=dbN`, auto-detects leader) |
| `make activity` | Live activity monitor (`NODE=dbN`) |
| `make slow-queries` | Top queries from pg_stat_statements (`NODE=dbN LIMIT=10`) |
| `make vacuum` / `make analyze` | VACUUM ANALYZE / ANALYZE (`NODE=dbN` or `ALL=1`, `TYPE=analyze\|vacuum\|full`) |
| `make pgbadger` | pgBadger report (`NODE=dbN`, auto-detects leader) |

### Cluster Operations

| Target | Description |
|---|---|
| `make switchover` | Planned switchover (`NEW_LEADER=db2`) |
| `make reinit` | Reinitialize a replica (`NODE=db2`; type `REINIT` to confirm) |
| `make failover` | **Emergency** force failover (`NEW_LEADER=db2`; type `FAILOVER` to confirm) |
| `make switchover-to-remote` / `make switchover-from-remote` | Cross-cluster switchover (`YES=1 DRY_RUN=1 SKIP_BACKUP=1`; see [docs/switchover.md](switchover.md)) |
| `make test-ssh` / `make test-connectivity` | SSH / PostgreSQL connectivity tests to Backup |
| `make config` | Show current configuration (ports, `.env`) |

---

## Emergency Procedures

### Destroy / Reset the Stack

`make destroy` removes **all** containers, volumes (PostgreSQL data, etcd state,
Backup backups and WAL archives). There is no undo.

- Interactive safety: you must type `DESTROY` to confirm.
- `make destroy YES=1` skips the confirmation prompt (for scripting).
- `make destroy PRUNE=1` additionally runs `docker system prune`.
- **Take an external backup first** (`make backup`, then copy it off-host) if you
  need any of the data.

### Complete Cluster Failure

**Scenario**: all nodes down, etcd down, cluster state possibly corrupted.

1. **Assess damage:** `make ps`, `docker logs db1 --tail 50`

2. **Restart etcd** (adjust for your `ETCD_COUNT`; etcd must reach quorum):
   ```bash
   docker-compose start etcd1 etcd2 etcd3
   sleep 5
   for i in 1 2 3; do docker exec etcd$i etcdctl endpoint health --endpoints="http://etcd$i:2379"; done
   ```

3. **If cluster state is corrupted, clear it** (see also the split-brain runbook):
   `docker exec etcd1 etcdctl del --prefix /$PATRONI_CLUSTER_NAME/`

4. **Start nodes one by one** (replace with your db1..dbN): `docker-compose start db1`,
   wait ~10 seconds, `make status`, then `docker-compose start db2 db3`, wait
   ~15 seconds, `make status` again.

5. **If data is corrupted, restore from backup:** `make pitr` (interactive
   wizard; see docs/pitr.md).

---

## Maintenance Windows

### Planned Maintenance Checklist

**Before maintenance:**

- [ ] Create a backup: `make backup`
- [ ] Verify the backup: `docker exec backup barman check db1` and `make list-backups`
- [ ] Verify cluster health: `make check`
- [ ] Document current cluster state: `make status` (save the output)
- [ ] Notify stakeholders and schedule the window

**During maintenance:**

- [ ] Switchover if the leader needs work: `make switchover NEW_LEADER=db2`
- [ ] Execute maintenance tasks
- [ ] Re-run `make check` after each step

**After maintenance:**

- [ ] Full health check: `make check`
- [ ] Verify replication is caught up (no lag warnings)
- [ ] Test application connectivity (write + read endpoints)
- [ ] Document changes

---

## References

- **Patroni REST API**: https://patroni.readthedocs.io/en/latest/rest_api.html
- **PostgreSQL High Availability**: https://www.postgresql.org/docs/current/high-availability.html
- **Backup Operations**: https://www.pgbarman.org/documentation/
- **PITR (canonical)**: [docs/pitr.md](pitr.md)
- **Health checks (canonical)**: [docs/checks.md](checks.md)
- **Cross-cluster switchover**: [docs/switchover.md](switchover.md)
