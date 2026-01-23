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

# Add private SSH key for Barman to connect to Patroni nodes
# Copy from mounted location to actual home directory
if [ -f /home/barman/.ssh/barman_rsa ]; then
    echo "Setting up Barman's private SSH key from mount..."
    cp /home/barman/.ssh/barman_rsa "$BARMAN_HOME/.ssh/id_rsa"
    chmod 600 "$BARMAN_HOME/.ssh/id_rsa"
    chown barman:barman "$BARMAN_HOME/.ssh/id_rsa"
    echo "Barman private SSH key configured at $BARMAN_HOME/.ssh/id_rsa"
    # Also copy public key if available
    if [ -f /home/barman/.ssh/barman_rsa.pub ]; then
        cp /home/barman/.ssh/barman_rsa.pub "$BARMAN_HOME/.ssh/id_rsa.pub"
        chmod 644 "$BARMAN_HOME/.ssh/id_rsa.pub"
        chown barman:barman "$BARMAN_HOME/.ssh/id_rsa.pub"
        echo "Barman public SSH key configured at $BARMAN_HOME/.ssh/id_rsa.pub"
    fi
else
    echo "WARNING: Barman private SSH key not found at /home/barman/.ssh/barman_rsa"
fi

# Add public key to barman's authorized_keys if provided
if [ -f /ssh_keys/barman_rsa.pub ]; then
    echo "Adding SSH public key to barman's authorized_keys in $BARMAN_HOME/.ssh/..."
    # Remove existing key if present to avoid duplicates
    PUBKEY=$(cat /ssh_keys/barman_rsa.pub)
    if ! grep -q "$PUBKEY" "$BARMAN_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$PUBKEY" >> "$BARMAN_HOME/.ssh/authorized_keys"
    fi
    chmod 600 "$BARMAN_HOME/.ssh/authorized_keys"
    chown barman:barman "$BARMAN_HOME/.ssh/authorized_keys"
    echo "SSH key added successfully to $BARMAN_HOME/.ssh/authorized_keys"
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

