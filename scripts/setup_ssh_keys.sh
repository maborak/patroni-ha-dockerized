#!/bin/bash
# Script to generate SSH keys for Patroni nodes to access Barman
# This should be run once to generate the keys, then the keys are mounted into containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/../ssh_keys"

# Create keys directory if it doesn't exist
mkdir -p "$KEYS_DIR"

# Generate SSH key pair if it doesn't exist
if [ ! -f "$KEYS_DIR/barman_rsa" ]; then
    echo "Generating SSH key pair for Barman access..."
    ssh-keygen -t rsa -b 4096 -f "$KEYS_DIR/barman_rsa" -N "" -C "patroni-to-barman"
    chmod 600 "$KEYS_DIR/barman_rsa"
    chmod 644 "$KEYS_DIR/barman_rsa.pub"
    echo "SSH keys generated successfully!"
    echo "Private key: $KEYS_DIR/barman_rsa"
    echo "Public key: $KEYS_DIR/barman_rsa.pub"
else
    echo "SSH keys already exist at $KEYS_DIR/barman_rsa"
fi

