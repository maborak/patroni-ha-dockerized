#!/bin/bash

# Script to monitor PostgreSQL recovery progress

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
    echo -e "${CYAN}  (Useful for monitoring specific node in recovery, e.g., after PITR)${NC}" >&2
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
        echo -e "${CYAN}  Tip: Specify node manually: bash scripts/monitor_recovery.sh db2${NC}" >&2
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
echo -e "${BLUE}${BOLD}  PostgreSQL Recovery Monitor${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Connection Details:${NC}"
if [ -n "$1" ]; then
    echo -e "  ${BOLD}Host/Container:${NC} ${DEFAULT_NODE} ${YELLOW}(manually specified)${NC}"
else
    echo -e "  ${BOLD}Host/Container:${NC} ${DEFAULT_NODE} ${GREEN}(auto-detected leader)${NC}"
fi
echo -e "  ${BOLD}Database:${NC} ${DEFAULT_DATABASE}"
echo -e "  ${BOLD}Port:${NC} 5431"
echo -e "  ${BOLD}Connection String:${NC} docker exec ${DEFAULT_NODE} psql -U postgres -d ${DEFAULT_DATABASE} -p 5431 -h localhost"
echo ""
echo -e "${CYAN}Monitor Settings:${NC}"
echo -e "  ${BOLD}Refresh interval:${NC} ${REFRESH_INTERVAL} seconds"
echo -e "  ${BOLD}Press Ctrl+C to stop monitoring${NC}"
if [ -z "$1" ]; then
    echo -e "  ${CYAN}Tip:${NC} To monitor a specific node (e.g., after PITR): bash scripts/monitor_recovery.sh <node> <interval>"
fi
echo ""

# Monitor loop
while true; do
    clear
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  PostgreSQL Recovery Monitor${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    if [ -n "$1" ]; then
        echo -e "${CYAN}Host/Container:${NC} ${DEFAULT_NODE} ${YELLOW}(specified)${NC}"
    else
        echo -e "${CYAN}Host/Container:${NC} ${DEFAULT_NODE} ${GREEN}(leader)${NC}"
    fi
    echo -e "${CYAN}Database:${NC} ${DEFAULT_DATABASE}"
    echo -e "${CYAN}Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Check recovery status
    IS_RECOVERY=$(run_query "SELECT pg_is_in_recovery();" | tr -d ' ')
    WAL_LSN=$(run_query "SELECT pg_last_wal_replay_lsn();" | tr -d ' ')
    
    if [ "$IS_RECOVERY" = "f" ] || [ "$IS_RECOVERY" = "false" ]; then
        echo -e "${GREEN}${BOLD}✓ Recovery Complete!${NC}"
        echo ""
        echo -e "${CYAN}Database is no longer in recovery mode.${NC}"
        echo -e "${CYAN}You can now run ANALYZE:${NC}"
        echo -e "  docker exec ${DEFAULT_NODE} psql -U postgres -d ${DEFAULT_DATABASE} -p 5431 -h localhost -c \"ANALYZE;\""
        echo ""
        echo -e "${CYAN}Or run the statistics script:${NC}"
        echo -e "  bash scripts/count_database_stats.sh"
        echo ""
        break
    else
        echo -e "${YELLOW}${BOLD}⏳ Database is in recovery mode${NC}"
        echo ""
        echo -e "${CYAN}Recovery Status:${NC}"
        echo -e "  Last WAL Replay LSN: ${WAL_LSN}"
        echo ""
        
        # Try to get recovery target info if available
        RECOVERY_TARGET=$(run_query "SHOW recovery_target;" 2>/dev/null | tr -d ' ' || echo "N/A")
        if [ "$RECOVERY_TARGET" != "N/A" ] && [ -n "$RECOVERY_TARGET" ]; then
            echo -e "${CYAN}Recovery Target:${NC} ${RECOVERY_TARGET}"
        fi
        
        # Check if there's a recovery target time
        RECOVERY_TIME=$(run_query "SELECT setting FROM pg_settings WHERE name = 'recovery_target_time';" 2>/dev/null | tr -d ' ' || echo "")
        if [ -n "$RECOVERY_TIME" ] && [ "$RECOVERY_TIME" != "" ]; then
            echo -e "${CYAN}Recovery Target Time:${NC} ${RECOVERY_TIME}"
        fi
        
        echo ""
        echo -e "${YELLOW}Waiting for recovery to complete...${NC}"
        echo -e "${CYAN}ANALYZE cannot run during recovery.${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}Refreshing in ${REFRESH_INTERVAL} seconds... (Ctrl+C to stop)${NC}"
    sleep "$REFRESH_INTERVAL"
done

