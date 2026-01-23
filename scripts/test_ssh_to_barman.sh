#!/bin/bash
# Test SSH connectivity from all Patroni nodes to Barman

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
echo -e "${BLUE}  Testing SSH from Patroni to Barman${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if SSH keys exist
if [ ! -f "ssh_keys/barman_rsa" ] || [ ! -f "ssh_keys/barman_rsa.pub" ]; then
    echo -e "${RED}ERROR: SSH keys not found!${NC}"
    echo "Please run: ./scripts/setup_ssh_keys.sh"
    exit 1
fi

# Check if containers are running
if ! docker ps --format '{{.Names}}' | grep -q "^barman$"; then
    echo -e "${RED}ERROR: Barman container is not running!${NC}"
    echo "Please start the stack with: docker-compose up -d"
    exit 1
fi

# Test SSH from each Patroni node
NODES=("db1" "db2" "db3" "db4")
SUCCESS_COUNT=0
FAIL_COUNT=0

for node in "${NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        echo -e "${YELLOW}⚠ ${node}: Container not running, skipping${NC}"
        ((FAIL_COUNT++))
        continue
    fi
    
    echo -e "${YELLOW}Testing SSH from ${node} to barman...${NC}"
    
    # Test SSH connection
    SSH_OUTPUT=$(docker exec ${node} sh -c "ssh -i /home/postgres/.ssh/barman_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 barman@barman 'echo SSH connection successful' 2>&1" 2>&1)
    SSH_EXIT_CODE=$?
    
    if [ $SSH_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: SSH connection successful${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ ${node}: SSH connection failed${NC}"
        echo "  Error: $SSH_OUTPUT" | head -3
        ((FAIL_COUNT++))
    fi
    echo ""
done

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Successful: ${GREEN}${SUCCESS_COUNT}${NC}"
echo -e "Failed: ${RED}${FAIL_COUNT}${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All SSH connections successful!${NC}"
    exit 0
else
    echo -e "${RED}Some SSH connections failed.${NC}"
    exit 1
fi

