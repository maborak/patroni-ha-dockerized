#!/bin/bash
set -euo pipefail
# Generate all config files from templates based on .env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
TEMPLATE_DIR="$PROJECT_ROOT/templates"

# Supported-version registry + validators (single source of truth)
source "$SCRIPT_DIR/lib/versions.sh"

# Ensure SSH keys are present
bash "$SCRIPT_DIR/utils/setup_ssh_keys.sh"

# Generated-artifact dirs must exist on pristine clones (they are gitignored)
mkdir -p "$PROJECT_ROOT/configs"

# Save any overrides passed via environment before sourcing .env
_OVERRIDE_REPLICAS="${PATRONI_REPLICAS:-}"

# Source .env for defaults
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a; source "$PROJECT_ROOT/.env"; set +a
fi

# Command-line override takes precedence over .env
if [ -n "$_OVERRIDE_REPLICAS" ]; then
    PATRONI_REPLICAS="$_OVERRIDE_REPLICAS"
fi

PATRONI_REPLICAS=${PATRONI_REPLICAS:-2}
# Total cluster members = replicas + 1 leader (Patroni elects the leader from members)
PATRONI_NODES=$((PATRONI_REPLICAS + 1))
# etcd cluster size (odd number required for quorum; changes need destroy + fresh bootstrap)
ETCD_COUNT=${ETCD_COUNT:-3}
POSTGRES_USER=${POSTGRES_USER:-postgres}
DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}
PATRONI_BASE_PORT=${PATRONI_BASE_PORT:-15431}
PATRONI_API_BASE_PORT=${PATRONI_API_BASE_PORT:-8001}
HAPROXY_STATS_USER=${HAPROXY_STATS_USER:-admin}
HAPROXY_STATS_PASSWORD=${HAPROXY_STATS_PASSWORD:-haproxy_stats_secret}
BARMAN_RETENTION_POLICY=${BARMAN_RETENTION_POLICY:-RECOVERY WINDOW OF 7 DAYS}
BARMAN_BANDWIDTH_LIMIT=${BARMAN_BANDWIDTH_LIMIT:-50000}
BARMAN_PARALLEL_JOBS=${BARMAN_PARALLEL_JOBS:-4}

# ----------------------------------------------------------------------------
# Software versions — step 1: ensure the *_VERSION keys exist in .env.
# Defaults come from the registry, EXCEPT for the two bootstrap-bound versions
# (PostgreSQL, etcd): on an existing stack those must match the deployed data
# — silently bumping them would break the cluster on the next 'make up'.
# ----------------------------------------------------------------------------
if [ -f "$PROJECT_ROOT/.env" ]; then
    # Detect what is actually deployed (empty on fresh hosts)
    DEPLOYED_PG=""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^db1$'; then
        DEPLOYED_PG=$(docker exec db1 sh -c 'ls /var/lib/postgresql/ 2>/dev/null | grep -E "^[0-9]+$" | sort -n | tail -1' 2>/dev/null || true)
    fi
    DEPLOYED_ETCD=""
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^etcd1$'; then
        # capture fully first: piping into head/awk-exit can SIGPIPE the
        # producer and kill the script under `set -o pipefail`
        _etcd_version_output=$(docker exec etcd1 etcd --version 2>/dev/null || true)
        DEPLOYED_ETCD=$(printf '%s' "$_etcd_version_output" | awk '/etcd Version/{print $3; exit}')
        [ -n "$DEPLOYED_ETCD" ] && DEPLOYED_ETCD="v${DEPLOYED_ETCD#v}"
    fi

    for comp in POSTGRES PATRONI ETCD HAPROXY PGBOUNCER PGBADGER; do
        key="${comp}_VERSION"
        if ! grep -qE "^${key}=" "$PROJECT_ROOT/.env"; then
            val="$(default_version "$comp")"
            case "$comp" in
                POSTGRES) [ -n "$DEPLOYED_PG" ] && val="$DEPLOYED_PG" ;;
                ETCD)     [ -n "$DEPLOYED_ETCD" ] && val="$DEPLOYED_ETCD" ;;
            esac
            {
                echo ""
                echo "# Software versions (validated against scripts/lib/versions.sh)"
                echo "${key}=${val}"
            } >> "$PROJECT_ROOT/.env"
            echo "Added missing ${key}=${val} to .env"
        fi
    done

    # Re-source .env so values just written are visible below (set -a exports),
    # preserving any command-line overrides (e.g. PATRONI_REPLICAS from scale).
    _OVR="${PATRONI_REPLICAS:-}"
    set -a; source "$PROJECT_ROOT/.env"; set +a
    [ -n "$_OVR" ] && PATRONI_REPLICAS="$_OVR"
fi

# ----------------------------------------------------------------------------
# Software versions — step 2: validate against the supported registry.
# Unsupported values (even valid upstream tags) abort config generation.
# ----------------------------------------------------------------------------
validate_version_or_die POSTGRES   "${POSTGRES_VERSION:-}"
validate_version_or_die PATRONI    "${PATRONI_VERSION:-}"
validate_version_or_die ETCD       "${ETCD_VERSION:-}"
validate_version_or_die HAPROXY    "${HAPROXY_VERSION:-}"
validate_version_or_die PGBOUNCER  "${PGBOUNCER_VERSION:-}"
validate_version_or_die PGBADGER   "${PGBADGER_VERSION:-}"

# Normalize any loose spellings in .env ("3.7.1", "1.25.2") to the canonical
# registry tags ("v3.7.1", "v1.25.2-p0") so file, compose and runtime agree.
if [ -f "$PROJECT_ROOT/.env" ]; then
    for comp in POSTGRES PATRONI ETCD HAPROXY PGBOUNCER PGBADGER; do
        key="${comp}_VERSION"
        raw=$(grep -E "^${key}=" "$PROJECT_ROOT/.env" | tail -1 | cut -d= -f2-)
        canon=$(printenv "$key")
        if [ -n "$raw" ] && [ "$raw" != "$canon" ]; then
            sed -i.bak -E "s|^${key}=.*|${key}=${canon}|" "$PROJECT_ROOT/.env" \
                && rm -f "$PROJECT_ROOT/.env.bak"
            echo "Normalized ${key}: ${raw} -> ${canon}"
        fi
    done
fi

# Warn when the configured PG major differs from the data on existing volumes
# (PostgreSQL cannot start a data directory created by a different major).
if [ -n "$DEPLOYED_PG" ] && [ "$DEPLOYED_PG" != "$POSTGRES_VERSION" ]; then
    echo ""
    echo "  ⚠️  WARNING: data volumes hold PostgreSQL $DEPLOYED_PG but POSTGRES_VERSION=$POSTGRES_VERSION is configured."
    echo "     A different major version requires 'make destroy' + fresh bootstrap (ALL DATA LOST),"
    echo "     or revert POSTGRES_VERSION to $DEPLOYED_PG to keep using the current volumes."
    echo ""
fi

# Resolved image references (written literally into the generated compose file)
ETCD_IMAGE="quay.io/coreos/etcd:${ETCD_VERSION}"
HAPROXY_IMAGE="haproxy:${HAPROXY_VERSION}"
PGBOUNCER_IMAGE="edoburu/pgbouncer:${PGBOUNCER_VERSION}"

if [ "$PATRONI_REPLICAS" -lt 1 ]; then
    echo "ERROR: PATRONI_REPLICAS must be >= 1 (got $PATRONI_REPLICAS)"
    exit 1
fi
if [ "$((ETCD_COUNT % 2))" -eq 0 ]; then
    echo "WARNING: ETCD_COUNT=$ETCD_COUNT is even — quorum prefers an odd number (3, 5, ...)"
fi

# etcd host list for Patroni (in-network, fixed internal port)
ETCD_HOSTS=""
for i in $(seq 1 $ETCD_COUNT); do
    if [ -n "$ETCD_HOSTS" ]; then ETCD_HOSTS="${ETCD_HOSTS},"; fi
    ETCD_HOSTS="${ETCD_HOSTS}etcd${i}:2379"
done

echo "Generating configs for $PATRONI_NODES Patroni nodes ($PATRONI_REPLICAS replicas + 1 leader)..."

# Build node list
NODES=""
for i in $(seq 1 $PATRONI_NODES); do
    NODES="${NODES}db${i} "
done

# --- Patroni config ---
# templates/patroni.yml.tpl is mounted directly into containers.
# patroni/entrypoint.sh substitutes node name, passwords, and performance variables at container runtime.

# --- Generate haproxy.cfg ---
WRITE_SERVERS=""
READ_SERVERS=""
for i in $(seq 1 $PATRONI_NODES); do
    WRITE_LINE="    server db${i} db${i}:5431 check port 8001 inter 2000 fall 3 rise 2 on-marked-down shutdown-sessions"
    READ_LINE="    server db${i} db${i}:5431 check port 8001 inter 2000 fall 3 rise 2"
    if [ -n "$WRITE_SERVERS" ]; then
        WRITE_SERVERS="${WRITE_SERVERS}
${WRITE_LINE}"
        READ_SERVERS="${READ_SERVERS}
${READ_LINE}"
    else
        WRITE_SERVERS="${WRITE_LINE}"
        READ_SERVERS="${READ_LINE}"
    fi
done

python3 << PYEOF
with open('${TEMPLATE_DIR}/haproxy.cfg.tpl', 'r') as f:
    content = f.read()
content = content.replace('__WRITE_SERVERS__', """${WRITE_SERVERS}""")
content = content.replace('__READ_SERVERS__', """${READ_SERVERS}""")
content = content.replace('__HAPROXY_STATS_USER__', """${HAPROXY_STATS_USER}""")
content = content.replace('__HAPROXY_STATS_PASSWORD__', """${HAPROXY_STATS_PASSWORD}""")
with open('${PROJECT_ROOT}/configs/haproxy.cfg', 'w') as f:
    f.write(content)
PYEOF
# --- Generate barman.conf ---
DB_SECTIONS=""
for i in $(seq 1 $PATRONI_NODES); do
    SECTION="###########################################
# db${i}
###########################################
[db${i}]
archiver = on
description = \"SSH db${i}\"
recovery_options = 'get-wal'
conninfo = host=db${i} user=${POSTGRES_USER} dbname=postgres port=5431
ssh_command = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes postgres@db${i}"
    if [ -n "$DB_SECTIONS" ]; then
        DB_SECTIONS="${DB_SECTIONS}

${SECTION}"
    else
        DB_SECTIONS="${SECTION}"
    fi
done

python3 << PYEOF
with open('${TEMPLATE_DIR}/barman.conf.tpl', 'r') as f:
    content = f.read()
content = content.replace('__DB_SECTIONS__', """${DB_SECTIONS}""")
content = content.replace('__BARMAN_RETENTION_POLICY__', """${BARMAN_RETENTION_POLICY}""")
content = content.replace('__BARMAN_BANDWIDTH_LIMIT__', """${BARMAN_BANDWIDTH_LIMIT}""")
content = content.replace('__BARMAN_PARALLEL_JOBS__', """${BARMAN_PARALLEL_JOBS}""")
with open('${PROJECT_ROOT}/configs/barman.conf', 'w') as f:
    f.write(content)
PYEOF

# --- Generate barman/supervisord.conf ---
BACKUP_SERVERS=$(echo $NODES | xargs)  # trim whitespace
sed "s/__BACKUP_SERVERS__/${BACKUP_SERVERS}/" \
    "$TEMPLATE_DIR/barman-supervisord.conf.tpl" > "$PROJECT_ROOT/barman/supervisord.conf"

# --- Generate pgbouncer configs ---
PGBOUNCER_POOL_MODE=${PGBOUNCER_POOL_MODE:-transaction}
PGBOUNCER_MAX_CLIENT_CONN=${PGBOUNCER_MAX_CLIENT_CONN:-1000}
PGBOUNCER_DEFAULT_POOL_SIZE=${PGBOUNCER_DEFAULT_POOL_SIZE:-50}
PGBOUNCER_RESERVE_POOL_SIZE=${PGBOUNCER_RESERVE_POOL_SIZE:-10}
PGBOUNCER_RESERVE_POOL_TIMEOUT=${PGBOUNCER_RESERVE_POOL_TIMEOUT:-3}

for INI in pgbouncer.ini pgbouncer-ro.ini; do
python3 << PYEOF2
with open('${TEMPLATE_DIR}/${INI}.tpl', 'r') as f:
    content = f.read()
for k, v in {
    '__DEFAULT_DATABASE__': '${DEFAULT_DATABASE}',
    '__POSTGRES_USER__': '${POSTGRES_USER}',
    '__PGBOUNCER_POOL_MODE__': '${PGBOUNCER_POOL_MODE}',
    '__PGBOUNCER_MAX_CLIENT_CONN__': '${PGBOUNCER_MAX_CLIENT_CONN}',
    '__PGBOUNCER_DEFAULT_POOL_SIZE__': '${PGBOUNCER_DEFAULT_POOL_SIZE}',
    '__PGBOUNCER_RESERVE_POOL_SIZE__': '${PGBOUNCER_RESERVE_POOL_SIZE}',
    '__PGBOUNCER_RESERVE_POOL_TIMEOUT__': '${PGBOUNCER_RESERVE_POOL_TIMEOUT}',
}.items():
    content = content.replace(k, str(v))
with open('${PROJECT_ROOT}/configs/${INI}', 'w') as f:
    f.write(content)
PYEOF2
done

# --- Generate etcd services ---
ETCD_INITIAL_CLUSTER=""
for i in $(seq 1 $ETCD_COUNT); do
    if [ -n "$ETCD_INITIAL_CLUSTER" ]; then ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER},"; fi
    ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER}etcd${i}=http://etcd${i}:2380"
done

ETCD_SERVICES=""
ETCD_VOLUMES=""
ETCD_DEPENDS=""
for i in $(seq 1 $ETCD_COUNT); do
    CLIENT=$(( i == 1 ? 2379 : i * 10000 + 2379 ))
    PEER=$(( i == 1 ? 2380 : i * 10000 + 2380 ))
    BLOCK="  # etcd cluster node ${i}/${ETCD_COUNT}
  etcd${i}:
    image: ${ETCD_IMAGE}
    container_name: etcd${i}
    hostname: etcd${i}
    ports:
      - \"\${ETCD${i}_CLIENT_PORT:-${CLIENT}}:2379\"
      - \"\${ETCD${i}_PEER_PORT:-${PEER}}:2380\"
    volumes:
      - etcd${i}_data:/etcd-data
    networks:
      - patroni_network
    command: >
      etcd
      --name=etcd${i}
      --data-dir=/etcd-data
      --listen-client-urls=http://0.0.0.0:2379
      --advertise-client-urls=http://etcd${i}:2379
      --listen-peer-urls=http://0.0.0.0:2380
      --initial-advertise-peer-urls=http://etcd${i}:2380
      --initial-cluster=${ETCD_INITIAL_CLUSTER}
      --initial-cluster-state=new
      --initial-cluster-token=etcd-cluster-1
    healthcheck:
      test: [\"CMD\", \"etcdctl\", \"endpoint\", \"health\", \"--endpoints=http://localhost:2379\"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    restart: unless-stopped"
    if [ -n "$ETCD_SERVICES" ]; then
        ETCD_SERVICES="${ETCD_SERVICES}

${BLOCK}"
    else
        ETCD_SERVICES="${BLOCK}"
    fi
    DEP="      etcd${i}:
        condition: service_healthy"
    if [ -n "$ETCD_DEPENDS" ]; then ETCD_DEPENDS="${ETCD_DEPENDS}
${DEP}"; else ETCD_DEPENDS="$DEP"; fi
    VOL="  etcd${i}_data:"
    if [ -n "$ETCD_VOLUMES" ]; then ETCD_VOLUMES="${ETCD_VOLUMES}
${VOL}"; else ETCD_VOLUMES="$VOL"; fi
done

# --- Generate docker-compose.yml ---
# Build DB service blocks
DB_SERVICES=""
for i in $(seq 1 $PATRONI_NODES); do
    port_var="PATRONI_DB${i}_PORT"
    api_var="PATRONI_DB${i}_API_PORT"
    BLOCK="  db${i}:
    <<: *patroni_base
    container_name: db${i}
    hostname: db${i}
    ports:
      - \"\${${port_var}}:5431\"
      - \"\${${api_var}}:8001\"
    volumes:
      - db${i}_data:/var/lib/postgresql
      - db${i}_logs:/var/log/postgresql
      - ./templates/patroni.yml.tpl:/etc/patroni/patroni.yml.tpl:ro
      - ./scripts:/etc/patroni/scripts:ro
      - ./ssh_keys/barman_rsa:/ssh_keys/barman_rsa:ro
      - ./ssh_keys/barman_rsa.pub:/ssh_keys/barman_rsa.pub:ro"
    if [ -n "$DB_SERVICES" ]; then
        DB_SERVICES="${DB_SERVICES}

${BLOCK}"
    else
        DB_SERVICES="$BLOCK"
    fi
done

# Build depends_on healthy blocks
DB_DEPENDS_ON=""
for i in $(seq 1 $PATRONI_NODES); do
    ENTRY="      db${i}:
        condition: service_healthy"
    if [ -n "$DB_DEPENDS_ON" ]; then
        DB_DEPENDS_ON="${DB_DEPENDS_ON}
${ENTRY}"
    else
        DB_DEPENDS_ON="${ENTRY}"
    fi
done

# Build volume declarations (data + per-node log volumes shared with pgbadger)
DB_VOLUMES=""
PGBADGER_LOG_VOLUMES=""
for i in $(seq 1 $PATRONI_NODES); do
    ENTRY="  db${i}_data:"
    LOG_VOL_ENTRY="      - db${i}_logs:/logs/db${i}"
    if [ -n "$DB_VOLUMES" ]; then
        DB_VOLUMES="${DB_VOLUMES}
  db${i}_logs:
${ENTRY}"
        PGBADGER_LOG_VOLUMES="${PGBADGER_LOG_VOLUMES}
${LOG_VOL_ENTRY}"
    else
        DB_VOLUMES="${ENTRY}
  db${i}_logs:"
        PGBADGER_LOG_VOLUMES="$LOG_VOL_ENTRY"
    fi
done

# Write intermediate files for python to read (avoids shell quoting issues)
printf '%s' "$DB_SERVICES" > /tmp/_gen_db_services.txt
printf '%s' "$DB_DEPENDS_ON" > /tmp/_gen_db_depends.txt
printf '%s' "$DB_VOLUMES" > /tmp/_gen_db_volumes.txt
printf '%s' "$PGBADGER_LOG_VOLUMES" > /tmp/_gen_pgbadger_vols.txt
printf '%s' "$ETCD_SERVICES" > /tmp/_gen_etcd_services.txt
printf '%s' "$ETCD_DEPENDS" > /tmp/_gen_etcd_depends.txt
printf '%s' "$ETCD_VOLUMES" > /tmp/_gen_etcd_volumes.txt

python3 << PYEOF
with open('${TEMPLATE_DIR}/docker-compose.yml.tpl', 'r') as f:
    content = f.read()
with open('/tmp/_gen_db_services.txt', 'r') as f:
    db_services = f.read()
with open('/tmp/_gen_db_depends.txt', 'r') as f:
    db_depends = f.read()
with open('/tmp/_gen_db_volumes.txt', 'r') as f:
    db_volumes = f.read()
with open('/tmp/_gen_pgbadger_vols.txt', 'r') as f:
    pgbadger_vols = f.read()
with open('/tmp/_gen_etcd_services.txt', 'r') as f:
    etcd_services = f.read()
with open('/tmp/_gen_etcd_depends.txt', 'r') as f:
    etcd_depends = f.read()
with open('/tmp/_gen_etcd_volumes.txt', 'r') as f:
    etcd_volumes = f.read()
content = content.replace('__ETCD_SERVICES__', etcd_services)
content = content.replace('__ETCD_DEPENDS__', etcd_depends)
content = content.replace('__ETCD_VOLUMES__', etcd_volumes)
content = content.replace('__DB_SERVICES__', db_services)
content = content.replace('__DB_DEPENDS_ON_HEALTHY__', db_depends)
content = content.replace('__DB_VOLUMES__', db_volumes)
content = content.replace('__PGBADGER_LOG_VOLUMES__', pgbadger_vols)
content = content.replace('__HAPROXY_IMAGE__', """${HAPROXY_IMAGE}""")
content = content.replace('__PGBOUNCER_IMAGE__', """${PGBOUNCER_IMAGE}""")
content = content.replace('__BA_POSTGRES_VERSION__', """${POSTGRES_VERSION}""")
content = content.replace('__BA_PATRONI_VERSION__', """${PATRONI_VERSION}""")
content = content.replace('__BA_ALPINE_VERSION__', """${ALPINE_VERSION:-3.22}""")
content = content.replace('__BA_PGBADGER_VERSION__', """${PGBADGER_VERSION}""")
with open('${PROJECT_ROOT}/docker-compose.yml', 'w') as f:
    f.write(content)
PYEOF
rm -f /tmp/_gen_db_services.txt /tmp/_gen_db_depends.txt /tmp/_gen_db_volumes.txt /tmp/_gen_pgbadger_vols.txt /tmp/_gen_etcd_services.txt /tmp/_gen_etcd_depends.txt /tmp/_gen_etcd_volumes.txt

# --- Generate .env.example port entries ---
ETCD_PORT_ENTRIES=""
for i in $(seq 1 $ETCD_COUNT); do
    CLIENT=$(( i == 1 ? 2379 : i * 10000 + 2379 ))
    PEER=$(( i == 1 ? 2380 : i * 10000 + 2380 ))
    ENTRY="ETCD${i}_CLIENT_PORT=${CLIENT}
ETCD${i}_PEER_PORT=${PEER}"
    if [ -n "$ETCD_PORT_ENTRIES" ]; then
        ETCD_PORT_ENTRIES="${ETCD_PORT_ENTRIES}
${ENTRY}"
    else
        ETCD_PORT_ENTRIES="${ENTRY}"
    fi
done
printf '%s' "$ETCD_PORT_ENTRIES" > /tmp/_gen_etcd_port_entries.txt

DB_PORT_ENTRIES=""
for i in $(seq 1 $PATRONI_NODES); do
    port=$((PATRONI_BASE_PORT + i - 1))
    api=$((PATRONI_API_BASE_PORT + i - 1))
    ENTRY="PATRONI_DB${i}_PORT=${port}
PATRONI_DB${i}_API_PORT=${api}"
    if [ -n "$DB_PORT_ENTRIES" ]; then
        DB_PORT_ENTRIES="${DB_PORT_ENTRIES}
${ENTRY}"
    else
        DB_PORT_ENTRIES="${ENTRY}"
    fi
done

printf '%s' "$DB_PORT_ENTRIES" > /tmp/_gen_port_entries.txt

python3 << PYEOF
with open('${TEMPLATE_DIR}/env.tpl', 'r') as f:
    content = f.read()
with open('/tmp/_gen_port_entries.txt', 'r') as f:
    port_entries = f.read()
content = content.replace('__DB_PORT_ENTRIES__', port_entries)
with open('/tmp/_gen_etcd_port_entries.txt', 'r') as f:
    etcd_port_entries = f.read()
content = content.replace('__ETCD_PORT_ENTRIES__', etcd_port_entries)
with open('${PROJECT_ROOT}/.env.example', 'w') as f:
    f.write(content)
PYEOF
rm -f /tmp/_gen_port_entries.txt /tmp/_gen_etcd_port_entries.txt

# --- Update .env port entries ---
if [ -f "$PROJECT_ROOT/.env" ]; then
    python3 << PYEOF
import re

with open('${PROJECT_ROOT}/.env') as f:
    content = f.read()

# Update PATRONI_REPLICAS (migrating legacy PATRONI_NODES if present)
if re.search(r'^PATRONI_REPLICAS=', content, flags=re.MULTILINE):
    content = re.sub(r'^PATRONI_REPLICAS=.*', 'PATRONI_REPLICAS=${PATRONI_REPLICAS}', content, flags=re.MULTILINE)
    content = re.sub(r'^PATRONI_NODES=.*\n', '', content, flags=re.MULTILINE)
elif re.search(r'^PATRONI_NODES=', content, flags=re.MULTILINE):
    content = re.sub(r'^PATRONI_NODES=.*', 'PATRONI_REPLICAS=${PATRONI_REPLICAS}', content, flags=re.MULTILINE)
else:
    content = re.sub(
        r'(^PATRONI_CLUSTER_NAME=.*\n)',
        r'\1' + 'PATRONI_REPLICAS=${PATRONI_REPLICAS}' + '\n',
        content,
        flags=re.MULTILINE
    )

# Remove existing per-node port entries
content = re.sub(r'^PATRONI_DB\d+_(API_)?PORT=.*\n', '', content, flags=re.MULTILINE)

# Refresh etcd entries (ports, count, host list)
content = re.sub(r'^ETCD\d+_(CLIENT|PEER)_PORT=.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^ETCD_COUNT=.*\n', '', content, flags=re.MULTILINE)
content = re.sub(r'^ETCD_HOSTS=.*\n', '', content, flags=re.MULTILINE)
etcd_entries = ['ETCD_COUNT=${ETCD_COUNT}']
for i in range(1, ${ETCD_COUNT} + 1):
    c_port = 2379 if i == 1 else i * 10000 + 2379
    p_port = 2380 if i == 1 else i * 10000 + 2380
    etcd_entries.append(f'ETCD{i}_CLIENT_PORT={c_port}')
    etcd_entries.append(f'ETCD{i}_PEER_PORT={p_port}')
etcd_entries.append('ETCD_HOSTS=${ETCD_HOSTS}')
etcd_block = '\n'.join(etcd_entries)
if re.search(r'^# etcd Consensus Cluster.*\n', content, flags=re.MULTILINE):
    content = re.sub(r'(^# etcd Consensus Cluster.*\n)', r'\1' + etcd_block + '\n', content, flags=re.MULTILINE)
else:
    content = re.sub(
        r'(^PATRONI_API_BASE_PORT=.*\n)',
        r'\1' + etcd_block + '\n',
        content, flags=re.MULTILINE
    )

# Ensure POSTGRES_VERSION is set (drives data_dir/bin_dir paths)
if not re.search(r'^POSTGRES_VERSION=', content, flags=re.MULTILINE):
    content = re.sub(r'(^POSTGRES_USER=.*\n)', r'\1POSTGRES_VERSION=${POSTGRES_VERSION:-15}\n', content, flags=re.MULTILINE)

# Build new port entries
port_entries = []
for i in range(1, ${PATRONI_NODES} + 1):
    port_entries.append(f'PATRONI_DB{i}_PORT={${PATRONI_BASE_PORT} + i - 1}')
    port_entries.append(f'PATRONI_DB{i}_API_PORT={${PATRONI_API_BASE_PORT} + i - 1}')
port_block = '\n'.join(port_entries)

# Insert after PATRONI_API_BASE_PORT line
content = re.sub(
    r'(^PATRONI_API_BASE_PORT=.*\n)',
    r'\1' + port_block + '\n',
    content,
    flags=re.MULTILINE
)

with open('${PROJECT_ROOT}/.env', 'w') as f:
    f.write(content)
PYEOF
fi

echo ""
echo "Generated configs for $PATRONI_NODES nodes:"
echo "  configs/haproxy.cfg"
echo "  configs/barman.conf"
echo "  configs/pgbouncer.ini"
echo "  configs/pgbouncer-ro.ini"
echo "  barman/supervisord.conf"
echo "  docker-compose.yml"
echo "  .env.example"
echo ""
echo "Configuration generation complete."
