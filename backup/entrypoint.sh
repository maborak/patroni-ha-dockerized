#!/bin/bash
set -e

# Get backup user's actual home directory
BARMAN_HOME=$(getent passwd backup | cut -d: -f6)
if [ -z "$BARMAN_HOME" ]; then
    BARMAN_HOME="/var/lib/backup"
fi

# Create .ssh directory in backup's home directory
mkdir -p "$BARMAN_HOME/.ssh"
chmod 700 "$BARMAN_HOME/.ssh"
chown -R backup:backup "$BARMAN_HOME/.ssh"

# Copy SSH key from mounted location to backup's home directory
# This key will be used for all SSH connections (to DB nodes)
if [ -f /ssh_keys/backup_rsa ]; then
    echo "Setting up SSH key for backup user from /ssh_keys/backup_rsa..."
    # Copy as id_rsa (default SSH key location) to actual home directory
    cp /ssh_keys/backup_rsa "$BARMAN_HOME/.ssh/id_rsa"
    chmod 600 "$BARMAN_HOME/.ssh/id_rsa"
    chown backup:backup "$BARMAN_HOME/.ssh/id_rsa"
    echo "Backup SSH key configured at $BARMAN_HOME/.ssh/id_rsa"
    
    # Also set up in /home/backup/.ssh for loopback connections (backup → backup)
    if [ "$BARMAN_HOME" != "/home/backup" ]; then
        mkdir -p /home/backup/.ssh
        chmod 700 /home/backup/.ssh
        chown backup:backup /home/backup/.ssh
        cp /ssh_keys/backup_rsa /home/backup/.ssh/id_rsa
        chmod 600 /home/backup/.ssh/id_rsa
        chown backup:backup /home/backup/.ssh/id_rsa
        echo "Backup SSH key also configured at /home/backup/.ssh/id_rsa (for loopback connections)"
    fi
    
    # Copy public key if available
    if [ -f /ssh_keys/backup_rsa.pub ]; then
        cp /ssh_keys/backup_rsa.pub "$BARMAN_HOME/.ssh/id_rsa.pub"
        chmod 644 "$BARMAN_HOME/.ssh/id_rsa.pub"
        chown backup:backup "$BARMAN_HOME/.ssh/id_rsa.pub"
        echo "Backup SSH public key configured at $BARMAN_HOME/.ssh/id_rsa.pub"
        
        # Also copy to /home/backup/.ssh if different
        if [ "$BARMAN_HOME" != "/home/backup" ]; then
            cp /ssh_keys/backup_rsa.pub /home/backup/.ssh/id_rsa.pub
            chmod 644 /home/backup/.ssh/id_rsa.pub
            chown backup:backup /home/backup/.ssh/id_rsa.pub
            echo "Backup SSH public key also configured at /home/backup/.ssh/id_rsa.pub"
        fi
    fi
else
    echo "WARNING: SSH key not found at /ssh_keys/backup_rsa"
fi

# Add public key to backup's authorized_keys so DB nodes can connect to Backup
# This enables: DB nodes -> Backup, and loopback connections (backup -> backup)
if [ -f /ssh_keys/backup_rsa.pub ]; then
    echo "Adding SSH public key to backup's authorized_keys in $BARMAN_HOME/.ssh/..."
    PUBKEY=$(cat /ssh_keys/backup_rsa.pub)
    if ! grep -q "$PUBKEY" "$BARMAN_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$BARMAN_HOME/.ssh/authorized_keys"
    fi
    chmod 600 "$BARMAN_HOME/.ssh/authorized_keys"
    chown backup:backup "$BARMAN_HOME/.ssh/authorized_keys"
    echo "SSH key added successfully to $BARMAN_HOME/.ssh/authorized_keys"
    
    # Also add to /home/backup/.ssh/authorized_keys for loopback connections
    if [ "$BARMAN_HOME" != "/home/backup" ]; then
        mkdir -p /home/backup/.ssh
        chmod 700 /home/backup/.ssh
        chown backup:backup /home/backup/.ssh
        if ! grep -q "$PUBKEY" /home/backup/.ssh/authorized_keys 2>/dev/null; then
            echo "$PUBKEY" >> /home/backup/.ssh/authorized_keys
        fi
        chmod 600 /home/backup/.ssh/authorized_keys
        chown backup:backup /home/backup/.ssh/authorized_keys
        echo "SSH key also added to /home/backup/.ssh/authorized_keys (for loopback connections)"
    fi
fi

# Set up SSH for root user as well (for root connections between containers)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ -f /ssh_keys/backup_rsa ]; then
    cp /ssh_keys/backup_rsa /root/.ssh/id_rsa
    chmod 600 /root/.ssh/id_rsa
    echo "SSH key configured for root at /root/.ssh/id_rsa"
fi
if [ -f /ssh_keys/backup_rsa.pub ]; then
    PUBKEY=$(cat /ssh_keys/backup_rsa.pub)
    if ! grep -q "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBKEY" >> /root/.ssh/authorized_keys
    fi
    chmod 600 /root/.ssh/authorized_keys
    echo "SSH key added to root authorized_keys"
fi

# Create .pgpass file for backup user
echo "Creating .pgpass file for backup user..."
PGPASS_FILE="$BARMAN_HOME/.pgpass"
# Generate .pgpass entries for all database nodes (replicas + leader)
# Format: host:*:*:user:password (matches Ansible template format)
PGUSER="${POSTGRES_USER:-postgres}"
PGPASS_NODES=$(( ${PATRONI_REPLICAS:-2} + 1 ))
: > "$PGPASS_FILE"
for i in $(seq 1 "$PGPASS_NODES"); do
    echo "db${i}:*:*:${PGUSER}:${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD}" >> "$PGPASS_FILE"
done
chmod 600 "$PGPASS_FILE"
chown backup:backup "$PGPASS_FILE"
echo ".pgpass file created successfully"

# Start SSH daemon (will be managed by supervisor)
echo "SSH daemon will be started by supervisor"

# Execute the main command (supervisord)
exec "$@"

