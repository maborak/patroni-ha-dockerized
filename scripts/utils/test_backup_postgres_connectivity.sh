#!/bin/bash
# Test Backup connectivity to PostgreSQL nodes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
cd "$SCRIPT_DIR/../"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Testing Backup PostgreSQL Connectivity${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if backup container is running
if ! docker ps --format '{{.Names}}' | grep -q "^backup$"; then
    echo -e "${RED}ERROR: Backup container is not running!${NC}"
    echo "Please start the stack with: docker-compose up -d"
    exit 1
fi

# Check .pgpass file
echo -e "${YELLOW}Checking .pgpass file...${NC}"
BARMAN_HOME=$(docker exec backup getent passwd backup | cut -d: -f6)
if [ -z "$BARMAN_HOME" ]; then
    BARMAN_HOME="/var/lib/backup"
fi

if docker exec backup test -f "$BARMAN_HOME/.pgpass" 2>/dev/null; then
    echo -e "${GREEN}✓ .pgpass file exists at $BARMAN_HOME/.pgpass${NC}"
    echo -e "${YELLOW}Contents:${NC}"
    docker exec backup cat "$BARMAN_HOME/.pgpass" 2>/dev/null | sed 's/^/  /'
    PGPASS_PERMS=$(docker exec backup stat -c "%a" "$BARMAN_HOME/.pgpass" 2>/dev/null || docker exec backup ls -l "$BARMAN_HOME/.pgpass" 2>/dev/null | awk '{print $1}')
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
DB_NODES=($(get_db_nodes))
SUCCESS_COUNT=0
FAIL_COUNT=0

for node in "${DB_NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        echo -e "${YELLOW}⚠ ${node}: Container not running, skipping${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    
    echo -e "${YELLOW}Testing connection to ${node}...${NC}"
    
    # Test psql connection (run as backup user to use .pgpass)
    CONNECTION_TEST=$(docker exec -u backup backup psql -h "$node" -p 5431 -U postgres -d postgres -c "SELECT version();" 2>&1)
    CONNECTION_EXIT_CODE=$?
    
    if [ $CONNECTION_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: Connection successful${NC}"
        PG_VERSION=$(echo "$CONNECTION_TEST" | grep -i "PostgreSQL" | head -1 | sed 's/^[[:space:]]*//')
        if [ -n "$PG_VERSION" ]; then
            echo "  Version: ${PG_VERSION:0:50}..."
        fi
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}✗ ${node}: Connection failed${NC}"
        echo "  Error: $(echo "$CONNECTION_TEST" | head -3 | sed 's/^/    /')"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    echo ""
done

# Test barman check command for each server
echo -e "${YELLOW}Testing Backup check commands...${NC}"
for node in "${DB_NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        continue
    fi
    
    echo -e "${YELLOW}Running 'barman check ${node}'...${NC}"
    BARMAN_CHECK=$(docker exec backup barman check "$node" 2>&1)
    BARMAN_EXIT_CODE=$?
    
    if [ $BARMAN_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ ${node}: Backup check passed${NC}"
        echo "$BARMAN_CHECK" | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠ ${node}: Backup check issues (this is normal if no backups exist yet)${NC}"
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

