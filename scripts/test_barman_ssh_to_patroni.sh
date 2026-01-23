#!/bin/bash
# Test Barman SSH connectivity to Patroni nodes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Testing Barman SSH to Patroni Nodes${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if containers are running
if ! docker ps --format '{{.Names}}' | grep -q "^barman$"; then
    echo -e "${RED}ERROR: Barman container is not running!${NC}"
    exit 1
fi

# Check Barman's private SSH key
echo -e "${YELLOW}Checking Barman's private SSH key...${NC}"
BARMAN_HOME=$(docker exec barman getent passwd barman | cut -d: -f6)
if [ -z "$BARMAN_HOME" ]; then
    BARMAN_HOME="/var/lib/barman"
fi

if docker exec barman test -f "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null; then
    echo -e "${GREEN}✓ Barman private SSH key exists${NC}"
    KEY_PERMS=$(docker exec barman stat -c "%a" "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null || docker exec barman ls -l "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null | awk '{print $1}')
    if [ "$KEY_PERMS" == "600" ] || echo "$KEY_PERMS" | grep -q "^-rw-------"; then
        echo -e "${GREEN}✓ Private key permissions are correct (600)${NC}"
    else
        echo -e "${YELLOW}⚠ Private key permissions: $KEY_PERMS (expected 600)${NC}"
    fi
else
    echo -e "${RED}✗ Barman private SSH key not found${NC}"
fi
echo ""

# Test SSH connections from Barman to each Patroni node
NODES=("db1" "db2" "db3" "db4")
SUCCESS_COUNT=0
FAIL_COUNT=0

for node in "${NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        echo -e "${YELLOW}⚠ ${node}: Container not running, skipping${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    echo -e "${YELLOW}Testing SSH from Barman to ${node}...${NC}"
    
    # Test SSH connection (capture output and exit code separately to avoid set -e issues)
    set +e
    SSH_OUTPUT=$(docker exec -u barman barman ssh -i "$BARMAN_HOME/.ssh/id_rsa" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=3 postgres@${node} 'echo SSH_SUCCESS' 2>&1)
    SSH_EXIT_CODE=$?
    set -e
    
    if [ $SSH_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: SSH connection successful${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}✗ ${node}: SSH connection failed${NC}"
        echo "  Error: $(echo "$SSH_OUTPUT" | head -3 | sed 's/^/    /')"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    echo ""
done

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Successful connections: ${GREEN}${SUCCESS_COUNT}${NC}"
echo -e "Failed connections: ${RED}${FAIL_COUNT}${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All SSH connections successful!${NC}"
    exit 0
else
    echo -e "${RED}Some SSH connections failed.${NC}"
    exit 1
fi

