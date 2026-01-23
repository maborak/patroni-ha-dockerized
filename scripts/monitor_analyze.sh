#!/bin/bash

# Script to monitor ANALYZE progress in PostgreSQL
# Uses pg_stat_progress_analyze (PostgreSQL 13+)

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Load environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}
REFRESH_INTERVAL=${2:-2}

# If node is specified, use it; otherwise detect leader
if [ -n "$1" ]; then
    DEFAULT_NODE="$1"
    echo -e "${CYAN}Using specified node: ${DEFAULT_NODE}${NC}" >&2
else
    # Auto-detect leader
    echo -e "${YELLOW}Auto-detecting cluster leader...${NC}" >&2
    DEFAULT_NODE=""
    
    # Try to find the leader using patronictl
    PATRONI_LIST=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
    if [ -n "$PATRONI_LIST" ]; then
        # Extract leader from patronictl output (format: | db3 | db3:5431 | Leader | running |)
        DEFAULT_NODE=$(echo "$PATRONI_LIST" | grep -i "Leader" | awk '{print $2}' | head -1)
        if [ -n "$DEFAULT_NODE" ]; then
            echo -e "${GREEN}✓ Found leader: ${DEFAULT_NODE}${NC}" >&2
        fi
    fi
    
    # Fallback: Try REST API
    if [ -z "$DEFAULT_NODE" ]; then
        for node in db1 db2 db3 db4; do
            role=$(docker exec "$node" sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
            if [ "$role" = "primary" ] || [ "$role" = "Leader" ]; then
                DEFAULT_NODE="$node"
                echo -e "${GREEN}✓ Found leader via REST API: ${DEFAULT_NODE}${NC}" >&2
                break
            fi
        done
    fi
    
    # Final fallback
    if [ -z "$DEFAULT_NODE" ]; then
        echo -e "${YELLOW}⚠ Warning: Could not detect leader, defaulting to db1${NC}" >&2
        echo -e "${CYAN}  Tip: Specify node manually: bash scripts/monitor_analyze.sh db3${NC}" >&2
        DEFAULT_NODE="db1"
    fi
    echo "" >&2
fi

# Function to run SQL query
run_query() {
    local query=$1
    docker exec "$DEFAULT_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -t -A -c "$query" 2>/dev/null
}

echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  ANALYZE Progress Monitor${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Connection Details:${NC}"
echo -e "  ${BOLD}Host/Container:${NC} ${DEFAULT_NODE} ${YELLOW}(auto-detected leader)${NC}"
echo -e "  ${BOLD}Database:${NC} ${DEFAULT_DATABASE}"
echo -e "  ${BOLD}Port:${NC} 5431"
echo -e "  ${BOLD}Connection String:${NC} docker exec ${DEFAULT_NODE} psql -U postgres -d ${DEFAULT_DATABASE} -p 5431 -h localhost"
echo ""
echo -e "${CYAN}Monitor Settings:${NC}"
echo -e "  ${BOLD}Refresh interval:${NC} ${REFRESH_INTERVAL} seconds"
echo -e "  ${BOLD}Press Ctrl+C to stop monitoring${NC}"
echo -e "  ${CYAN}Tip:${NC} To monitor a specific node: bash scripts/monitor_analyze.sh <node> <interval>"
echo ""

# Check if pg_stat_progress_analyze exists
if ! run_query "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'pg_stat_progress_analyze');" | grep -q "t"; then
    echo -e "${RED}Error: pg_stat_progress_analyze is not available (requires PostgreSQL 13+)${NC}"
    exit 1
fi

# Monitor loop
while true; do
    clear
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  ANALYZE Progress Monitor${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${CYAN}Host/Container:${NC} ${DEFAULT_NODE}"
    echo -e "${CYAN}Database:${NC} ${DEFAULT_DATABASE}"
    echo -e "${CYAN}Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Check if ANALYZE is running
    ANALYZE_COUNT=$(run_query "SELECT COUNT(*) FROM pg_stat_progress_analyze;" | tr -d ' ')
    
    if [ "$ANALYZE_COUNT" = "0" ] || [ -z "$ANALYZE_COUNT" ]; then
        echo -e "${YELLOW}No ANALYZE operations currently running${NC}"
        echo ""
        echo -e "${CYAN}To start ANALYZE, run:${NC}"
        echo -e "  docker exec ${DEFAULT_NODE} psql -U postgres -d ${DEFAULT_DATABASE} -p 5431 -h localhost -c \"ANALYZE;\""
        echo ""
    else
        # Show detailed progress
        docker exec "$DEFAULT_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -c "
            SELECT 
                pid,
                datname as \"Database\",
                relid::regclass as \"Table\",
                phase as \"Phase\",
                CASE 
                    WHEN sample_blks_total > 0 THEN 
                        ROUND(100.0 * sample_blks_scanned / sample_blks_total, 2)
                    ELSE 0
                END as \"Progress %\",
                sample_blks_scanned || '/' || sample_blks_total as \"Blocks\",
                CASE 
                    WHEN child_tables_total > 0 THEN 
                        child_tables_done || '/' || child_tables_total
                    ELSE '-'
                END as \"Child Tables\"
            FROM pg_stat_progress_analyze
            ORDER BY pid;
        " 2>/dev/null
        
        echo ""
        echo -e "${CYAN}Phase Descriptions:${NC}"
        echo -e "  ${GREEN}initializing${NC} - Preparing to begin scanning"
        echo -e "  ${GREEN}acquiring sample rows${NC} - Scanning table for sample rows"
        echo -e "  ${GREEN}acquiring inherited sample rows${NC} - Scanning child tables"
        echo -e "  ${GREEN}computing statistics${NC} - Calculating statistics from samples"
        echo -e "  ${GREEN}computing extended statistics${NC} - Calculating extended statistics"
        echo -e "  ${GREEN}finalizing analyze${NC} - Updating system catalogs"
        echo ""
    fi
    
    # Show recent ANALYZE activity from pg_stat_user_tables
    echo -e "${BLUE}${BOLD}Recent Statistics Updates:${NC}"
    docker exec "$DEFAULT_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -c "
        SELECT 
            schemaname as \"Schema\",
            relname as \"Table\",
            CASE 
                WHEN last_analyze IS NOT NULL THEN 
                    last_analyze::text
                WHEN last_autoanalyze IS NOT NULL THEN 
                    last_autoanalyze::text || ' (auto)'
                ELSE 'Never'
            END as \"Last Analyzed\",
            n_live_tup as \"Rows\"
        FROM pg_stat_user_tables
        WHERE schemaname = 'public'
        ORDER BY 
            COALESCE(last_analyze, last_autoanalyze, '1970-01-01'::timestamp) DESC
        LIMIT 10;
    " 2>/dev/null
    
    echo ""
    echo -e "${CYAN}Refreshing in ${REFRESH_INTERVAL} seconds... (Ctrl+C to stop)${NC}"
    sleep "$REFRESH_INTERVAL"
done

