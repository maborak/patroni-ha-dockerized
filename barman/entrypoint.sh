#!/bin/bash
set -e

# Get barman user's actual home directory
BARMAN_HOME=$(getent passwd barman | cut -d: -f6)
if [ -z "$BARMAN_HOME" ]; then
    BARMAN_HOME="/var/lib/barman"
fi

# Create .ssh directory in barman's home directory
mkdir -p "$BARMAN_HOME/.ssh"
chmod 700 "$BARMAN_HOME/.ssh"
chown -R barman:barman "$BARMAN_HOME/.ssh"

# Copy SSH key from mounted location to barman's home directory
# This key will be used for all SSH connections (to DB nodes)
if [ -f /ssh_keys/barman_rsa ]; then
    echo "Setting up SSH key for barman user from /ssh_keys/barman_rsa..."
    # Copy as id_rsa (default SSH key location) to actual home directory
    cp /ssh_keys/barman_rsa "$BARMAN_HOME/.ssh/id_rsa"
    chmod 600 "$BARMAN_HOME/.ssh/id_rsa"
    chown barman:barman "$BARMAN_HOME/.ssh/id_rsa"
    echo "Barman SSH key configured at $BARMAN_HOME/.ssh/id_rsa"
    
    # Also set up in /home/barman/.ssh for loopback connections (barman → barman)
    if [ "$BARMAN_HOME" != "/home/barman" ]; then
        mkdir -p /home/barman/.ssh
        chmod 700 /home/barman/.ssh
        chown barman:barman /home/barman/.ssh
        cp /ssh_keys/barman_rsa /home/barman/.ssh/id_rsa
        chmod 600 /home/barman/.ssh/id_rsa
        chown barman:barman /home/barman/.ssh/id_rsa
        echo "Barman SSH key also configured at /home/barman/.ssh/id_rsa (for loopback connections)"
    fi
    
    # Copy public key if available
    if [ -f /ssh_keys/barman_rsa.pub ]; then
        cp /ssh_keys/barman_rsa.pub "$BARMAN_HOME/.ssh/id_rsa.pub"
        chmod 644 "$BARMAN_HOME/.ssh/id_rsa.pub"
        chown barman:barman "$BARMAN_HOME/.ssh/id_rsa.pub"
        echo "Barman SSH public key configured at $BARMAN_HOME/.ssh/id_rsa.pub"
        
        # Also copy to /home/barman/.ssh if different
        if [ "$BARMAN_HOME" != "/home/barman" ]; then
            cp /ssh_keys/barman_rsa.pub /home/barman/.ssh/id_rsa.pub
            chmod 644 /home/barman/.ssh/id_rsa.pub
            chown barman:barman /home/barman/.ssh/id_rsa.pub
            echo "Barman SSH public key also configured at /home/barman/.ssh/id_rsa.pub"
        fi
    fi
else
    echo "WARNING: SSH key not found at /ssh_keys/barman_rsa"
fi

# Add public key to barman's authorized_keys so DB nodes can connect to Barman
# This enables: DB nodes -> Barman, and loopback connections (barman -> barman)
if [ -f /ssh_keys/barman_rsa.pub ]; then
    echo "Adding SSH public key to barman's authorized_keys in $BARMAN_HOME/.ssh/..."
    PUBKEY=$(cat /ssh_keys/barman_rsa.pub)
    if ! grep -q "$PUBKEY" "$BARMAN_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$BARMAN_HOME/.ssh/authorized_keys"
    fi
    chmod 600 "$BARMAN_HOME/.ssh/authorized_keys"
    chown barman:barman "$BARMAN_HOME/.ssh/authorized_keys"
    echo "SSH key added successfully to $BARMAN_HOME/.ssh/authorized_keys"
    
    # Also add to /home/barman/.ssh/authorized_keys for loopback connections
    if [ "$BARMAN_HOME" != "/home/barman" ]; then
        mkdir -p /home/barman/.ssh
        chmod 700 /home/barman/.ssh
        chown barman:barman /home/barman/.ssh
        if ! grep -q "$PUBKEY" /home/barman/.ssh/authorized_keys 2>/dev/null; then
            echo "$PUBKEY" >> /home/barman/.ssh/authorized_keys
        fi
        chmod 600 /home/barman/.ssh/authorized_keys
        chown barman:barman /home/barman/.ssh/authorized_keys
        echo "SSH key also added to /home/barman/.ssh/authorized_keys (for loopback connections)"
    fi
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

# Create .pgpass file for barman user
echo "Creating .pgpass file for barman user..."
PGPASS_FILE="$BARMAN_HOME/.pgpass"
# Generate .pgpass entries for all database nodes
# Format: host:*:*:user:password (matches Ansible template format)
cat > "$PGPASS_FILE" <<EOF
db1:*:*:postgres:${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
db2:*:*:postgres:${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
db3:*:*:postgres:${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
db4:*:*:postgres:${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
EOF
chmod 600 "$PGPASS_FILE"
chown barman:barman "$PGPASS_FILE"
echo ".pgpass file created successfully"

# Start SSH daemon (will be managed by supervisor)
echo "SSH daemon will be started by supervisor"

# Execute the main command (supervisord)
exec "$@"

