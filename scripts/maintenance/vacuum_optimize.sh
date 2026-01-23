#!/bin/bash

# Script to vacuum and optimize PostgreSQL databases
# Usage: ./vacuum_optimize.sh [options]
#
# IMPORTANT: VACUUM in Replication Setup
# =======================================
# In PostgreSQL streaming replication (Patroni), VACUUM operations do NOT replicate.
# Each node must run VACUUM independently:
#
# - LEADER (Master): Needs VACUUM to clean up dead tuples from writes/updates/deletes
# - REPLICAS (Slaves): Also need VACUUM to maintain visibility maps and clean up
#                      their own internal structures (though they have fewer dead tuples)
#
# Best Practices:
# - VACUUM ANALYZE: Safe on both leader and replicas (non-blocking, recommended)
# - VACUUM: Safe on both leader and replicas (non-blocking)
# - VACUUM FULL: Should be done on leader first, then replicas (blocking, use with caution)
# - Autovacuum: Runs independently on each node (already configured in your setup)
#
# Options:
#   --node <node>        Target specific node (db1, db2, db3, db4)
#   --database <db>      Target specific database (default: all databases)
#   --type <type>        Vacuum type: analyze, vacuum, full (default: analyze)
#   --all-nodes          Run on all nodes (default: leader only)
#   --verbose            Show detailed output

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
TARGET_DATABASE=""
VACUUM_TYPE="analyze"  # analyze, vacuum, full
ALL_NODES=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --database)
            TARGET_DATABASE="$2"
            shift 2
            ;;
        --type)
            VACUUM_TYPE="$2"
            if [[ ! "$VACUUM_TYPE" =~ ^(analyze|vacuum|full)$ ]]; then
                echo -e "${RED}Invalid vacuum type: $VACUUM_TYPE${NC}"
                echo -e "${YELLOW}Valid types: analyze, vacuum, full${NC}"
                exit 1
            fi
            shift 2
            ;;
        --all-nodes)
            ALL_NODES=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --node <node>        Target specific node (db1, db2, db3, db4)"
            echo "  --database <db>      Target specific database (default: all databases)"
            echo "  --type <type>        Vacuum type: analyze, vacuum, full (default: analyze)"
            echo "                       - analyze: VACUUM ANALYZE (recommended, non-blocking)"
            echo "                       - vacuum: VACUUM only (non-blocking)"
            echo "                       - full: VACUUM FULL (blocking, reclaims space)"
            echo "  --all-nodes          Run on all nodes (default: leader only)"
            echo "  --verbose            Show detailed output"
            echo ""
            echo "Examples:"
            echo "  $0                                    # VACUUM ANALYZE on leader, all databases"
            echo "  $0 --type full --database postgres   # VACUUM FULL on postgres database"
            echo "  $0 --node db2 --type analyze         # VACUUM ANALYZE on db2"
            echo "  $0 --all-nodes --type vacuum          # VACUUM on all nodes"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            exit 1
            ;;
    esac
done

# Load environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}

# Function to get port for a node
# Note: Inside containers, PostgreSQL always listens on port 5431
# The external ports (15431-15434) are only for host access
get_node_port() {
    local node=$1
    # All nodes use port 5431 inside the container
    echo "5431"
}

# Function to find leader node
find_leader() {
    local leader=""
    PATRONI_LIST=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
    if [ -n "$PATRONI_LIST" ]; then
        leader=$(echo "$PATRONI_LIST" | grep -i "Leader" | awk '{print $2}' | head -1)
    fi
    echo "$leader"
}

# Function to get list of databases
get_databases() {
    local node=$1
    local port=$2
    docker exec "$node" psql -U postgres -p "$port" -h localhost -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | grep -v '^$' || echo "postgres"
}

# Function to run vacuum command
run_vacuum() {
    local node=$1
    local port=$2
    local database=$3
    local vacuum_type=$4
    
    local vacuum_cmd=""
    case $vacuum_type in
        analyze)
            vacuum_cmd="VACUUM ANALYZE;"
            ;;
        vacuum)
            vacuum_cmd="VACUUM;"
            ;;
        full)
            vacuum_cmd="VACUUM FULL;"
            ;;
    esac
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}  Running ${vacuum_type} on ${database}...${NC}"
    fi
    
    # Run vacuum with timeout (VACUUM FULL can take a long time)
    local timeout_seconds=3600  # 1 hour for VACUUM FULL
    if [ "$vacuum_type" = "full" ]; then
        timeout_seconds=7200  # 2 hours for VACUUM FULL
    fi
    
    if docker exec "$node" timeout "$timeout_seconds" psql -U postgres -p "$port" -h localhost -d "$database" -c "$vacuum_cmd" 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get database statistics before/after
get_db_stats() {
    local node=$1
    local port=$2
    local database=$3
    
    docker exec "$node" psql -U postgres -p "$port" -h localhost -d "$database" -t -A -c "
        SELECT 
            pg_size_pretty(pg_database_size('$database')) as size,
            (SELECT count(*) FROM pg_stat_user_tables WHERE schemaname = 'public') as tables,
            (SELECT sum(n_tup_ins + n_tup_upd + n_tup_del) FROM pg_stat_user_tables WHERE schemaname = 'public') as total_operations
    " 2>/dev/null | tr '|' ' ' || echo "N/A N/A N/A"
}

# Determine target nodes
NODES=()
if [ -n "$TARGET_NODE" ]; then
    # Specific node requested
    if [[ ! "$TARGET_NODE" =~ ^db[1-4]$ ]]; then
        echo -e "${RED}Invalid node: $TARGET_NODE${NC}"
        echo -e "${YELLOW}Valid nodes: db1, db2, db3, db4${NC}"
        exit 1
    fi
    NODES=("$TARGET_NODE")
elif [ "$ALL_NODES" = true ]; then
    # All nodes
    NODES=("db1" "db2" "db3" "db4")
else
    # Leader only (default)
    LEADER=$(find_leader)
    if [ -z "$LEADER" ]; then
        echo -e "${YELLOW}Could not determine leader, using db1${NC}"
        LEADER="db1"
    fi
    NODES=("$LEADER")
fi

# Display header
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  PostgreSQL Vacuum & Optimization${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Vacuum Type:${NC} ${BOLD}${VACUUM_TYPE}${NC}"
echo -e "${CYAN}Target Nodes:${NC} ${BOLD}${NODES[*]}${NC}"
if [ -n "$TARGET_DATABASE" ]; then
    echo -e "${CYAN}Target Database:${NC} ${BOLD}${TARGET_DATABASE}${NC}"
else
    echo -e "${CYAN}Target Database:${NC} ${BOLD}All databases${NC}"
fi
echo ""

# Warning for VACUUM FULL
if [ "$VACUUM_TYPE" = "full" ]; then
    echo -e "${YELLOW}⚠ WARNING: VACUUM FULL will lock tables and can take a long time!${NC}"
    echo -e "${YELLOW}  This operation is blocking and will prevent concurrent access.${NC}"
    echo ""
    if [ -t 0 ]; then
        read -p "Continue with VACUUM FULL? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Aborted.${NC}"
            exit 0
        fi
    else
        echo -e "${YELLOW}  Non-interactive mode: proceeding with VACUUM FULL...${NC}"
        sleep 2
    fi
    echo ""
fi

# Process each node
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for node in "${NODES[@]}"; do
    port=$(get_node_port "$node")
    if [ -z "$port" ]; then
        echo -e "${RED}✗ Invalid node: $node${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    echo -e "${YELLOW}[Processing ${node}]${NC}"
    
    # Check if node is accessible
    if ! docker exec "$node" psql -U postgres -p "$port" -h localhost -c "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}  ✗ Cannot connect to ${node}${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    # Get databases to process
    if [ -n "$TARGET_DATABASE" ]; then
        DATABASES=("$TARGET_DATABASE")
    else
        DATABASES=($(get_databases "$node" "$port"))
        # Always include postgres database
        if [[ ! " ${DATABASES[@]} " =~ " postgres " ]]; then
            DATABASES+=("postgres")
        fi
    fi
    
    echo -e "${CYAN}  Databases: ${DATABASES[*]}${NC}"
    echo ""
    
    # Process each database
    for database in "${DATABASES[@]}"; do
        # Check if database exists
        if ! docker exec "$node" psql -U postgres -p "$port" -h localhost -lqt | cut -d \| -f 1 | grep -qw "$database"; then
            echo -e "${YELLOW}  ⚠ Database '${database}' does not exist on ${node}, skipping...${NC}"
            continue
        fi
        
        echo -e "${CYAN}  Database: ${BOLD}${database}${NC}"
        
        # Get stats before
        if [ "$VERBOSE" = true ]; then
            stats_before=$(get_db_stats "$node" "$port" "$database")
            echo -e "${CYAN}    Before: ${stats_before}${NC}"
        fi
        
        # Run vacuum
        start_time=$(date +%s)
        if run_vacuum "$node" "$port" "$database" "$VACUUM_TYPE"; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            echo -e "${GREEN}  ✓ ${database} optimized (${duration}s)${NC}"
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
            
            # Get stats after
            if [ "$VERBOSE" = true ]; then
                stats_after=$(get_db_stats "$node" "$port" "$database")
                echo -e "${CYAN}    After:  ${stats_after}${NC}"
            fi
        else
            echo -e "${RED}  ✗ Failed to optimize ${database}${NC}"
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
        echo ""
    done
done

# Summary
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  Summary${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${GREEN}✓ Successful: ${TOTAL_SUCCESS}${NC}"
if [ $TOTAL_FAILED -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${TOTAL_FAILED}${NC}"
fi
echo ""

if [ $TOTAL_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi

