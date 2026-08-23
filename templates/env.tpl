# ============================================================================
# 1. CLUSTER TOPOLOGY & IDENTITY
# ============================================================================
PATRONI_CLUSTER_NAME=patroni1
# Number of replica nodes; the leader is additional (total members = REPLICAS + 1)
PATRONI_REPLICAS=3
DEFAULT_DATABASE=maborak

# ============================================================================
# 1b. SOFTWARE VERSIONS
# ============================================================================
# Every value is validated against scripts/lib/versions.sh at config
# generation — unsupported versions abort with the list of allowed ones.
# Loose spellings are accepted and normalized: "3.7.1", "v3.7.1" and
# "1.25.2" (→ v1.25.2-p0) all work; canonical tags are written back to .env.
# Run 'make versions' to see what is configured vs supported.
#
# PostgreSQL major. Floor is 15 (the stack needs jsonlog). Changing this on an
# existing cluster requires 'make destroy' + fresh bootstrap: data directories
# are major-specific (/var/lib/postgresql/<major>/...).
POSTGRES_VERSION=18
# Exact Patroni release installed via pip in patroni/Dockerfile.
PATRONI_VERSION=4.1.5
# etcd image tag (quay.io/coreos/etcd). Changing it requires destroy +
# rebootstrap — the DCS membership state lives in the etcd volumes.
ETCD_VERSION=v3.7.1
# HAProxy docker branch tag (haproxy:<branch>). Config is compatible across 2.8–3.4.
HAPROXY_VERSION=3.4
# PgBouncer image tag (edoburu/pgbouncer). NOTE the v...-p0 tag format.
PGBOUNCER_VERSION=v1.25.2-p0
# pgBadger release installed from upstream in pgbadger/Dockerfile.
PGBADGER_VERSION=13.2

# Container engine driving the stack: docker (default) or podman.
# Both installed -> the setup wizard asks; set here to skip the prompt.
# podman-only hosts need a docker-compatible CLI (e.g. the podman-docker shim).
CONTAINER_ENGINE=docker

# ============================================================================
# 2. CREDENTIALS & AUTHENTICATION
# ============================================================================
POSTGRES_USER=postgres
POSTGRES_PASSWORD=CHANGE_ME_BEFORE_FIRST_USE
REPLICATOR_USER=replicator
REPLICATOR_PASSWORD=CHANGE_ME_BEFORE_FIRST_USE
HAPROXY_STATS_USER=admin
HAPROXY_STATS_PASSWORD=haproxy_stats_secret

# ============================================================================
# 3. HOST PORT MAPPINGS
# ============================================================================
# HAProxy
HAPROXY_WRITE_PORT=5551
HAPROXY_READ_PORT=5552
HAPROXY_STATS_PORT=5553

# PgBouncer
PGBOUNCER_PORT=6432
PGBOUNCER_RO_PORT=6433

# Barman Backup
BARMAN_PORT=54320

# etcd Consensus Cluster
# ETCD_COUNT must be odd for quorum. Changing it on an existing cluster
# requires 'make destroy' + fresh bootstrap (etcd membership lives in volumes).
ETCD_COUNT=3
__ETCD_PORT_ENTRIES__
# Comma-separated etcd endpoints injected into Patroni (auto-generated)
ETCD_HOSTS=etcd1:2379,etcd2:2379,etcd3:2379

# Patroni DCS Tuning (leader election timing / failover behavior)
PATRONI_TTL=30
PATRONI_LOOP_WAIT=10
PATRONI_RETRY_TIMEOUT=10
PATRONI_MAX_LAG_ON_FAILOVER=1048576
PATRONI_MASTER_START_TIMEOUT=300
PATRONI_BASEBACKUP_MAX_RATE=100M

# Patroni Base Node Ports
PATRONI_BASE_PORT=15431
PATRONI_API_BASE_PORT=8001
__DB_PORT_ENTRIES__

# ============================================================================
# 4. POSTGRESQL ENGINE & PERFORMANCE TUNING
# ============================================================================
PG_MAX_CONNECTIONS=200
PG_SHARED_BUFFERS=2GB
PG_EFFECTIVE_CACHE_SIZE=6GB
PG_WORK_MEM=16MB
PG_MAINTENANCE_WORK_MEM=512MB
PG_DEFAULT_STATISTICS_TARGET=100
PG_LOG_MIN_DURATION_STATEMENT=250ms
PG_LOG_STATEMENT=ddl

# ============================================================================
# 5. PGBOUNCER CONNECTION POOLING
# ============================================================================
PGBOUNCER_POOL_MODE=transaction
PGBOUNCER_DEFAULT_POOL_SIZE=50
PGBOUNCER_MAX_CLIENT_CONN=1000
PGBOUNCER_RESERVE_POOL_SIZE=10
PGBOUNCER_RESERVE_POOL_TIMEOUT=3

# ============================================================================
# 5b. PGBADGER LOG ANALYTICS (JSON logs, cron collection + web UI)
# ============================================================================
# Cron expression for log collection (default: every 30 minutes).
# Example schedules: '0 * * * *' hourly, '0 2 * * *' daily at 02:00,
# '*/15 * * * *' every 15 minutes.
PGBADGER_CRON_EXPRESSION=*/30 * * * *
# Web UI port for the generated reports
PGBADGER_PORT=8080
# Days of raw JSON logs to keep for re-parsing (0 = keep forever)
PGBADGER_RETENTION_DAYS=7
# Parallel parse jobs inside the pgbadger container
PGBADGER_JOBS=4
# Only collect log files untouched for at least N minutes (safety window
# so we never delete a file the logging collector still has open)
PGBADGER_SAFETY_MINUTES=10
# Timezone used by the cron scheduler (CRON_TZ) inside the container
PGBADGER_TZ=UTC

# ============================================================================
# 6. BARMAN BACKUP & RETENTION
# ============================================================================
BARMAN_RETENTION_POLICY="RECOVERY WINDOW OF 7 DAYS"
BARMAN_BANDWIDTH_LIMIT=50000
BARMAN_PARALLEL_JOBS=4


# ============================================================================
# 7. NETWORK CONFIGURATION
# ============================================================================
NETWORK_SUBNET=172.20.0.0/16

# ============================================================================
# 8. CROSS-CLUSTER / DISASTER RECOVERY (Optional Standby)
# ============================================================================
# Remote Patroni cluster (the standby/DR side) — replace with your own hosts.
REMOTE_SSH_HOST=192.0.2.20
REMOTE_SSH_USER=root
REMOTE_PATRONI_CONFIG=/etc/patroni/patroni1.yml
REMOTE_PATRONI_SERVICE=patroni1
REMOTE_PG_BIN=/usr/pgsql-15/bin
REMOTE_PG_PORT=5431
REMOTE_PG_SOCKET_DIR=/var/run/postgresql

# Remote HAProxy
REMOTE_HAPROXY_HOST=192.0.2.10
REMOTE_HAPROXY_WRITE_PORT=5511
REMOTE_HAPROXY_READ_PORT=5521

# Remote PgBouncer (only used for endpoint display; defaults to the HAProxy host)
REMOTE_PGBOUNCER_HOST=

# Local VPN address the remote side replicates from
MAC_VPN_HOST=198.51.100.5

# Replication slot names
STANDBY_REMOTE_SLOT_NAME=standby_remote
MAC_STANDBY_SLOT_NAME=mac_standby

# App roles to REVOKE CONNECT from during switchover
APP_ROLES=""
