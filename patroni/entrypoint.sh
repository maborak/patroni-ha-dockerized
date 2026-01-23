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

# SSH daemon will be started by supervisor
echo "SSH daemon will be started by supervisor"

# Execute the main command (supervisord)
exec "$@"

