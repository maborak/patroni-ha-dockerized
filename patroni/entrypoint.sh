#!/bin/bash
set -e

# Set correct permissions on SSH key if it exists (ignore errors if read-only)
if [ -f /home/postgres/.ssh/barman_rsa ]; then
    chmod 600 /home/postgres/.ssh/barman_rsa 2>/dev/null || true
    chown postgres:postgres /home/postgres/.ssh/barman_rsa 2>/dev/null || true
fi

# Get postgres user's actual home directory
POSTGRES_HOME=$(getent passwd postgres | cut -d: -f6)
if [ -z "$POSTGRES_HOME" ]; then
    POSTGRES_HOME="/var/lib/postgresql"
fi

# Create .ssh directory and authorized_keys if needed (in actual home directory)
mkdir -p "$POSTGRES_HOME/.ssh"
chmod 700 "$POSTGRES_HOME/.ssh"
chown postgres:postgres "$POSTGRES_HOME/.ssh"

# Add Barman's public key to authorized_keys if provided
if [ -f /ssh_keys/barman_rsa.pub ]; then
    echo "Adding Barman's SSH public key to postgres authorized_keys in $POSTGRES_HOME/.ssh/..."
    PUBKEY=$(cat /ssh_keys/barman_rsa.pub)
    if ! grep -q "$PUBKEY" "$POSTGRES_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$POSTGRES_HOME/.ssh/authorized_keys"
    fi
    chmod 600 "$POSTGRES_HOME/.ssh/authorized_keys"
    chown postgres:postgres "$POSTGRES_HOME/.ssh/authorized_keys"
    echo "Barman SSH key added successfully to $POSTGRES_HOME/.ssh/authorized_keys"
fi

# SSH daemon will be started by supervisor
echo "SSH daemon will be started by supervisor"

# Execute the main command (supervisord)
exec "$@"

