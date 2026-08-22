#!/bin/bash
# Script to generate SSH keys for Patroni nodes to access Barman
# This should be run once to generate the keys, then the keys are mounted into containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KEYS_DIR="$PROJECT_ROOT/ssh_keys"

# Create keys directory if it doesn't exist
mkdir -p "$KEYS_DIR"

# Generate SSH key pair if it doesn't exist
if [ ! -f "$KEYS_DIR/barman_rsa" ]; then
    echo "Generating SSH key pair for Barman <-> Patroni communication..."
    ssh-keygen -t rsa -b 4096 -f "$KEYS_DIR/barman_rsa" -N "" -C "patroni-to-barman"
    chmod 600 "$KEYS_DIR/barman_rsa"
    chmod 644 "$KEYS_DIR/barman_rsa.pub"
    echo "SSH keys generated successfully at $KEYS_DIR/barman_rsa"
else
    # Ensure correct permissions on existing keys
    chmod 600 "$KEYS_DIR/barman_rsa" 2>/dev/null || true
    chmod 644 "$KEYS_DIR/barman_rsa.pub" 2>/dev/null || true
    echo "SSH keys verified at $KEYS_DIR/barman_rsa"
fi


