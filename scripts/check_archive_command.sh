#!/bin/bash
# Check if archive_command is running on the master node

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
echo -e "${BLUE}  Checking Archive Command on Master${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Get the leader node
LEADER=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>&1 | grep Leader | awk '{print $2}')

if [ -z "$LEADER" ]; then
    echo -e "${RED}ERROR: Could not determine leader node${NC}"
    exit 1
fi

echo -e "${GREEN}Current Leader: ${LEADER}${NC}"
echo ""

# Check archive_mode
echo -e "${YELLOW}Checking archive_mode...${NC}"
ARCHIVE_MODE=$(docker exec $LEADER psql -h localhost -p 5431 -U postgres -d postgres -t -c "SHOW archive_mode;" 2>&1 | tr -d ' ')
if [ "$ARCHIVE_MODE" == "on" ]; then
    echo -e "${GREEN}✓ archive_mode: on${NC}"
else
    echo -e "${RED}✗ archive_mode: $ARCHIVE_MODE (expected: on)${NC}"
fi
echo ""

# Check archive_command
echo -e "${YELLOW}Checking archive_command...${NC}"
ARCHIVE_CMD=$(docker exec $LEADER psql -h localhost -p 5431 -U postgres -d postgres -t -c "SHOW archive_command;" 2>&1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -n "$ARCHIVE_CMD" ] && [ "$ARCHIVE_CMD" != "(disabled)" ]; then
    echo -e "${GREEN}✓ archive_command is set${NC}"
    echo "  Command: ${ARCHIVE_CMD:0:80}..."
else
    echo -e "${RED}✗ archive_command is not set or disabled${NC}"
fi
echo ""

# Check archive log
echo -e "${YELLOW}Checking archive log...${NC}"
ARCHIVE_LOG_LINES=0
if docker exec $LEADER test -f /var/log/postgresql/archive.log 2>/dev/null; then
    ARCHIVE_LOG_LINES=$(docker exec $LEADER wc -l < /var/log/postgresql/archive.log 2>/dev/null | tr -d ' ' || echo "0")
    if [ -z "$ARCHIVE_LOG_LINES" ]; then
        ARCHIVE_LOG_LINES=0
    fi
    if [ "$ARCHIVE_LOG_LINES" -gt 0 ]; then
        echo -e "${GREEN}✓ Archive log exists with $ARCHIVE_LOG_LINES lines${NC}"
        echo -e "${YELLOW}Last 5 archive log entries:${NC}"
        docker exec $LEADER tail -5 /var/log/postgresql/archive.log 2>&1 | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠ Archive log exists but is empty${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Archive log file not found${NC}"
fi
echo ""

# Check Barman backup directory
echo -e "${YELLOW}Checking Barman backup directory...${NC}"
BARMAN_DIR="/data/pg-backup/$LEADER/incoming"
WAL_COUNT=0
if docker exec barman test -d "$BARMAN_DIR" 2>/dev/null; then
    WAL_COUNT=$(docker exec barman ls -1 "$BARMAN_DIR" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ -z "$WAL_COUNT" ]; then
        WAL_COUNT=0
    fi
    if [ "$WAL_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Barman directory exists with $WAL_COUNT WAL files${NC}"
        echo -e "${YELLOW}Recent WAL files:${NC}"
        docker exec barman ls -lht "$BARMAN_DIR" 2>/dev/null | head -5 | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠ Barman directory exists but is empty${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Barman directory does not exist: $BARMAN_DIR${NC}"
fi
echo ""

# Test archive by switching WAL
echo -e "${YELLOW}Testing archive by switching WAL...${NC}"
echo "  Executing pg_switch_wal()..."
SWITCH_OUTPUT=$(docker exec $LEADER psql -h localhost -p 5431 -U postgres -d postgres -t -c "SELECT pg_switch_wal();" 2>&1)
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ WAL switch successful${NC}"
    echo "  Waiting 3 seconds for archive_command to execute..."
    sleep 3
    
    # Check archive log for new entry
    NEW_LOG_ENTRIES=$(docker exec $LEADER tail -3 /var/log/postgresql/archive.log 2>&1 | grep -c "Archived:" || echo "0")
    NEW_LOG_ENTRIES=$(echo "$NEW_LOG_ENTRIES" | tr -d ' \n\r' || echo "0")
    if [ -z "$NEW_LOG_ENTRIES" ]; then
        NEW_LOG_ENTRIES=0
    fi
    # Ensure it's an integer for comparison
    NEW_LOG_ENTRIES=$((NEW_LOG_ENTRIES + 0))
    if [ "$NEW_LOG_ENTRIES" -gt 0 ]; then
        echo -e "${GREEN}✓ Archive command executed (found $NEW_LOG_ENTRIES new archive entries)${NC}"
        docker exec $LEADER tail -3 /var/log/postgresql/archive.log 2>&1 | sed 's/^/  /'
    else
        echo -e "${YELLOW}⚠ No new archive entries found in log${NC}"
        docker exec $LEADER tail -3 /var/log/postgresql/archive.log 2>&1 | sed 's/^/  /' || echo "  (log file may be empty)"
    fi
    
    # Check if file appeared in Barman
    sleep 1
    NEW_WAL_COUNT=$(docker exec barman ls -1 "$BARMAN_DIR" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
    if [ -z "$NEW_WAL_COUNT" ]; then
        NEW_WAL_COUNT=0
    fi
    if [ -z "$WAL_COUNT" ]; then
        WAL_COUNT=0
    fi
    # Ensure both are integers for comparison
    NEW_WAL_COUNT=$((NEW_WAL_COUNT + 0))
    WAL_COUNT=$((WAL_COUNT + 0))
    if [ "$NEW_WAL_COUNT" -gt "$WAL_COUNT" ]; then
        echo -e "${GREEN}✓ New WAL file appeared in Barman directory${NC}"
    else
        echo -e "${YELLOW}⚠ No new WAL file in Barman directory (count: $WAL_COUNT -> $NEW_WAL_COUNT)${NC}"
    fi
else
    echo -e "${RED}✗ WAL switch failed${NC}"
    echo "  Error: $SWITCH_OUTPUT"
fi
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Leader Node: ${GREEN}${LEADER}${NC}"
echo -e "Archive Mode: ${GREEN}${ARCHIVE_MODE}${NC}"
echo -e "Archive Command: ${GREEN}Configured${NC}"
echo ""

