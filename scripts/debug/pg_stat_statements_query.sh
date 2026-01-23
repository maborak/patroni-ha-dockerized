#!/bin/bash

# Script to query pg_stat_statements for query performance analysis
# Usage: ./pg_stat_statements_query.sh [options]
#
# Options:
#   --node <node>        Target specific node (db1, db2, db3, db4)
#   --top <n>            Show top N queries (default: 10)
#   --sort <field>       Sort by: calls, total_time, mean_time, max_time (default: total_time)
#   --min-calls <n>      Minimum number of calls to include (default: 1)
#   --format <format>    Output format: table, csv, json (default: table)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Default values
TARGET_NODE=""
TOP_N=10
SORT_BY="total_time"
MIN_CALLS=1
OUTPUT_FORMAT="table"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --top)
            TOP_N="$2"
            shift 2
            ;;
        --sort)
            SORT_BY="$2"
            if [[ ! "$SORT_BY" =~ ^(calls|total_time|mean_time|max_time)$ ]]; then
                echo -e "${RED}Invalid sort field: $SORT_BY${NC}"
                echo -e "${YELLOW}Valid fields: calls, total_time, mean_time, max_time${NC}"
                exit 1
            fi
            shift 2
            ;;
        --min-calls)
            MIN_CALLS="$2"
            shift 2
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            if [[ ! "$OUTPUT_FORMAT" =~ ^(table|csv|json)$ ]]; then
                echo -e "${RED}Invalid format: $OUTPUT_FORMAT${NC}"
                echo -e "${YELLOW}Valid formats: table, csv, json${NC}"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "pg_stat_statements - Query performance analysis"
            echo ""
            echo "Options:"
            echo "  --node <node>        Target specific node (db1, db2, db3, db4)"
            echo "  --top <n>            Show top N queries (default: 10)"
            echo "  --sort <field>       Sort by: calls, total_time, mean_time, max_time (default: total_time)"
            echo "  --min-calls <n>      Minimum number of calls to include (default: 1)"
            echo "  --format <format>    Output format: table, csv, json (default: table)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Top 10 queries by total time"
            echo "  $0 --node db2 --top 20               # Top 20 queries on db2"
            echo "  $0 --sort mean_time --top 5          # Top 5 by mean execution time"
            echo "  $0 --min-calls 100 --format csv      # Queries with 100+ calls, CSV format"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            exit 1
            ;;
    esac
done

# Function to find leader node
find_leader() {
    local leader=""
    PATRONI_LIST=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
    if [ -n "$PATRONI_LIST" ]; then
        leader=$(echo "$PATRONI_LIST" | grep -i "Leader" | awk '{print $2}' | head -1)
    fi
    echo "$leader"
}

# Determine target node
if [ -z "$TARGET_NODE" ]; then
    LEADER=$(find_leader)
    if [ -z "$LEADER" ]; then
        echo -e "${YELLOW}Could not determine leader, using db1${NC}"
        LEADER="db1"
    fi
    TARGET_NODE="$LEADER"
fi

if [[ ! "$TARGET_NODE" =~ ^db[1-4]$ ]]; then
    echo -e "${RED}Invalid node: $TARGET_NODE${NC}"
    echo -e "${YELLOW}Valid nodes: db1, db2, db3, db4${NC}"
    exit 1
fi

# Check if pg_stat_statements extension is enabled
echo -e "${CYAN}Checking pg_stat_statements extension...${NC}"
EXTENSION_CHECK=$(docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -t -A -c "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements');" 2>/dev/null | tr -d ' ')

if [ "$EXTENSION_CHECK" != "t" ]; then
    echo -e "${YELLOW}pg_stat_statements extension not enabled${NC}"
    echo -e "${CYAN}Enabling extension...${NC}"
    docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 || {
        echo -e "${RED}Failed to enable pg_stat_statements${NC}"
        echo -e "${YELLOW}You may need to add it to shared_preload_libraries in postgresql.conf${NC}"
        exit 1
    }
fi

# Build SQL query based on sort field
case $SORT_BY in
    calls)
        ORDER_BY="calls DESC"
        ;;
    total_time)
        ORDER_BY="total_exec_time DESC"
        ;;
    mean_time)
        ORDER_BY="(total_exec_time / NULLIF(calls, 0)) DESC"
        ;;
    max_time)
        ORDER_BY="max_exec_time DESC"
        ;;
esac

# Build query
QUERY="
SELECT 
    LEFT(query, 80) as query_preview,
    calls,
    ROUND(total_exec_time::numeric, 2) as total_time_ms,
    ROUND((total_exec_time / NULLIF(calls, 0))::numeric, 2) as mean_time_ms,
    ROUND(max_exec_time::numeric, 2) as max_time_ms,
    ROUND((100.0 * total_exec_time / SUM(total_exec_time) OVER ())::numeric, 2) as pct_total_time
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
ORDER BY $ORDER_BY
LIMIT $TOP_N;
"

# Display header
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  pg_stat_statements Query Analysis${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Target Node:${NC} ${BOLD}${TARGET_NODE}${NC}"
echo -e "${CYAN}Top Queries:${NC} ${BOLD}${TOP_N}${NC}"
echo -e "${CYAN}Sort By:${NC} ${BOLD}${SORT_BY}${NC}"
echo -e "${CYAN}Min Calls:${NC} ${BOLD}${MIN_CALLS}${NC}"
echo ""

# Execute query based on format
case $OUTPUT_FORMAT in
    table)
        docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -c "$QUERY"
        ;;
    csv)
        docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -c "COPY ($QUERY) TO STDOUT WITH CSV HEADER;"
        ;;
    json)
        docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -t -A -c "SELECT json_agg(row_to_json(t)) FROM ($QUERY) t;" | jq '.' 2>/dev/null || docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -t -A -c "SELECT json_agg(row_to_json(t)) FROM ($QUERY) t;"
        ;;
esac

echo ""

