#!/bin/bash

# Script to check stack health and output connection information in JSON format
# Usage: ./get_stack_info.sh [--json|--human]

# Don't exit on error - we want to output info even if some checks fail
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Output format (default: json)
OUTPUT_FORMAT="${1:---json}"

# Load environment variables from .env file
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "Warning: .env file not found. Using default values." >&2
fi

# Set defaults if not set
HAPROXY_WRITE_PORT=${HAPROXY_WRITE_PORT:-5551}
HAPROXY_READ_PORT=${HAPROXY_READ_PORT:-5552}
HAPROXY_STATS_PORT=${HAPROXY_STATS_PORT:-5553}
PATRONI_DB1_PORT=${PATRONI_DB1_PORT:-15431}
PATRONI_DB1_API_PORT=${PATRONI_DB1_API_PORT:-8001}
PATRONI_DB2_PORT=${PATRONI_DB2_PORT:-15432}
PATRONI_DB2_API_PORT=${PATRONI_DB2_API_PORT:-8002}
PATRONI_DB3_PORT=${PATRONI_DB3_PORT:-15433}
PATRONI_DB3_API_PORT=${PATRONI_DB3_API_PORT:-8003}
PATRONI_DB4_PORT=${PATRONI_DB4_PORT:-15434}
PATRONI_DB4_API_PORT=${PATRONI_DB4_API_PORT:-8004}
ETCD1_CLIENT_PORT=${ETCD1_CLIENT_PORT:-2379}
ETCD2_CLIENT_PORT=${ETCD2_CLIENT_PORT:-22379}
ETCD1_PEER_PORT=${ETCD1_PEER_PORT:-12380}
ETCD2_PEER_PORT=${ETCD2_PEER_PORT:-22380}
BARMAN_PORT=${BARMAN_PORT:-5432}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}

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
CONTAINERS_TOTAL=8

# Calculate total checks for progress
PROGRESS_TOTAL=14  # 8 containers + 4 roles + 2 etcd health

# Show header for non-JSON output
if [ "$OUTPUT_FORMAT" != "--json" ]; then
    echo -e "${BLUE}${BOLD}========================================${NC}" >&2
    echo -e "${BLUE}${BOLD}  Stack Health Check & Info${NC}" >&2
    echo -e "${BLUE}${BOLD}========================================${NC}" >&2
    echo "" >&2
fi

# Check containers
ETCD1_RUNNING=false
ETCD2_RUNNING=false
DB1_RUNNING=false
DB2_RUNNING=false
DB3_RUNNING=false
DB4_RUNNING=false
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

print_progress "Checking db1 container" "$CYAN"
if is_container_running "db1"; then
    DB1_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "db1 is running" "ok"
else
    print_status "db1 is not running" "fail"
fi

print_progress "Checking db2 container" "$CYAN"
if is_container_running "db2"; then
    DB2_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "db2 is running" "ok"
else
    print_status "db2 is not running" "fail"
fi

print_progress "Checking db3 container" "$CYAN"
if is_container_running "db3"; then
    DB3_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "db3 is running" "ok"
else
    print_status "db3 is not running" "fail"
fi

print_progress "Checking db4 container" "$CYAN"
if is_container_running "db4"; then
    DB4_RUNNING=true
    ((CONTAINERS_RUNNING++))
    print_status "db4 is running" "ok"
else
    print_status "db4 is not running" "fail"
fi

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
DB1_ROLE="unknown"
DB2_ROLE="unknown"
DB3_ROLE="unknown"
DB4_ROLE="unknown"

print_progress "Checking db1 Patroni role" "$MAGENTA"
if [ "$DB1_RUNNING" = true ]; then
    DB1_ROLE=$(get_patroni_role "db1" "8001" 2>/dev/null || echo "unknown")
    if [ "$DB1_ROLE" != "unknown" ]; then
        print_status "db1 role: $DB1_ROLE" "ok"
    else
        print_status "db1 role: unknown" "warn"
    fi
else
    print_status "db1 not running, skipping role check" "warn"
fi

print_progress "Checking db2 Patroni role" "$MAGENTA"
if [ "$DB2_RUNNING" = true ]; then
    DB2_ROLE=$(get_patroni_role "db2" "8001" 2>/dev/null || echo "unknown")
    if [ "$DB2_ROLE" != "unknown" ]; then
        print_status "db2 role: $DB2_ROLE" "ok"
    else
        print_status "db2 role: unknown" "warn"
    fi
else
    print_status "db2 not running, skipping role check" "warn"
fi

print_progress "Checking db3 Patroni role" "$MAGENTA"
if [ "$DB3_RUNNING" = true ]; then
    DB3_ROLE=$(get_patroni_role "db3" "8001" 2>/dev/null || echo "unknown")
    if [ "$DB3_ROLE" != "unknown" ]; then
        print_status "db3 role: $DB3_ROLE" "ok"
    else
        print_status "db3 role: unknown" "warn"
    fi
else
    print_status "db3 not running, skipping role check" "warn"
fi

print_progress "Checking db4 Patroni role" "$MAGENTA"
if [ "$DB4_RUNNING" = true ]; then
    DB4_ROLE=$(get_patroni_role "db4" "8001" 2>/dev/null || echo "unknown")
    if [ "$DB4_ROLE" != "unknown" ]; then
        print_status "db4 role: $DB4_ROLE" "ok"
    else
        print_status "db4 role: unknown" "warn"
    fi
else
    print_status "db4 not running, skipping role check" "warn"
fi

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
if [ "$OUTPUT_FORMAT" = "--json" ]; then
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
      "write": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}",
      "read": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}",
      "stats": "http://localhost:${HAPROXY_STATS_PORT}/stats"
    },
    "running": $HAPROXY_RUNNING,
    "description": "Write port routes to leader, read port routes to replicas"
  },
  "patroni": {
    "nodes": [
      {
        "name": "db1",
        "host": "localhost",
        "database_port": $PATRONI_DB1_PORT,
        "api_port": $PATRONI_DB1_API_PORT,
        "api_url": "http://localhost:${PATRONI_DB1_API_PORT}",
        "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB1_PORT}/${DEFAULT_DATABASE}",
        "role": "$DB1_ROLE",
        "running": $DB1_RUNNING
      },
      {
        "name": "db2",
        "host": "localhost",
        "database_port": $PATRONI_DB2_PORT,
        "api_port": $PATRONI_DB2_API_PORT,
        "api_url": "http://localhost:${PATRONI_DB2_API_PORT}",
        "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB2_PORT}/${DEFAULT_DATABASE}",
        "role": "$DB2_ROLE",
        "running": $DB2_RUNNING
      },
      {
        "name": "db3",
        "host": "localhost",
        "database_port": $PATRONI_DB3_PORT,
        "api_port": $PATRONI_DB3_API_PORT,
        "api_url": "http://localhost:${PATRONI_DB3_API_PORT}",
        "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB3_PORT}/${DEFAULT_DATABASE}",
        "role": "$DB3_ROLE",
        "running": $DB3_RUNNING
      },
      {
        "name": "db4",
        "host": "localhost",
        "database_port": $PATRONI_DB4_PORT,
        "api_port": $PATRONI_DB4_API_PORT,
        "api_url": "http://localhost:${PATRONI_DB4_API_PORT}",
        "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB4_PORT}/${DEFAULT_DATABASE}",
        "role": "$DB4_ROLE",
        "running": $DB4_RUNNING
      }
    ],
    "credentials": {
      "username": "postgres",
      "password": "${POSTGRES_PASSWORD}",
      "replicator_password": "${REPLICATOR_PASSWORD}",
      "default_database": "${DEFAULT_DATABASE}"
    },
    "cluster_status_endpoint": "docker exec -it db1 patronictl -c /etc/patroni/patroni.yml list"
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
      "password": "${POSTGRES_PASSWORD}",
      "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}",
      "description": "Routes to current leader, use for all write operations"
    },
    "recommended_read_endpoint": {
      "type": "postgresql",
      "host": "localhost",
      "port": $HAPROXY_READ_PORT,
      "database": "${DEFAULT_DATABASE}",
      "username": "postgres",
      "password": "${POSTGRES_PASSWORD}",
      "connection_string": "postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}",
      "description": "Routes to replicas in round-robin, use for read operations"
    },
    "monitoring": {
      "haproxy_stats": "http://localhost:${HAPROXY_STATS_PORT}/stats",
      "patroni_api_base": "http://localhost:${PATRONI_DB1_API_PORT}",
      "patroni_cluster_status": "docker exec -it db1 patronictl -c /etc/patroni/patroni.yml list"
    },
    "logs": {
      "all_services": "$DOCKER_COMPOSE logs -f",
      "all_services_tail": "$DOCKER_COMPOSE logs --tail=100",
      "patroni_nodes": {
        "db1": "$DOCKER_COMPOSE logs -f db1",
        "db2": "$DOCKER_COMPOSE logs -f db2",
        "db3": "$DOCKER_COMPOSE logs -f db3",
        "db4": "$DOCKER_COMPOSE logs -f db4",
        "all_patroni": "$DOCKER_COMPOSE logs -f db1 db2 db3 db4"
      },
      "haproxy": "$DOCKER_COMPOSE logs -f haproxy",
      "barman": "$DOCKER_COMPOSE logs -f barman",
      "etcd": {
        "etcd1": "$DOCKER_COMPOSE logs -f etcd1",
        "etcd2": "$DOCKER_COMPOSE logs -f etcd2",
        "all_etcd": "$DOCKER_COMPOSE logs -f etcd1 etcd2"
      },
      "postgresql_json_logs": {
        "db1": "docker exec -it db1 sh -c 'tail -f /var/log/postgresql/*.json'",
        "db2": "docker exec -it db2 sh -c 'tail -f /var/log/postgresql/*.json'",
        "db3": "docker exec -it db3 sh -c 'tail -f /var/log/postgresql/*.json'",
        "db4": "docker exec -it db4 sh -c 'tail -f /var/log/postgresql/*.json'"
      },
      "archive_logs": {
        "db1": "docker exec -it db1 tail -f /var/log/postgresql/archive.log",
        "db2": "docker exec -it db2 tail -f /var/log/postgresql/archive.log",
        "db3": "docker exec -it db3 tail -f /var/log/postgresql/archive.log",
        "db4": "docker exec -it db4 tail -f /var/log/postgresql/archive.log"
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
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}"
    echo ""
    echo "Read Endpoint (Replicas):"
    echo "  Host: localhost"
    echo "  Port: $HAPROXY_READ_PORT"
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}"
    echo ""
    echo "Stats Endpoint:"
    echo "  URL: http://localhost:${HAPROXY_STATS_PORT}/stats"
    echo "  Status: $([ "$HAPROXY_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "------------------------------------------"
    echo "Patroni Nodes"
    echo "------------------------------------------"
    echo "db1:"
    echo "  Database Port: $PATRONI_DB1_PORT"
    echo "  API Port: $PATRONI_DB1_API_PORT"
    echo "  Role: $DB1_ROLE"
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB1_PORT}/${DEFAULT_DATABASE}"
    echo "  API: http://localhost:${PATRONI_DB1_API_PORT}"
    echo "  Status: $([ "$DB1_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "db2:"
    echo "  Database Port: $PATRONI_DB2_PORT"
    echo "  API Port: $PATRONI_DB2_API_PORT"
    echo "  Role: $DB2_ROLE"
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB2_PORT}/${DEFAULT_DATABASE}"
    echo "  API: http://localhost:${PATRONI_DB2_API_PORT}"
    echo "  Status: $([ "$DB2_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "db3:"
    echo "  Database Port: $PATRONI_DB3_PORT"
    echo "  API Port: $PATRONI_DB3_API_PORT"
    echo "  Role: $DB3_ROLE"
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB3_PORT}/${DEFAULT_DATABASE}"
    echo "  API: http://localhost:${PATRONI_DB3_API_PORT}"
    echo "  Status: $([ "$DB3_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "db4:"
    echo "  Database Port: $PATRONI_DB4_PORT"
    echo "  API Port: $PATRONI_DB4_API_PORT"
    echo "  Role: $DB4_ROLE"
    echo "  Connection: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB4_PORT}/${DEFAULT_DATABASE}"
    echo "  API: http://localhost:${PATRONI_DB4_API_PORT}"
    echo "  Status: $([ "$DB4_RUNNING" = true ] && echo "Running" || echo "Not Running")"
    echo ""
    echo "Credentials:"
    echo "  Username: postgres"
    echo "  Password: ${POSTGRES_PASSWORD}"
    echo "  Replicator Password: ${REPLICATOR_PASSWORD}"
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
    echo "  # Follow db1 logs"
    echo "  $DOCKER_COMPOSE logs -f db1"
    echo ""
    echo "  # Follow db2 logs"
    echo "  $DOCKER_COMPOSE logs -f db2"
    echo ""
    echo "  # Follow db3 logs"
    echo "  $DOCKER_COMPOSE logs -f db3"
    echo ""
    echo "  # Follow db4 logs"
    echo "  $DOCKER_COMPOSE logs -f db4"
    echo ""
    echo "  # Follow all Patroni nodes"
    echo "  $DOCKER_COMPOSE logs -f db1 db2 db3 db4"
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
    echo "  # Follow PostgreSQL JSON logs (db1)"
    echo "  docker exec -it db1 sh -c 'tail -f /var/log/postgresql/*.json'"
    echo ""
    echo "  # Follow PostgreSQL JSON logs (db2)"
    echo "  docker exec -it db2 sh -c 'tail -f /var/log/postgresql/*.json'"
    echo ""
    echo "  # Follow PostgreSQL JSON logs (db3)"
    echo "  docker exec -it db3 sh -c 'tail -f /var/log/postgresql/*.json'"
    echo ""
    echo "  # Follow PostgreSQL JSON logs (db4)"
    echo "  docker exec -it db4 sh -c 'tail -f /var/log/postgresql/*.json'"
    echo ""
    echo -e "${CYAN}${BOLD}WAL Archive Logs:${NC}"
    echo "  # Follow archive logs (db1)"
    echo "  docker exec -it db1 tail -f /var/log/postgresql/archive.log"
    echo ""
    echo "  # Follow archive logs (db2)"
    echo "  docker exec -it db2 tail -f /var/log/postgresql/archive.log"
    echo ""
    echo "  # Follow archive logs (db3)"
    echo "  docker exec -it db3 tail -f /var/log/postgresql/archive.log"
    echo ""
    echo "  # Follow archive logs (db4)"
    echo "  docker exec -it db4 tail -f /var/log/postgresql/archive.log"
    echo ""
    echo "=========================================="
fi

# Exit with error if stack is unhealthy
if [ "$STACK_HEALTHY" = false ]; then
    exit 1
fi

