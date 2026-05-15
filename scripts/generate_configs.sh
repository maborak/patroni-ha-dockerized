#!/bin/bash
set -euo pipefail
# Generate all config files from templates based on PATRONI_NODES

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
TEMPLATE_DIR="$PROJECT_ROOT/templates"

# Save any overrides passed via environment before sourcing .env
_OVERRIDE_NODES="${PATRONI_NODES:-}"

# Source .env for defaults
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a; source "$PROJECT_ROOT/.env"; set +a
fi

# Command-line override takes precedence over .env
if [ -n "$_OVERRIDE_NODES" ]; then
    PATRONI_NODES="$_OVERRIDE_NODES"
fi

PATRONI_NODES=${PATRONI_NODES:-4}
PATRONI_BASE_PORT=${PATRONI_BASE_PORT:-15431}
PATRONI_API_BASE_PORT=${PATRONI_API_BASE_PORT:-8001}

if [ "$PATRONI_NODES" -lt 2 ]; then
    echo "ERROR: PATRONI_NODES must be >= 2 (got $PATRONI_NODES)"
    exit 1
fi

echo "Generating configs for $PATRONI_NODES Patroni nodes..."

# Build node list
NODES=""
for i in $(seq 1 $PATRONI_NODES); do
    NODES="${NODES}db${i} "
done

# --- Patroni config ---
# No per-node generation needed. The entrypoint substitutes __NODE_NAME__ at runtime.
# templates/patroni.yml.tpl is mounted directly into containers.

# --- Generate haproxy.cfg ---
WRITE_SERVERS=""
READ_SERVERS=""
for i in $(seq 1 $PATRONI_NODES); do
    LINE="    server db${i} db${i}:5431 check port 8001 inter 2000 fall 3 rise 2"
    if [ -n "$WRITE_SERVERS" ]; then
        WRITE_SERVERS="${WRITE_SERVERS}
${LINE}"
        READ_SERVERS="${READ_SERVERS}
${LINE}"
    else
        WRITE_SERVERS="${LINE}"
        READ_SERVERS="${LINE}"
    fi
done

python3 << PYEOF
with open('${TEMPLATE_DIR}/haproxy.cfg.tpl', 'r') as f:
    content = f.read()
content = content.replace('__WRITE_SERVERS__', """${WRITE_SERVERS}""")
content = content.replace('__READ_SERVERS__', """${READ_SERVERS}""")
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
conninfo = host=db${i} user=postgres dbname=postgres port=5431
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
replacement = """${DB_SECTIONS}"""
content = content.replace('__DB_SECTIONS__', replacement)
with open('${PROJECT_ROOT}/configs/barman.conf', 'w') as f:
    f.write(content)
PYEOF

# --- Generate barman/supervisord.conf ---
BACKUP_SERVERS=$(echo $NODES | xargs)  # trim whitespace
sed "s/__BACKUP_SERVERS__/${BACKUP_SERVERS}/" \
    "$TEMPLATE_DIR/barman-supervisord.conf.tpl" > "$PROJECT_ROOT/barman/supervisord.conf"

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
    environment:
      - DEFAULT_DATABASE=\${DEFAULT_DATABASE:-maborak}
    volumes:
      - db${i}_data:/var/lib/postgresql
      - ./templates/patroni.yml.tpl:/etc/patroni/patroni.yml.tpl:ro
      - ./scripts:/etc/patroni/scripts:ro
      - ./ssh_keys/barman_rsa:/ssh_keys/barman_rsa:ro
      - ./ssh_keys/barman_rsa.pub:/ssh_keys/barman_rsa.pub:ro"
    if [ -n "$DB_SERVICES" ]; then
        DB_SERVICES="${DB_SERVICES}

${BLOCK}"
    else
        DB_SERVICES="${BLOCK}"
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

# Build volume declarations
DB_VOLUMES=""
for i in $(seq 1 $PATRONI_NODES); do
    ENTRY="  db${i}_data:"
    if [ -n "$DB_VOLUMES" ]; then
        DB_VOLUMES="${DB_VOLUMES}
${ENTRY}"
    else
        DB_VOLUMES="${ENTRY}"
    fi
done

# Write intermediate files for python to read (avoids shell quoting issues)
printf '%s' "$DB_SERVICES" > /tmp/_gen_db_services.txt
printf '%s' "$DB_DEPENDS_ON" > /tmp/_gen_db_depends.txt
printf '%s' "$DB_VOLUMES" > /tmp/_gen_db_volumes.txt

python3 << PYEOF
with open('${TEMPLATE_DIR}/docker-compose.yml.tpl', 'r') as f:
    content = f.read()
with open('/tmp/_gen_db_services.txt', 'r') as f:
    db_services = f.read()
with open('/tmp/_gen_db_depends.txt', 'r') as f:
    db_depends = f.read()
with open('/tmp/_gen_db_volumes.txt', 'r') as f:
    db_volumes = f.read()
content = content.replace('__DB_SERVICES__', db_services)
content = content.replace('__DB_DEPENDS_ON_HEALTHY__', db_depends)
content = content.replace('__DB_VOLUMES__', db_volumes)
with open('${PROJECT_ROOT}/docker-compose.yml', 'w') as f:
    f.write(content)
PYEOF
rm -f /tmp/_gen_db_services.txt /tmp/_gen_db_depends.txt /tmp/_gen_db_volumes.txt

# --- Generate .env.example port entries ---
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
with open('${PROJECT_ROOT}/.env.example', 'w') as f:
    f.write(content)
PYEOF
rm -f /tmp/_gen_port_entries.txt

# --- Update .env port entries ---
if [ -f "$PROJECT_ROOT/.env" ]; then
    python3 << PYEOF
import re

with open('${PROJECT_ROOT}/.env') as f:
    content = f.read()

# Update PATRONI_NODES
content = re.sub(r'^PATRONI_NODES=.*', 'PATRONI_NODES=${PATRONI_NODES}', content, flags=re.MULTILINE)

# Remove existing per-node port entries
content = re.sub(r'^PATRONI_DB\d+_(API_)?PORT=.*\n', '', content, flags=re.MULTILINE)

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
echo "  barman/supervisord.conf"
echo "  docker-compose.yml"
echo "  .env.example"
echo ""
echo "Next: Update .env port entries if needed, then 'docker-compose up -d'"
