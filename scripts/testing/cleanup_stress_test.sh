#!/bin/bash
# Cleanup script for stress test data

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../"

# Load environment variables
if [ -f .env ]; then
    source .env
fi

# Configuration
DB_HOST_IP="localhost"
DB_PORT="${HAPROXY_WRITE_PORT:-5551}"
DB_NAME="${DEFAULT_DATABASE:-maborak}"
DB_USER="postgres"
DB_PASSWORD="${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Cleaning Up Stress Test Data${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if database is accessible via HAProxy (write port routes to leader)
echo -e "${YELLOW}Checking database connectivity via HAProxy (write port ${DB_PORT})...${NC}"
CONNECTION_STRING="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST_IP}:${DB_PORT}/${DB_NAME}"

# Test connection with better error reporting
CONNECTION_OUTPUT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" 2>&1)
CONNECTION_EXIT=$?

if [ $CONNECTION_EXIT -ne 0 ]; then
    echo -e "${RED}ERROR: Cannot connect to database via HAProxy!${NC}"
    echo -e "${YELLOW}  Connection string: postgresql://${DB_USER}@${DB_HOST_IP}:${DB_PORT}/${DB_NAME}${NC}"
    echo -e "${YELLOW}  Error output:${NC}"
    echo "$CONNECTION_OUTPUT" | sed 's/^/    /'
    echo -e "${YELLOW}  Make sure HAProxy is running and the write port is accessible.${NC}"
    echo -e "${YELLOW}  Test manually with: psql '${CONNECTION_STRING}'${NC}"
    exit 1
fi

# Verify we're connected to the leader
echo -e "${YELLOW}Verifying connection to leader...${NC}"
IS_LEADER=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
if [ "$IS_LEADER" = "f" ]; then
    echo -e "${GREEN}✓ Connected to leader (not in recovery)${NC}"
else
    echo -e "${RED}ERROR: Connected to a replica, not the leader!${NC}"
    echo -e "${YELLOW}  HAProxy write port should route to the leader.${NC}"
    echo -e "${YELLOW}  pg_is_in_recovery() returned: ${IS_LEADER}${NC}"
    exit 1
fi
echo ""

# Get list of stress test tables
echo -e "${YELLOW}Finding stress test tables...${NC}"
TABLES=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'stress_table_%' ORDER BY table_name;" | tr -d ' ' | tr '\n' ',' | sed 's/,$//')

if [ -z "$TABLES" ]; then
    echo -e "${YELLOW}No stress test tables found.${NC}"
    exit 0
fi

TABLE_COUNT=$(echo "$TABLES" | tr ',' '\n' | wc -l | tr -d ' ')
echo -e "Found ${GREEN}${TABLE_COUNT}${NC} stress test tables"
echo ""

# Confirm deletion
read -p "Are you sure you want to delete all stress test tables? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}Cleanup cancelled.${NC}"
    exit 0
fi

# Drop tables
echo -e "${YELLOW}Dropping tables...${NC}"
PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" <<EOF
DROP TABLE IF EXISTS $(echo "$TABLES" | sed 's/,/, /g') CASCADE;
EOF

echo -e "${GREEN}✓ All stress test tables dropped${NC}"
echo ""

# Verify cleanup
REMAINING=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'stress_table_%';" | tr -d ' ')

if [ "$REMAINING" -eq 0 ]; then
    echo -e "${GREEN}Cleanup completed successfully!${NC}"
else
    echo -e "${YELLOW}Warning: ${REMAINING} tables still remain.${NC}"
fi

