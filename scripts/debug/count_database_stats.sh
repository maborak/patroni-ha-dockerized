#!/bin/bash

# Script to count tables, columns, and rows in the database cluster
# Useful for verifying data before/after PITR

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
cd "$SCRIPT_DIR/.."

# Determine which node to connect to (prefer leader)
echo -e "${YELLOW}Detecting cluster leader...${NC}" >&2
LEADER_NODE=$(detect_leader)
if [ -z "$LEADER_NODE" ]; then
    echo -e "${YELLOW}⚠ Warning: Could not detect leader, defaulting to db1${NC}" >&2
    LEADER_NODE="db1"
else
    echo -e "${GREEN}✓ Found leader: ${LEADER_NODE}${NC}" >&2
fi
LEADER_PORT=$(get_db_port "$(get_node_num "$LEADER_NODE")")
echo "" >&2

# Function to run SQL query on a specific database
run_query() {
    local db=$1
    local query=$2
    docker exec "$LEADER_NODE" psql -U postgres -d "$db" -p 5431 -h localhost -t -A -c "$query" 2>/dev/null | tr -d ' '
}

# Function to run SQL query on postgres database (for cluster-wide queries)
run_query_postgres() {
    local query=$1
    docker exec "$LEADER_NODE" psql -U postgres -d postgres -p 5431 -h localhost -t -A -c "$query" 2>/dev/null | tr -d ' '
}

# Get list of all databases excluding internal ones
echo -e "${YELLOW}Discovering databases...${NC}" >&2
DATABASES=$(run_query_postgres "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') AND datname NOT LIKE 'pg_%' ORDER BY datname;" 2>/dev/null)

if [ -z "$DATABASES" ]; then
    echo -e "${RED}Error: No databases found (excluding internal databases)${NC}" >&2
    exit 1
fi

DB_COUNT=$(echo "$DATABASES" | grep -v '^$' | wc -l | tr -d ' ')
echo -e "${GREEN}✓ Found ${DB_COUNT} database(s)${NC}" >&2
echo "" >&2

echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  Database Statistics Report${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Connection Details:${NC}"
echo -e "  ${BOLD}Host/Container:${NC} ${LEADER_NODE} ${GREEN}(cluster leader)${NC}"
echo -e "  ${BOLD}Port:${NC} ${LEADER_PORT}"
echo -e "  ${BOLD}Databases:${NC} ${DB_COUNT} (excluding internal databases)"
echo ""
echo -e "${CYAN}Timestamp:${NC} $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo ""

# Initialize totals
TOTAL_TABLES_ALL=0
TOTAL_COLUMNS_ALL=0
TOTAL_ROWS_ALL=0
TOTAL_SIZE_ALL=0

# Check if cluster is in recovery mode (ANALYZE cannot run during recovery)
IS_RECOVERY=$(run_query_postgres "SELECT pg_is_in_recovery();")
if [ "$IS_RECOVERY" = "f" ] || [ "$IS_RECOVERY" = "false" ]; then
    echo -e "${YELLOW}Updating statistics for all databases (this may take a moment)...${NC}"
    echo -e "${CYAN}Note: Run 'bash scripts/debug/monitor_analyze.sh' in another terminal to see progress${NC}"
    echo ""
    # Run ANALYZE on all databases
    for db in $DATABASES; do
        if [ -n "$db" ]; then
            echo -e "${CYAN}Analyzing database: ${db}...${NC}"
            docker exec "$LEADER_NODE" psql -U postgres -d "$db" -p 5431 -h localhost -c "ANALYZE VERBOSE;" 2>&1 | head -10
        fi
    done
    echo ""
    echo -e "${GREEN}✓ Statistics updated for all databases${NC}"
    echo ""
else
    echo -e "${YELLOW}Cluster is in recovery mode, skipping ANALYZE (not allowed during recovery)${NC}"
    echo -e "${CYAN}Recovery status:${NC} Cluster is still recovering"
    echo -e "${CYAN}Note:${NC} ANALYZE will run automatically after recovery completes, or you can run it manually"
    echo ""
fi

# Process each database
DB_JSON_ARRAY=""
FIRST_DB=true

for db in $DATABASES; do
    if [ -z "$db" ]; then
        continue
    fi
    
    echo -e "${BLUE}${BOLD}----------------------------------------${NC}"
    echo -e "${BLUE}${BOLD}  Database: ${db}${NC}"
    echo -e "${BLUE}${BOLD}----------------------------------------${NC}"
    echo ""
    
    # Count tables (all schemas, not just public)
    TOTAL_TABLES=$(run_query "$db" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE';")
    
    # Count columns (all schemas)
    TOTAL_COLUMNS=$(run_query "$db" "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog', 'information_schema');")
    
    # Count total rows using pg_stat_user_tables (all schemas)
    TOTAL_ROWS=$(run_query "$db" "SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');")
    
    # If statistics show 0, try pg_class.reltuples (faster estimate)
    if [ "$TOTAL_ROWS" = "0" ] || [ -z "$TOTAL_ROWS" ]; then
        TOTAL_ROWS=$(run_query "$db" "SELECT COALESCE(SUM(reltuples::BIGINT), 0) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind = 'r';")
    fi
    
    # If still 0, use actual COUNT queries (slower but accurate) - but only for small databases
    if [ "$TOTAL_ROWS" = "0" ] || [ -z "$TOTAL_ROWS" ]; then
        # Only do direct count if database is small (< 100 tables)
        TABLE_COUNT_CHECK=$(run_query "$db" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE';")
        if [ "$TABLE_COUNT_CHECK" -lt 100 ]; then
            TOTAL_ROWS=0
            TABLES=$(docker exec "$LEADER_NODE" psql -U postgres -d "$db" -p 5431 -h localhost -t -A -c "SELECT schemaname||'.'||tablename FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE' ORDER BY schemaname, tablename;" 2>/dev/null)
            for table in $TABLES; do
                if [ -n "$table" ]; then
                    count=$(run_query "$db" "SELECT COUNT(*) FROM ${table};" 2>/dev/null || echo "0")
                    TOTAL_ROWS=$((TOTAL_ROWS + count))
                fi
            done
        fi
    fi
    
    # Get database size
    DB_SIZE_RAW=$(run_query "$db" "SELECT pg_database_size('${db}');")
    DB_SIZE=$(run_query "$db" "SELECT pg_size_pretty(pg_database_size('${db}'));")
    
    # Accumulate totals
    TOTAL_TABLES_ALL=$((TOTAL_TABLES_ALL + TOTAL_TABLES))
    TOTAL_COLUMNS_ALL=$((TOTAL_COLUMNS_ALL + TOTAL_COLUMNS))
    TOTAL_ROWS_ALL=$((TOTAL_ROWS_ALL + TOTAL_ROWS))
    TOTAL_SIZE_ALL=$((TOTAL_SIZE_ALL + DB_SIZE_RAW))
    
    echo -e "${GREEN}  Tables:${NC} ${BOLD}${TOTAL_TABLES}${NC}"
    echo -e "${GREEN}  Columns:${NC} ${BOLD}${TOTAL_COLUMNS}${NC}"
    echo -e "${GREEN}  Total Rows:${NC} ${BOLD}${TOTAL_ROWS}${NC}"
    echo -e "${GREEN}  Database Size:${NC} ${BOLD}${DB_SIZE}${NC}"
    echo ""
    
    # Build JSON array
    if [ "$FIRST_DB" = true ]; then
        DB_JSON_ARRAY="    {\"name\": \"${db}\", \"tables\": ${TOTAL_TABLES}, \"columns\": ${TOTAL_COLUMNS}, \"rows\": ${TOTAL_ROWS}, \"size\": \"${DB_SIZE}\", \"size_bytes\": ${DB_SIZE_RAW}}"
        FIRST_DB=false
    else
        DB_JSON_ARRAY="${DB_JSON_ARRAY},
    {\"name\": \"${db}\", \"tables\": ${TOTAL_TABLES}, \"columns\": ${TOTAL_COLUMNS}, \"rows\": ${TOTAL_ROWS}, \"size\": \"${DB_SIZE}\", \"size_bytes\": ${DB_SIZE_RAW}}"
    fi
done

# Calculate total size (format bytes to human-readable)
# Use PostgreSQL to format the size
TOTAL_SIZE_PRETTY=$(docker exec "$LEADER_NODE" psql -U postgres -d postgres -p 5431 -h localhost -t -A -c "SELECT pg_size_pretty(${TOTAL_SIZE_ALL});" 2>/dev/null | tr -d ' ')

echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  Cluster Summary${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Total Databases:${NC} ${BOLD}${DB_COUNT}${NC}"
echo -e "${CYAN}Total Tables:${NC} ${BOLD}${TOTAL_TABLES_ALL}${NC}"
echo -e "${CYAN}Total Columns:${NC} ${BOLD}${TOTAL_COLUMNS_ALL}${NC}"
echo -e "${CYAN}Total Rows:${NC} ${BOLD}${TOTAL_ROWS_ALL}${NC}"
echo -e "${CYAN}Total Size:${NC} ${BOLD}${TOTAL_SIZE_PRETTY}${NC}"
echo ""
echo -e "${CYAN}Save this information for PITR verification!${NC}"
echo ""

# Generate JSON output for easy comparison
OUTPUT_FILE="./db_stats_before_pitr_$(date +%Y%m%d_%H%M%S).json"
cat <<EOF > "$OUTPUT_FILE"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "node": "${LEADER_NODE}",
  "cluster_statistics": {
    "total_databases": ${DB_COUNT},
    "total_tables": ${TOTAL_TABLES_ALL},
    "total_columns": ${TOTAL_COLUMNS_ALL},
    "total_rows": ${TOTAL_ROWS_ALL},
    "total_size": "${TOTAL_SIZE_PRETTY}",
    "total_size_bytes": ${TOTAL_SIZE_ALL}
  },
  "databases": [
${DB_JSON_ARRAY}
  ]
}
EOF

echo -e "${YELLOW}Use this file to verify your PITR recovery!${NC}"
echo ""

