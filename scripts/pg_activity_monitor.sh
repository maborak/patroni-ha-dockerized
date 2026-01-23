#!/bin/bash

# Script to run pg_activity for real-time PostgreSQL monitoring
# Usage: ./pg_activity_monitor.sh [options]
#
# Options:
#   --node <node>        Target specific node (db1, db2, db3, db4)
#   --refresh <seconds>  Refresh interval in seconds (default: 2)
#   --verbose           Show verbose output

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
REFRESH_INTERVAL=2
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --refresh)
            REFRESH_INTERVAL="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "pg_activity - Real-time PostgreSQL activity monitor (top-like)"
            echo ""
            echo "Options:"
            echo "  --node <node>        Target specific node (db1, db2, db3, db4)"
            echo "  --refresh <seconds>  Refresh interval in seconds (default: 2)"
            echo "  --verbose           Show verbose output"
            echo ""
            echo "Examples:"
            echo "  $0                          # Monitor leader node"
            echo "  $0 --node db2               # Monitor db2"
            echo "  $0 --refresh 5              # Refresh every 5 seconds"
            echo ""
            echo "Controls:"
            echo "  q, Q, Ctrl+C    - Quit"
            echo "  +, -            - Increase/decrease refresh interval"
            echo "  f, F            - Freeze/unfreeze display"
            echo "  r, R            - Sort by duration (desc/asc)"
            echo "  m, M            - Sort by memory (desc/asc)"
            echo "  c, C            - Sort by CPU (desc/asc)"
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

# Check if pg_activity is available
if ! docker exec "$TARGET_NODE" which pg_activity >/dev/null 2>&1; then
    echo -e "${YELLOW}pg_activity not found in ${TARGET_NODE}${NC}"
    echo -e "${CYAN}Installing pg_activity...${NC}"
    docker exec "$TARGET_NODE" apt-get update >/dev/null 2>&1
    docker exec "$TARGET_NODE" apt-get install -y pg-activity >/dev/null 2>&1 || {
        echo -e "${RED}Failed to install pg_activity${NC}"
        echo -e "${YELLOW}You can install it manually: apt-get install pg-activity${NC}"
        exit 1
    }
fi

# Display header
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  pg_activity - Real-time Monitor${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Target Node:${NC} ${BOLD}${TARGET_NODE}${NC}"
echo -e "${CYAN}Refresh Interval:${NC} ${BOLD}${REFRESH_INTERVAL}s${NC}"
echo ""
echo -e "${YELLOW}Starting pg_activity...${NC}"
echo -e "${CYAN}Press 'q' or Ctrl+C to quit${NC}"
echo ""

# Run pg_activity
# Note: pg_activity doesn't support --verbose flag, removed it
docker exec -it "$TARGET_NODE" pg_activity \
    -U postgres \
    -h localhost \
    -p 5431 \
    -d postgres \
    --refresh "$REFRESH_INTERVAL"

