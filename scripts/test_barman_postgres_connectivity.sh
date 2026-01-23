#!/bin/bash
# Test Barman connectivity to PostgreSQL nodes

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
echo -e "${BLUE}  Testing Barman PostgreSQL Connectivity${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if barman container is running
if ! docker ps --format '{{.Names}}' | grep -q "^barman$"; then
    echo -e "${RED}ERROR: Barman container is not running!${NC}"
    echo "Please start the stack with: docker-compose up -d"
    exit 1
fi

# Check .pgpass file
echo -e "${YELLOW}Checking .pgpass file...${NC}"
BARMAN_HOME=$(docker exec barman getent passwd barman | cut -d: -f6)
if [ -z "$BARMAN_HOME" ]; then
    BARMAN_HOME="/var/lib/barman"
fi

if docker exec barman test -f "$BARMAN_HOME/.pgpass" 2>/dev/null; then
    echo -e "${GREEN}✓ .pgpass file exists at $BARMAN_HOME/.pgpass${NC}"
    echo -e "${YELLOW}Contents:${NC}"
    docker exec barman cat "$BARMAN_HOME/.pgpass" 2>/dev/null | sed 's/^/  /'
    PGPASS_PERMS=$(docker exec barman stat -c "%a" "$BARMAN_HOME/.pgpass" 2>/dev/null || docker exec barman ls -l "$BARMAN_HOME/.pgpass" 2>/dev/null | awk '{print $1}')
    if [ "$PGPASS_PERMS" == "600" ] || echo "$PGPASS_PERMS" | grep -q "^-rw-------"; then
        echo -e "${GREEN}✓ .pgpass permissions are correct (600)${NC}"
    else
        echo -e "${YELLOW}⚠ .pgpass permissions: $PGPASS_PERMS (expected 600)${NC}"
    fi
else
    echo -e "${RED}✗ .pgpass file not found at $BARMAN_HOME/.pgpass${NC}"
fi
echo ""

# Test connections to each PostgreSQL node
NODES=("db1" "db2" "db3" "db4")
SUCCESS_COUNT=0
FAIL_COUNT=0

for node in "${NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        echo -e "${YELLOW}⚠ ${node}: Container not running, skipping${NC}"
        ((FAIL_COUNT++))
        continue
    fi
    
    echo -e "${YELLOW}Testing connection to ${node}...${NC}"
    
    # Test psql connection (run as barman user to use .pgpass)
    CONNECTION_TEST=$(docker exec -u barman barman psql -h "$node" -p 5431 -U postgres -d postgres -c "SELECT version();" 2>&1)
    CONNECTION_EXIT_CODE=$?
    
    if [ $CONNECTION_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: Connection successful${NC}"
        PG_VERSION=$(echo "$CONNECTION_TEST" | grep -i "PostgreSQL" | head -1 | sed 's/^[[:space:]]*//')
        if [ -n "$PG_VERSION" ]; then
            echo "  Version: ${PG_VERSION:0:50}..."
        fi
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ ${node}: Connection failed${NC}"
        echo "  Error: $(echo "$CONNECTION_TEST" | head -3 | sed 's/^/    /')"
        ((FAIL_COUNT++))
    fi
    echo ""
done

# Test barman check command for each server
echo -e "${YELLOW}Testing Barman check commands...${NC}"
for node in "${NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        continue
    fi
    
    echo -e "${YELLOW}Running 'barman check ${node}'...${NC}"
    BARMAN_CHECK=$(docker exec barman barman check "$node" 2>&1)
    BARMAN_EXIT_CODE=$?
    
    if [ $BARMAN_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: Barman check passed${NC}"
        echo "$BARMAN_CHECK" | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠ ${node}: Barman check issues (this is normal if no backups exist yet)${NC}"
        echo "$BARMAN_CHECK" | head -5 | sed 's/^/  /'
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
    echo -e "${GREEN}All PostgreSQL connections successful!${NC}"
    exit 0
else
    echo -e "${RED}Some PostgreSQL connections failed.${NC}"
    exit 1
fi

