#!/bin/bash

# Script to collect PostgreSQL metrics using pgmetrics
# Usage: ./pgmetrics_collect.sh [options]
#
# Options:
#   --node <node>        Target specific node (db1, db2, db3, db4)
#   --all-nodes          Collect from all nodes
#   --format <format>    Output format: text, json, html (default: text)
#   --output-dir <dir>   Output directory (default: ./reports)
#   --no-schema          Don't collect schema information (faster)

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
ALL_NODES=false
OUTPUT_FORMAT="text"
OUTPUT_DIR="./reports"
NO_SCHEMA=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --all-nodes)
            ALL_NODES=true
            shift
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            if [[ ! "$OUTPUT_FORMAT" =~ ^(text|json|html)$ ]]; then
                echo -e "${RED}Invalid format: $OUTPUT_FORMAT${NC}"
                echo -e "${YELLOW}Valid formats: text, json, html${NC}"
                exit 1
            fi
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-schema)
            NO_SCHEMA=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "pgmetrics - PostgreSQL metrics collector"
            echo ""
            echo "Options:"
            echo "  --node <node>        Target specific node (db1, db2, db3, db4)"
            echo "  --all-nodes          Collect from all nodes"
            echo "  --format <format>    Output format: text, json, html (default: text)"
            echo "  --output-dir <dir>   Output directory (default: ./reports)"
            echo "  --no-schema          Don't collect schema information (faster)"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Text output for leader"
            echo "  $0 --node db2 --format json          # JSON output for db2"
            echo "  $0 --all-nodes --format html         # HTML reports for all nodes"
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

# Determine target nodes
NODES=()
if [ -n "$TARGET_NODE" ]; then
    if [[ ! "$TARGET_NODE" =~ ^db[1-4]$ ]]; then
        echo -e "${RED}Invalid node: $TARGET_NODE${NC}"
        echo -e "${YELLOW}Valid nodes: db1, db2, db3, db4${NC}"
        exit 1
    fi
    NODES=("$TARGET_NODE")
elif [ "$ALL_NODES" = true ]; then
    NODES=("db1" "db2" "db3" "db4")
else
    LEADER=$(find_leader)
    if [ -z "$LEADER" ]; then
        echo -e "${YELLOW}Could not determine leader, using db1${NC}"
        LEADER="db1"
    fi
    NODES=("$LEADER")
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Display header
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  pgmetrics - Metrics Collector${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Target Nodes:${NC} ${BOLD}${NODES[*]}${NC}"
echo -e "${CYAN}Output Format:${NC} ${BOLD}${OUTPUT_FORMAT}${NC}"
echo -e "${CYAN}Output Directory:${NC} ${BOLD}${OUTPUT_DIR}${NC}"
echo ""

# Check if pgmetrics is available in barman container
if ! docker exec barman which pgmetrics >/dev/null 2>&1; then
    echo -e "${YELLOW}pgmetrics not found, installing...${NC}"
    docker exec barman apt-get update >/dev/null 2>&1
    docker exec barman apt-get install -y wget >/dev/null 2>&1
    
    # Download pgmetrics binary (single binary, no dependencies)
    docker exec barman sh -c "wget -q https://github.com/rapidloop/pgmetrics/releases/latest/download/pgmetrics_linux_amd64.tar.gz -O /tmp/pgmetrics.tar.gz && tar -xzf /tmp/pgmetrics.tar.gz -C /usr/local/bin/ && chmod +x /usr/local/bin/pgmetrics && rm /tmp/pgmetrics.tar.gz" 2>&1 || {
        echo -e "${RED}Failed to install pgmetrics${NC}"
        echo -e "${YELLOW}You can install it manually or use pg_stat_statements instead${NC}"
        exit 1
    }
fi

# Process each node
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for node in "${NODES[@]}"; do
    echo -e "${YELLOW}[Collecting metrics from ${node}]${NC}"
    
    # Check if node is accessible
    if ! docker exec "$node" psql -U postgres -p 5431 -h localhost -c "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}  ✗ Cannot connect to ${node}${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    # Generate output filename
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTPUT_FILE="${OUTPUT_DIR}/pgmetrics-${node}-${TIMESTAMP}.${OUTPUT_FORMAT}"
    
    # Build pgmetrics command
    PGMETRICS_CMD="pgmetrics"
    PGMETRICS_CMD="$PGMETRICS_CMD --format $OUTPUT_FORMAT"
    if [ "$NO_SCHEMA" = true ]; then
        PGMETRICS_CMD="$PGMETRICS_CMD --no-schema"
    fi
    
    # Get connection info from node
    # pgmetrics needs to connect from barman container to the node
    # We'll use the node's hostname and port
    CONN_STRING="postgresql://postgres:${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}@${node}:5431/postgres"
    
    echo -e "${CYAN}  Collecting metrics...${NC}"
    start_time=$(date +%s)
    
    # Run pgmetrics from barman container
    if docker exec barman sh -c "$PGMETRICS_CMD '$CONN_STRING' > /tmp/pgmetrics-output.${OUTPUT_FORMAT}" 2>&1; then
        # Copy output to host
        docker cp "barman:/tmp/pgmetrics-output.${OUTPUT_FORMAT}" "$OUTPUT_FILE" >/dev/null 2>&1
        
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        if [ -f "$OUTPUT_FILE" ]; then
            echo -e "${GREEN}  ✓ Metrics collected: ${OUTPUT_FILE} (${duration}s)${NC}"
            FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
            echo -e "${CYAN}    File size: ${FILE_SIZE}${NC}"
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        else
            echo -e "${RED}  ✗ Failed to save output${NC}"
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
        
        # Cleanup
        docker exec barman rm -f /tmp/pgmetrics-output.${OUTPUT_FORMAT} >/dev/null 2>&1
    else
        echo -e "${RED}  ✗ Failed to collect metrics${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
    echo ""
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
echo -e "${CYAN}Reports location:${NC} ${BOLD}${OUTPUT_DIR}${NC}"
echo ""

if [ $TOTAL_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi

