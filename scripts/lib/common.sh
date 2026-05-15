#!/bin/bash
# scripts/lib/common.sh — Shared library for Patroni HA scripts
# Source this file at the top of any script that needs node discovery, colors, or leader detection.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   or:  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" && source "$SCRIPT_DIR/../lib/common.sh"

# ============================================================================
# Colors
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================================
# Project root detection
# ============================================================================
_find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/docker-compose.yml" ] && [ -f "$dir/.env" ] && echo "$dir" && return 0
        dir="$(dirname "$dir")"
    done
    # Fallback: try docker-compose.yml only
    dir="$1"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/docker-compose.yml" ] && echo "$dir" && return 0
        dir="$(dirname "$dir")"
    done
    return 1
}

# Determine project root from the calling script's location
if [ -n "${BASH_SOURCE[1]:-}" ]; then
    _COMMON_CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
else
    _COMMON_CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
PROJECT_ROOT="$(_find_project_root "$_COMMON_CALLER_DIR")"

# ============================================================================
# Load .env
# ============================================================================
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# ============================================================================
# Node configuration
# ============================================================================
PATRONI_NODES=${PATRONI_NODES:-4}
PATRONI_BASE_PORT=${PATRONI_BASE_PORT:-15431}
PATRONI_API_BASE_PORT=${PATRONI_API_BASE_PORT:-8001}
PATRONI_CLUSTER_NAME=${PATRONI_CLUSTER_NAME:-patroni1}
DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}

# ============================================================================
# Node discovery functions
# ============================================================================

# Returns space-separated list of node names: db1 db2 db3 ...
# Usage: DB_NODES=($(get_db_nodes))
get_db_nodes() {
    local nodes=""
    for i in $(seq 1 "$PATRONI_NODES"); do
        nodes="${nodes}db${i} "
    done
    echo "$nodes"
}

# Get the host-exposed PostgreSQL port for a node number
# Usage: get_db_port 1  → 15431
get_db_port() {
    local node_num=$1
    echo $((PATRONI_BASE_PORT + node_num - 1))
}

# Get the host-exposed Patroni API port for a node number
# Usage: get_api_port 1  → 8001
get_api_port() {
    local node_num=$1
    echo $((PATRONI_API_BASE_PORT + node_num - 1))
}

# Extract the node number from a node name
# Usage: get_node_num "db3"  → 3
get_node_num() {
    echo "${1#db}"
}

# Get the internal PostgreSQL port (same for all nodes inside containers)
get_internal_pg_port() {
    echo "5431"
}

# Get the internal Patroni API port (same for all nodes inside containers)
get_internal_api_port() {
    echo "8001"
}

# Get the Patroni data directory (same scope for all nodes)
get_patroni_data_dir() {
    echo "/var/lib/postgresql/15/${PATRONI_CLUSTER_NAME}"
}

# ============================================================================
# Validation
# ============================================================================

# Check if a node name is valid for the current configuration
# Usage: validate_node "db3" || exit 1
validate_node() {
    local node="$1"
    local num="${node#db}"
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$PATRONI_NODES" ]; then
        return 0
    fi
    echo -e "${RED}Invalid node: $node. Valid nodes: $(get_db_nodes)${NC}" >&2
    return 1
}

# ============================================================================
# Leader detection
# ============================================================================

# Detect the current cluster leader by querying patronictl on the first available node
# Usage: LEADER=$(detect_leader)
detect_leader() {
    for i in $(seq 1 "$PATRONI_NODES"); do
        local node="db${i}"
        local leader
        leader=$(docker exec "$node" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
            | grep -i "Leader" | awk '{print $2}' | head -1)
        if [ -n "$leader" ]; then
            echo "$leader"
            return 0
        fi
    done
    echo "db1"  # fallback
    return 1
}

# Detect leader using Patroni REST API (faster, no exec needed)
# Usage: LEADER=$(detect_leader_api)
detect_leader_api() {
    for i in $(seq 1 "$PATRONI_NODES"); do
        local node="db${i}"
        local api_port
        api_port=$(get_api_port "$i")
        local role
        role=$(curl -s "http://localhost:${api_port}/patroni" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('role',''))" 2>/dev/null)
        if [ "$role" = "master" ] || [ "$role" = "primary" ]; then
            echo "$node"
            return 0
        fi
    done
    echo "db1"  # fallback
    return 1
}
