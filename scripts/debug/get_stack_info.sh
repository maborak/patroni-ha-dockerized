#!/bin/bash

# Script to check stack health and output connection information in JSON format
# Usage: ./get_stack_info.sh [--json|--human] [--show-passwords]

# Don't exit on error - we want to output info even if some checks fail
set +e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared library (provides colors, .env, node discovery, leader detection)
source "$SCRIPT_DIR/../lib/common.sh"

# Progress indicator
PROGRESS_COUNT=0
PROGRESS_TOTAL=0

# Function to draw progress bar
draw_progress_bar() {
    local current=$1
    local total=$2
    local message=$3
    local color=${4:-$CYAN}
    local width=30
    local filled=0
    local empty=$width
    local percent=0
    
    # Convert to integers (bash arithmetic expansion handles this)
    # If variables are empty or non-numeric, they become 0
    current=$((current))
    total=$((total))
    
    # Ensure total is at least 1 to avoid division by zero
    if [ "$total" -le 0 ]; then
        total=1
    fi
    
    # Calculate percentage and filled width
    if [ "$current" -ge 0 ] && [ "$total" -gt 0 ]; then
        # Calculate percentage: (current * 100) / total
        percent=$((current * 100 / total))
        # Calculate filled width
        filled=$((current * width / total))
        empty=$((width - filled))
        
        # Ensure we don't exceed width or go below 0
        if [ "$filled" -gt "$width" ]; then
            filled=$width
            empty=0
            percent=100
        fi
        if [ "$filled" -lt 0 ]; then
            filled=0
            empty=$width
        fi
        if [ "$empty" -lt 0 ]; then
            empty=0
        fi
        if [ "$percent" -gt 100 ]; then
            percent=100
        fi
        if [ "$percent" -lt 0 ]; then
            percent=0
        fi
    fi
    
    # Build the filled and empty parts (always show something)
    local filled_bar=$(printf "%${filled}s" | tr ' ' '█')
    local empty_bar=$(printf "%${empty}s" | tr ' ' '░')
    
    # Clear the line and print everything on one line with carriage return
    # Add extra spaces at the end to clear any leftover characters
    printf "\r${CYAN}[${NC}${filled_bar}${empty_bar}${CYAN}]${NC} ${BOLD}%3d%%${NC} ${color}${BOLD}${message}${NC}...                    " "$percent" >&2
}

# Function to print progress
print_progress() {
    local message=$1
    local color=${2:-$CYAN}
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        PROGRESS_COUNT=$((PROGRESS_COUNT + 1))
        # Pass explicit numeric values
        draw_progress_bar "$PROGRESS_COUNT" "$PROGRESS_TOTAL" "$message" "$color"
        echo "" >&2  # Move to next line after progress bar
    fi
}

# Function to print status
print_status() {
    local message=$1
    local status=$2
    if [ "$OUTPUT_FORMAT" != "--json" ]; then
        if [ "$status" = "ok" ]; then
            echo -e "  ${GREEN}✓${NC} $message" >&2
        elif [ "$status" = "fail" ]; then
            echo -e "  ${RED}✗${NC} $message" >&2
        elif [ "$status" = "warn" ]; then
            echo -e "  ${YELLOW}⚠${NC} $message" >&2
        else
            echo -e "  ${BLUE}ℹ${NC} $message" >&2
        fi
    fi
}

# Password display control
SHOW_PASSWORDS=false

# Parse arguments
OUTPUT_FORMAT="--json"
for arg in "$@"; do
    case "$arg" in
        --json|--human)
            OUTPUT_FORMAT="$arg"
            ;;
        --show-passwords)
            SHOW_PASSWORDS=true
            ;;
    esac
done

# Helper function to redact passwords unless --show-passwords is passed
display_password() {
    if [ "$SHOW_PASSWORDS" = true ]; then
        echo "$1"
    else
        echo "********"
    fi
}

# Change to project root (common.sh sets PROJECT_ROOT)
cd "$PROJECT_ROOT"

# Set defaults for ports not provided by common.sh
HAPROXY_WRITE_PORT=${HAPROXY_WRITE_PORT:-5551}
HAPROXY_READ_PORT=${HAPROXY_READ_PORT:-5552}
HAPROXY_STATS_PORT=${HAPROXY_STATS_PORT:-5553}
ETCD1_CLIENT_PORT=${ETCD1_CLIENT_PORT:-2379}
ETCD2_CLIENT_PORT=${ETCD2_CLIENT_PORT:-22379}
ETCD1_PEER_PORT=${ETCD1_PEER_PORT:-12380}
ETCD2_PEER_PORT=${ETCD2_PEER_PORT:-22380}
BARMAN_PORT=${BARMAN_PORT:-5432}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD:?Set REPLICATOR_PASSWORD in .env}

# Build DB_NODES array from common.sh
DB_NODES=($(get_db_nodes))

# Use docker compose (v2) if available, otherwise docker-compose (v1)
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif docker-compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "ERROR: docker-compose not available" >&2
    exit 1
fi

# Function to check if container is running
is_container_running() {
    local container=$1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" && \
    [ "$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)" = "running" ]
}

# Function to check port accessibility (cross-platform)
is_port_accessible() {
    local host=$1
    local port=$2
    
    # Try using nc (netcat) first - works on both Linux and macOS
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 1 "$host" "$port" 2>/dev/null
    # Fallback to /dev/tcp for Linux (bash builtin)
    else
        timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null
    fi
}

# Function to get Patroni role
get_patroni_role() {
    local container=$1
    local api_port=$2
    # Use Python to parse JSON directly from curl
    local role=$(docker exec "$container" sh -c "curl -s http://localhost:${api_port}/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$role" ] && [ "$role" != "unknown" ]; then
        echo "$role"
    else
        echo "unknown"
    fi
}

# Function to check etcd health
check_etcd_health() {
    local container=$1
    local health_output=$(docker exec "$container" etcdctl endpoint health --endpoints="http://${container}:2379" 2>/dev/null)
    if echo "$health_output" | grep -q "healthy" 2>/dev/null; then
        echo "healthy"
    else
        echo "unhealthy"
    fi
}

# Initialize status tracking
STACK_HEALTHY=true
CONTAINERS_RUNNING=0
CONTAINERS_TOTAL=$((PATRONI_NODES + 4))  # db nodes + etcd1 + etcd2 + haproxy + barman

# Calculate total checks for progress
PROGRESS_TOTAL=$((CONTAINERS_TOTAL + PATRONI_NODES + 2))  # containers + roles + 2 etcd health

# Show header for non-JSON output
if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo -e "${BLUE}${BOLD}========================================${NC}" >&2
    echo -e "${BLUE}${BOLD}  Stack Health Check & Info${NC}" >&2
    echo -e "${BLUE}${BOLD}========================================${NC}" >&2
    echo "" >&2
fi

# Check containers — use associative arrays for dynamic tracking
declare -A NODE_RUNNING
declare -A NODE_ROLE

ETCD1_RUNNING=false
ETCD2_RUNNING=false
HAPROXY_RUNNING=false
BARMAN_RUNNING=false

print_progress "Checking etcd1 container" "$CYAN"
if is_container_running "etcd1"; then
    ETCD1_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "etcd1 is running" "ok"
else
    print_status "etcd1 is not running" "fail"
fi

print_progress "Checking etcd2 container" "$CYAN"
if is_container_running "etcd2"; then
    ETCD2_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "etcd2 is running" "ok"
else
    print_status "etcd2 is not running" "fail"
fi

# Check DB node containers dynamically
for db in "${DB_NODES[@]}"; do
    NODE_RUNNING[$db]=false
    print_progress "Checking $db container" "$CYAN"
    if is_container_running "$db"; then
        NODE_RUNNING[$db]=true
        ((CONTAINERS_RUNNING++))
        print_status "$db is running" "ok"
    else
        print_status "$db is not running" "fail"
    fi
done

print_progress "Checking haproxy container" "$CYAN"
if is_container_running "haproxy"; then
    HAPROXY_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "haproxy is running" "ok"
else
    print_status "haproxy is not running" "fail"
fi

print_progress "Checking barman container" "$CYAN"
if is_container_running "barman"; then
    BARMAN_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "barman is running" "ok"
else
    print_status "barman is not running" "fail"
fi

# Get Patroni roles (API port is 8001 inside container)
INTERNAL_API_PORT=$(get_internal_api_port)
for db in "${DB_NODES[@]}"; do
    NODE_ROLE[$db]="unknown"
    print_progress "Checking $db Patroni role" "$MAGENTA"
    if [ "${NODE_RUNNING[$db]}" = true ]; then
        NODE_ROLE[$db]=$(get_patroni_role "$db" "$INTERNAL_API_PORT" 2>/dev/null || echo "unknown")
        if [ "${NODE_ROLE[$db]}" != "unknown" ]; then
            print_status "$db role: ${NODE_ROLE[$db]}" "ok"
        else
            print_status "$db role: unknown" "warn"
        fi
    else
        print_status "$db not running, skipping role check" "warn"
    fi
done

# Check etcd health
ETCD1_HEALTH="unknown"
ETCD2_HEALTH="unknown"

print_progress "Checking etcd1 health" "$YELLOW"
if [ "$ETCD1_RUNNING" = true ]; then
    ETCD1_HEALTH=$(check_etcd_health "etcd1")
    if [ "$ETCD1_HEALTH" = "healthy" ]; then
        print_status "etcd1 is healthy" "ok"
    else
        print_status "etcd1 is unhealthy" "fail"
    fi
else
    print_status "etcd1 not running, skipping health check" "warn"
fi

print_progress "Checking etcd2 health" "$YELLOW"
if [ "$ETCD2_RUNNING" = true ]; then
    ETCD2_HEALTH=$(check_etcd_health "etcd2")
    if [ "$ETCD2_HEALTH" = "healthy" ]; then
        print_status "etcd2 is healthy" "ok"
    else
        print_status "etcd2 is unhealthy" "fail"
    fi
else
    print_status "etcd2 not running, skipping health check" "warn"
fi

# Show summary for non-JSON output
if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo "" >&2
    if [ "$CONTAINERS_RUNNING" -eq "$CONTAINERS_TOTAL" ]; then
        echo -e "${GREEN}${BOLD}✓ All containers running ($CONTAINERS_RUNNING/$CONTAINERS_TOTAL)${NC}" >&2
    else
        echo -e "${YELLOW}${BOLD}⚠ Some containers not running ($CONTAINERS_RUNNING/$CONTAINERS_TOTAL)${NC}" >&2
    fi
    echo "" >&2
    echo -e "${BLUE}${BOLD}Generating connection information...${NC}" >&2
    echo "" >&2
fi

# Determine overall health
if [ "$CONTAINERS_RUNNING" -lt "$CONTAINERS_TOTAL" ]; then
    STACK_HEALTHY=false
fi

# Build JSON output
# Pre-build dynamic JSON fragments for patroni nodes, logs, etc.
_build_patroni_nodes_json() {
    local first=true
    for db in "${DB_NODES[@]}"; do
        local num=$(get_node_num "$db")
        local db_port=$(get_db_port "$num")
        local api_port=$(get_api_port "$num")
        if [ "$first" = true ]; then first=false; else echo ","; fi
        cat <<NODEEOF
      {
        "name": "$db",
        "host": "localhost",
        "database_port": $db_port,
        "api_port": $api_port,
        "api_url": "http://localhost:${api_port}",
        "connection_string": "postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${db_port}/${DEFAULT_DATABASE}",
        "role": "${NODE_ROLE[$db]}",
        "running": ${NODE_RUNNING[$db]}
      }
NODEEOF
    done
}

_build_patroni_logs_json() {
    local first=true
    for db in "${DB_NODES[@]}"; do
        if [ "$first" = true ]; then first=false; else echo ","; fi
        printf '        "%s": "%s logs -f %s"' "$db" "$DOCKER_COMPOSE" "$db"
    done
    # Add all_patroni entry
    local all_nodes="${DB_NODES[*]}"
    echo ","
    printf '        "all_patroni": "%s logs -f %s"' "$DOCKER_COMPOSE" "$all_nodes"
}

_build_json_logs_json() {
    local first=true
    for db in "${DB_NODES[@]}"; do
        if [ "$first" = true ]; then first=false; else echo ","; fi
        printf '        "%s": "docker exec -it %s sh -c '"'"'tail -f /var/log/postgresql/*.json'"'"'"' "$db" "$db"
    done
}

_build_archive_logs_json() {
    local first=true
    for db in "${DB_NODES[@]}"; do
        if [ "$first" = true ]; then first=false; else echo ","; fi
        printf '        "%s": "docker exec -it %s tail -f /var/log/postgresql/archive.log"' "$db" "$db"
    done
}

FIRST_API_PORT=$(get_api_port 1)

if [ "$OUTPUT_FORMAT" = "--json" ]; then
    # Use a subshell approach to build JSON with dynamic node entries
    cat <<EOF
{
  "stack": {
    "healthy": $STACK_HEALTHY,
    "containers_running": $CONTAINERS_RUNNING,
    "containers_total": $CONTAINERS_TOTAL,
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  },
  "haproxy": {
    "host": "localhost",
    "ports": {
      "write": $HAPROXY_WRITE_PORT,
      "read": $HAPROXY_READ_PORT,
      "stats": $HAPROXY_STATS_PORT
    },
    "connection_strings": {
      "write": "postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}",
      "read": "postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}",
      "stats": "http://localhost:${HAPROXY_STATS_PORT}/stats"
    },
    "running": $HAPROXY_RUNNING,
    "description": "Write port routes to leader, read port routes to replicas"
  },
  "patroni": {
    "nodes": [
$(_build_patroni_nodes_json)
    ],
    "credentials": {
      "username": "postgres",
      "password": "$(display_password "$POSTGRES_PASSWORD")",
      "replicator_password": "$(display_password "$REPLICATOR_PASSWORD")",
      "default_database": "${DEFAULT_DATABASE}"
    },
    "cluster_status_endpoint": "docker exec -it ${DB_NODES[0]} patronictl -c /etc/patroni/patroni.yml list"
  },
  "etcd": {
    "nodes": [
      {
        "name": "etcd1",
        "host": "localhost",
        "client_port": $ETCD1_CLIENT_PORT,
        "peer_port": $ETCD1_PEER_PORT,
        "client_url": "http://localhost:${ETCD1_CLIENT_PORT}",
        "internal_url": "http://etcd1:2379",
        "health": "$ETCD1_HEALTH",
        "running": $ETCD1_RUNNING
      },
      {
        "name": "etcd2",
        "host": "localhost",
        "client_port": $ETCD2_CLIENT_PORT,
        "peer_port": $ETCD2_PEER_PORT,
        "client_url": "http://localhost:${ETCD2_CLIENT_PORT}",
        "internal_url": "http://etcd2:2379",
        "health": "$ETCD2_HEALTH",
        "running": $ETCD2_RUNNING
      }
    ],
    "cluster_endpoints": "http://localhost:${ETCD1_CLIENT_PORT},http://localhost:${ETCD2_CLIENT_PORT}",
    "internal_endpoints": "http://etcd1:2379,http://etcd2:2379"
  },
  "barman": {
    "host": "localhost",
    "port": $BARMAN_PORT,
    "connection_string": "postgresql://barman@localhost:${BARMAN_PORT}/barman",
    "internal_host": "barman",
    "internal_port": 5432,
    "running": $BARMAN_RUNNING,
    "credentials": {
      "username": "barman",
      "note": "Barman uses SSH for WAL archiving, not direct PostgreSQL connections"
    },
    "ssh_access": {
      "note": "SSH keys are required for WAL archiving from Patroni nodes",
      "key_location": "./ssh_keys/barman_rsa"
    }
  },
  "application_usage": {
    "recommended_write_endpoint": {
      "type": "postgresql",
      "host": "localhost",
      "port": $HAPROXY_WRITE_PORT,
      "database": "${DEFAULT_DATABASE}",
      "username": "postgres",
      "password": "$(display_password "$POSTGRES_PASSWORD")",
      "connection_string": "postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}",
      "description": "Routes to current leader, use for all write operations"
    },
    "recommended_read_endpoint": {
      "type": "postgresql",
      "host": "localhost",
      "port": $HAPROXY_READ_PORT,
      "database": "${DEFAULT_DATABASE}",
      "username": "postgres",
      "password": "$(display_password "$POSTGRES_PASSWORD")",
      "connection_string": "postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}",
      "description": "Routes to replicas in round-robin, use for read operations"
    },
    "monitoring": {
      "haproxy_stats": "http://localhost:${HAPROXY_STATS_PORT}/stats",
      "patroni_api_base": "http://localhost:${FIRST_API_PORT}",
      "patroni_cluster_status": "docker exec -it ${DB_NODES[0]} patronictl -c /etc/patroni/patroni.yml list"
    },
    "logs": {
      "all_services": "$DOCKER_COMPOSE logs -f",
      "all_services_tail": "$DOCKER_COMPOSE logs --tail=100",
      "patroni_nodes": {
$(_build_patroni_logs_json)
      },
      "haproxy": "$DOCKER_COMPOSE logs -f haproxy",
      "barman": "$DOCKER_COMPOSE logs -f barman",
      "etcd": {
        "etcd1": "$DOCKER_COMPOSE logs -f etcd1",
        "etcd2": "$DOCKER_COMPOSE logs -f etcd2",
        "all_etcd": "$DOCKER_COMPOSE logs -f etcd1 etcd2"
      },
      "postgresql_json_logs": {
$(_build_json_logs_json)
      },
      "archive_logs": {
$(_build_archive_logs_json)
      },
      "barman_logs": "docker exec -it barman tail -f /var/log/barman/barman.log"
    }
  }
}
EOF
else
    # Human-readable output
    echo "=========================================="
    echo "  Stack Connection Information"
    echo "=========================================="
    echo ""
    echo "Stack Health: $([ "$STACK_HEALTHY" = true ] && echo "✓ Healthy" || echo "✗ Unhealthy")"
    echo "Containers Running: $CONTAINERS_RUNNING/$CONTAINERS_TOTAL"
    echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""
    echo "------------------------------------------"
    echo "HAProxy (Load Balancer)"
    echo "------------------------------------------"
    echo "Write Endpoint (Leader):"
    echo "  Host: localhost"
    echo "  Port: $HAPROXY_WRITE_PORT"
    echo "  Connection: postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}"
    echo ""
    echo "Read Endpoint (Replicas):"
    echo "  Host: localhost"
    echo "  Port: $HAPROXY_READ_PORT"
    echo "  Connection: postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}"
    echo ""
    echo "Stats Endpoint:"
    echo "  URL: http://localhost:${HAPROXY_STATS_PORT}/stats"
    echo "  Status: $([ "$HAPROXY_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "------------------------------------------"
    echo "Patroni Nodes"
    echo "------------------------------------------"
    for db in "${DB_NODES[@]}"; do
        _num=$(get_node_num "$db")
        _db_port=$(get_db_port "$_num")
        _api_port=$(get_api_port "$_num")
        echo "$db:"
        echo "  Database Port: $_db_port"
        echo "  API Port: $_api_port"
        echo "  Role: ${NODE_ROLE[$db]}"
        echo "  Connection: postgresql://postgres:$(display_password "$POSTGRES_PASSWORD")@localhost:${_db_port}/${DEFAULT_DATABASE}"
        echo "  API: http://localhost:${_api_port}"
        echo "  Status: $([ "${NODE_RUNNING[$db]}" = true ] && echo "Running" || echo "Not Running")"
        echo ""
    done
    echo "Credentials:"
    echo "  Username: postgres"
    echo "  Password: $(display_password "$POSTGRES_PASSWORD")"
    echo "  Replicator Password: $(display_password "$REPLICATOR_PASSWORD")"
    echo "  Default Database: ${DEFAULT_DATABASE}"
    echo ""
    echo "------------------------------------------"
    echo "etcd (Configuration Store)"
    echo "------------------------------------------"
    echo "etcd1:"
    echo "  Client Port: $ETCD1_CLIENT_PORT"
    echo "  Peer Port: $ETCD1_PEER_PORT"
    echo "  Client URL: http://localhost:${ETCD1_CLIENT_PORT}"
    echo "  Health: $ETCD1_HEALTH"
    echo "  Status: $([ "$ETCD1_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "etcd2:"
    echo "  Client Port: $ETCD2_CLIENT_PORT"
    echo "  Peer Port: $ETCD2_PEER_PORT"
    echo "  Client URL: http://localhost:${ETCD2_CLIENT_PORT}"
    echo "  Health: $ETCD2_HEALTH"
    echo "  Status: $([ "$ETCD2_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "Cluster Endpoints:"
    echo "  http://localhost:${ETCD1_CLIENT_PORT},http://localhost:${ETCD2_CLIENT_PORT}"
    echo ""
    echo "------------------------------------------"
    echo "Barman (Backup Server)"
    echo "------------------------------------------"
    echo "Host: localhost"
    echo "Port: $BARMAN_PORT"
    echo "Status: $([ "$BARMAN_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo "Note: Barman uses SSH for WAL archiving, not direct PostgreSQL connections"
    echo ""
    echo "------------------------------------------"
    echo "Viewing Logs"
    echo "------------------------------------------"
    echo ""
    echo -e "${CYAN}${BOLD}All Services:${NC}"
    echo "  # Follow all logs (live)"
    echo "  $DOCKER_COMPOSE logs -f"
    echo ""
    echo "  # View last 100 lines of all logs"
    echo "  $DOCKER_COMPOSE logs --tail=100"
    echo ""
    echo -e "${CYAN}${BOLD}Patroni Nodes:${NC}"
    for db in "${DB_NODES[@]}"; do
        echo "  # Follow $db logs"
        echo "  $DOCKER_COMPOSE logs -f $db"
        echo ""
    done
    echo "  # Follow all Patroni nodes"
    echo "  $DOCKER_COMPOSE logs -f ${DB_NODES[*]}"
    echo ""
    echo -e "${CYAN}${BOLD}HAProxy:${NC}"
    echo "  # Follow HAProxy logs"
    echo "  $DOCKER_COMPOSE logs -f haproxy"
    echo ""
    echo -e "${CYAN}${BOLD}Barman:${NC}"
    echo "  # Follow Barman logs"
    echo "  $DOCKER_COMPOSE logs -f barman"
    echo ""
    echo "  # Follow Barman internal log"
    echo "  docker exec -it barman tail -f /var/log/barman/barman.log"
    echo ""
    echo -e "${CYAN}${BOLD}etcd:${NC}"
    echo "  # Follow etcd1 logs"
    echo "  $DOCKER_COMPOSE logs -f etcd1"
    echo ""
    echo "  # Follow etcd2 logs"
    echo "  $DOCKER_COMPOSE logs -f etcd2"
    echo ""
    echo "  # Follow all etcd nodes"
    echo "  $DOCKER_COMPOSE logs -f etcd1 etcd2"
    echo ""
    echo -e "${CYAN}${BOLD}PostgreSQL JSON Logs:${NC}"
    for db in "${DB_NODES[@]}"; do
        echo "  # Follow PostgreSQL JSON logs ($db)"
        echo "  docker exec -it $db sh -c 'tail -f /var/log/postgresql/*.json'"
        echo ""
    done
    echo -e "${CYAN}${BOLD}WAL Archive Logs:${NC}"
    for db in "${DB_NODES[@]}"; do
        echo "  # Follow archive logs ($db)"
        echo "  docker exec -it $db tail -f /var/log/postgresql/archive.log"
        echo ""
    done
    echo ""
    echo "=========================================="
fi

# Exit with error if stack is unhealthy
if [ "$STACK_HEALTHY" = false ]; then
    exit 1
fi

