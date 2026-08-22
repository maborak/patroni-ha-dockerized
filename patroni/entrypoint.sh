#!/bin/bash
set -e

# Get postgres user's actual home directory
POSTGRES_HOME=$(getent passwd postgres | cut -d: -f6)
if [ -z "$POSTGRES_HOME" ]; then
    POSTGRES_HOME="/var/lib/postgresql"
fi

# Create .ssh directory for postgres user (in actual home directory)
mkdir -p "$POSTGRES_HOME/.ssh"
chmod 700 "$POSTGRES_HOME/.ssh"
chown postgres:postgres "$POSTGRES_HOME/.ssh"

# Copy SSH key from mounted location to postgres home directory
# This key will be used for all SSH connections (to Barman and other DB nodes)
if [ -f /ssh_keys/barman_rsa ]; then
    echo "Setting up SSH key for postgres user from /ssh_keys/barman_rsa..."
    # Copy as id_rsa (default SSH key location)
    cp /ssh_keys/barman_rsa "$POSTGRES_HOME/.ssh/id_rsa"
    chmod 600 "$POSTGRES_HOME/.ssh/id_rsa"
    chown postgres:postgres "$POSTGRES_HOME/.ssh/id_rsa"
    echo "SSH key configured at $POSTGRES_HOME/.ssh/id_rsa"
    
    # Also copy as barman_rsa for backward compatibility
    cp /ssh_keys/barman_rsa "$POSTGRES_HOME/.ssh/barman_rsa"
    chmod 600 "$POSTGRES_HOME/.ssh/barman_rsa"
    chown postgres:postgres "$POSTGRES_HOME/.ssh/barman_rsa"
    echo "SSH key also configured at $POSTGRES_HOME/.ssh/barman_rsa (for compatibility)"
    
    # Copy public key if available
    if [ -f /ssh_keys/barman_rsa.pub ]; then
        cp /ssh_keys/barman_rsa.pub "$POSTGRES_HOME/.ssh/id_rsa.pub"
        chmod 644 "$POSTGRES_HOME/.ssh/id_rsa.pub"
        chown postgres:postgres "$POSTGRES_HOME/.ssh/id_rsa.pub"
        echo "SSH public key configured at $POSTGRES_HOME/.ssh/id_rsa.pub"
    fi
else
    echo "WARNING: SSH key not found at /ssh_keys/barman_rsa"
fi

# Add public key to authorized_keys so other nodes can connect to this node
# This enables: Barman -> DB nodes, DB nodes -> DB nodes
if [ -f /ssh_keys/barman_rsa.pub ]; then
    echo "Adding SSH public key to postgres authorized_keys in $POSTGRES_HOME/.ssh/..."
    PUBKEY=$(cat /ssh_keys/barman_rsa.pub)
    if ! grep -q "$PUBKEY" "$POSTGRES_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$POSTGRES_HOME/.ssh/authorized_keys"
    fi
    chmod 600 "$POSTGRES_HOME/.ssh/authorized_keys"
    chown postgres:postgres "$POSTGRES_HOME/.ssh/authorized_keys"
    echo "SSH key added successfully to $POSTGRES_HOME/.ssh/authorized_keys"
fi

# Set up SSH for root user as well (for root connections between containers)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ -f /ssh_keys/barman_rsa ]; then
    cp /ssh_keys/barman_rsa /root/.ssh/id_rsa
    chmod 600 /root/.ssh/id_rsa
    echo "SSH key configured for root at /root/.ssh/id_rsa"
fi
if [ -f /ssh_keys/barman_rsa.pub ]; then
    PUBKEY=$(cat /ssh_keys/barman_rsa.pub)
    if ! grep -q "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBKEY" >> /root/.ssh/authorized_keys
    fi
    chmod 600 /root/.ssh/authorized_keys
    echo "SSH key added to root authorized_keys"
fi

# Ensure the shared log directory exists (named volume; JSON logs + archive.log)
# pgBadger mounts this volume read-write to collect and clean up rotated logs.
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql
chmod 700 /var/log/postgresql

# Generate node-specific Patroni config from template
if [ -f /etc/patroni/patroni.yml.tpl ]; then
    NODE_NAME=$(hostname)
    echo "Generating Patroni config for node: $NODE_NAME"
    python3 - << 'PYEOF'
import os

tpl_path = '/etc/patroni/patroni.yml.tpl'
out_path = '/etc/patroni/patroni.yml'

node_name = os.environ.get('HOSTNAME', 'db1')
pg_pass = os.environ.get('POSTGRES_PASSWORD', '')
repl_pass = os.environ.get('REPLICATOR_PASSWORD', pg_pass)

subs = {
    '__NODE_NAME__': node_name,
    '__CLUSTER_NAME__': os.environ.get('PATRONI_CLUSTER_NAME', 'patroni1'),
    '__ETCD_HOSTS__': os.environ.get('ETCD_HOSTS', 'etcd1:2379,etcd2:2379,etcd3:2379'),
    '__PG_VERSION__': os.environ.get('POSTGRES_VERSION', '15'),
    '__POSTGRES_USER__': os.environ.get('POSTGRES_USER', 'postgres'),
    '__REPLICATOR_USER__': os.environ.get('REPLICATOR_USER', 'replicator'),
    '__POSTGRES_PASSWORD__': pg_pass,
    '__REPLICATOR_PASSWORD__': repl_pass,
    '__PATRONI_TTL__': os.environ.get('PATRONI_TTL', '30'),
    '__PATRONI_LOOP_WAIT__': os.environ.get('PATRONI_LOOP_WAIT', '10'),
    '__PATRONI_RETRY_TIMEOUT__': os.environ.get('PATRONI_RETRY_TIMEOUT', '10'),
    '__PATRONI_MAX_LAG_ON_FAILOVER__': os.environ.get('PATRONI_MAX_LAG_ON_FAILOVER', '1048576'),
    '__PATRONI_MASTER_START_TIMEOUT__': os.environ.get('PATRONI_MASTER_START_TIMEOUT', '300'),
    '__PATRONI_BASEBACKUP_MAX_RATE__': os.environ.get('PATRONI_BASEBACKUP_MAX_RATE', '100M'),
    '__PG_MAX_CONNECTIONS__': os.environ.get('PG_MAX_CONNECTIONS', '200'),
    '__PG_SHARED_BUFFERS__': os.environ.get('PG_SHARED_BUFFERS', '2GB'),
    '__PG_EFFECTIVE_CACHE_SIZE__': os.environ.get('PG_EFFECTIVE_CACHE_SIZE', '6GB'),
    '__PG_WORK_MEM__': os.environ.get('PG_WORK_MEM', '16MB'),
    '__PG_MAINTENANCE_WORK_MEM__': os.environ.get('PG_MAINTENANCE_WORK_MEM', '512MB'),
    '__PG_DEFAULT_STATISTICS_TARGET__': os.environ.get('PG_DEFAULT_STATISTICS_TARGET', '100'),
    '__PG_LOG_MIN_DURATION_STATEMENT__': os.environ.get('PG_LOG_MIN_DURATION_STATEMENT', '250ms'),
    '__PG_LOG_STATEMENT__': os.environ.get('PG_LOG_STATEMENT', 'ddl'),
}

with open(tpl_path, 'r') as f:
    content = f.read()

for k, v in subs.items():
    content = content.replace(k, str(v))

with open(out_path, 'w') as f:
    f.write(content)
PYEOF
    chown postgres:postgres /etc/patroni/patroni.yml
fi


# SSH daemon will be started by supervisor
echo "SSH daemon will be started by supervisor"

# Execute the main command (supervisord)
exec "$@"

