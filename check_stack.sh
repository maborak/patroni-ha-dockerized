#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables from .env file
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo -e "${YELLOW}Warning: .env file not found. Using default values.${NC}"
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
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}
DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Docker Compose Stack Health Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! command -v docker &> /dev/null; then
    echo -e "${RED}ERROR: docker-compose or docker not found${NC}"
    exit 1
fi

# Use docker compose (v2) if available, otherwise docker-compose (v1)
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif docker-compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    echo -e "${RED}ERROR: docker-compose not available${NC}"
    exit 1
fi

# Check if stack is running
echo -e "${YELLOW}Checking if stack is running...${NC}"
RUNNING_CONTAINERS=$($DOCKER_COMPOSE ps -q 2>/dev/null | wc -l)
if [ "$RUNNING_CONTAINERS" -eq 0 ]; then
    echo -e "${RED}ERROR: Stack is not running. Start it with: ${CYAN}docker-compose up -d${NC}"
    echo ""
    echo -e "${YELLOW}To start the stack:${NC}"
    echo -e "  ${CYAN}cd $SCRIPT_DIR${NC}"
    echo -e "  ${CYAN}docker-compose up -d${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Stack is running (${RUNNING_CONTAINERS} containers)${NC}"
echo ""

# Function to check container status
check_container() {
    local container=$1
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
        if [ "$status" = "running" ]; then
            echo -e "${GREEN}✓ ${container}: Running${NC}"
            return 0
        else
            echo -e "${RED}✗ ${container}: $status${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ ${container}: Not found${NC}"
        return 1
    fi
}

# Function to check port connectivity (cross-platform)
check_port() {
    local host=$1
    local port=$2
    local service=$3
    
    # Try using nc (netcat) first - works on both Linux and macOS
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            echo -e "${GREEN}✓ ${service} (${host}:${port}): Accessible${NC}"
            return 0
        fi
    # Fallback to /dev/tcp for Linux (bash builtin)
    elif timeout 2 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        echo -e "${GREEN}✓ ${service} (${host}:${port}): Accessible${NC}"
        return 0
    fi
    
    echo -e "${RED}✗ ${service} (${host}:${port}): Not accessible${NC}"
    return 1
}

# Function to check HTTP endpoint
check_http() {
    local url=$1
    local service=$2
    if curl -s -f -m 2 "$url" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ ${service} (${url}): Accessible${NC}"
        return 0
    else
        echo -e "${RED}✗ ${service} (${url}): Not accessible${NC}"
        return 1
    fi
}


# Check containers
echo -e "${YELLOW}Checking containers...${NC}"
check_container "etcd1"
check_container "etcd2"
check_container "db1"
check_container "db2"
check_container "db3"
check_container "db4"
check_container "haproxy"
check_container "barman"
echo ""

# Check etcd connectivity
echo -e "${YELLOW}Checking etcd cluster...${NC}"
if docker exec -it etcd1 etcdctl endpoint health --endpoints=http://etcd1:2379 2>/dev/null | grep -q "healthy"; then
    echo -e "${GREEN}✓ etcd1: Healthy${NC}"
else
    echo -e "${RED}✗ etcd1: Unhealthy${NC}"
fi

if docker exec -it etcd2 etcdctl endpoint health --endpoints=http://etcd2:2379 2>/dev/null | grep -q "healthy"; then
    echo -e "${GREEN}✓ etcd2: Healthy${NC}"
else
    echo -e "${RED}✗ etcd2: Unhealthy${NC}"
fi
echo ""

# Check Patroni REST API (from inside containers)
echo -e "${YELLOW}Checking Patroni REST API...${NC}"
# Use Python to parse JSON properly - Patroni API is on port 8001 inside containers
DB1_ROLE=$(docker exec db1 sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
DB2_ROLE=$(docker exec db2 sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
DB3_ROLE=$(docker exec db3 sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
DB4_ROLE=$(docker exec db4 sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")

for db in "db1:$DB1_ROLE" "db2:$DB2_ROLE" "db3:$DB3_ROLE" "db4:$DB4_ROLE"; do
    db_name=$(echo $db | cut -d: -f1)
    db_role=$(echo $db | cut -d: -f2)
    if [ "$db_role" = "Leader" ] || [ "$db_role" = "Replica" ] || [ "$db_role" = "primary" ] || [ "$db_role" = "replica" ]; then
        echo -e "${GREEN}✓ ${db_name} Patroni API: ${db_role}${NC}"
    else
        echo -e "${RED}✗ ${db_name} Patroni API: ${db_role} (not responding properly)${NC}"
    fi
done
echo ""

# Check PostgreSQL connectivity
echo -e "${YELLOW}Checking PostgreSQL connectivity...${NC}"
for db in db1 db2 db3 db4; do
    if docker exec -it $db pg_isready -U postgres -p 5431 > /dev/null 2>&1; then
        echo -e "${GREEN}✓ ${db} PostgreSQL: Ready${NC}"
    else
        echo -e "${RED}✗ ${db} PostgreSQL: Not ready${NC}"
    fi
done

# Check HAProxy
if docker exec -it haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg > /dev/null 2>&1; then
    echo -e "${GREEN}✓ HAProxy: Configuration valid${NC}"
else
    echo -e "${RED}✗ HAProxy: Configuration invalid${NC}"
fi
echo ""

# Check SSH key permissions (before connectivity tests)
echo -e "${YELLOW}Checking SSH key permissions...${NC}"

# Check SSH keys for Patroni nodes (to connect to Barman)
SSH_KEY_ISSUES=0
echo -e "${BLUE}  Patroni nodes SSH keys (for Barman access):${NC}"
for db in db1 db2 db3 db4; do
    if docker ps --format '{{.Names}}' | grep -q "^${db}$"; then
        # Check if private key exists
        if docker exec ${db} test -f /home/postgres/.ssh/barman_rsa 2>/dev/null; then
            # Check permissions (should be 600)
            KEY_PERMS=$(docker exec ${db} stat -c "%a" /home/postgres/.ssh/barman_rsa 2>/dev/null || docker exec ${db} ls -l /home/postgres/.ssh/barman_rsa 2>/dev/null | awk '{print $1}')
            if [ "$KEY_PERMS" = "600" ] || echo "$KEY_PERMS" | grep -q "^-rw-------"; then
                echo -e "${GREEN}  ✓ ${db}: Private key exists with correct permissions (600)${NC}"
            else
                echo -e "${RED}  ✗ ${db}: Private key has wrong permissions: $KEY_PERMS (expected 600)${NC}"
                ((SSH_KEY_ISSUES++))
            fi
        else
            echo -e "${RED}  ✗ ${db}: Private key not found at /home/postgres/.ssh/barman_rsa${NC}"
            ((SSH_KEY_ISSUES++))
        fi
    else
        echo -e "${YELLOW}  ⚠ ${db}: Container not running${NC}"
    fi
done

# Check SSH keys for Barman (to connect to Patroni nodes)
echo -e "${BLUE}  Barman SSH keys (for Patroni access):${NC}"
if docker ps --format '{{.Names}}' | grep -q "^barman$"; then
    # Get Barman's home directory
    BARMAN_HOME=$(docker exec barman getent passwd barman 2>/dev/null | cut -d: -f6 || echo "/var/lib/barman")
    
    # Check if private key exists
    if docker exec barman test -f "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null; then
        # Check permissions (should be 600)
        KEY_PERMS=$(docker exec barman stat -c "%a" "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null || docker exec barman ls -l "$BARMAN_HOME/.ssh/id_rsa" 2>/dev/null | awk '{print $1}')
        if [ "$KEY_PERMS" = "600" ] || echo "$KEY_PERMS" | grep -q "^-rw-------"; then
            echo -e "${GREEN}  ✓ barman: Private key exists with correct permissions (600)${NC}"
        else
            echo -e "${RED}  ✗ barman: Private key has wrong permissions: $KEY_PERMS (expected 600)${NC}"
            ((SSH_KEY_ISSUES++))
        fi
    else
        echo -e "${RED}  ✗ barman: Private key not found at $BARMAN_HOME/.ssh/id_rsa${NC}"
        ((SSH_KEY_ISSUES++))
    fi
else
    echo -e "${YELLOW}  ⚠ barman: Container not running${NC}"
fi

if [ $SSH_KEY_ISSUES -gt 0 ]; then
    echo -e "${YELLOW}Note: SSH key permission issues detected. This may cause SSH connectivity failures.${NC}"
fi
echo ""

# Check SSH connectivity (critical for WAL archiving)
echo -e "${YELLOW}Checking SSH connectivity...${NC}"

# Check SSH from Patroni nodes to Barman
SSH_PATRONI_TO_BARMAN_SUCCESS=0
SSH_PATRONI_TO_BARMAN_FAIL=0
echo -e "${BLUE}  From Patroni nodes to Barman:${NC}"
for db in db1 db2 db3 db4; do
    if docker ps --format '{{.Names}}' | grep -q "^${db}$"; then
        SSH_OUTPUT=$(docker exec ${db} sh -c "ssh -i /home/postgres/.ssh/barman_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 barman@barman 'echo SSH_SUCCESS' 2>&1" 2>&1)
        SSH_EXIT_CODE=$?
        if [ $SSH_EXIT_CODE -eq 0 ]; then
            echo -e "${GREEN}  ✓ ${db} → barman: Connected${NC}"
            ((SSH_PATRONI_TO_BARMAN_SUCCESS++))
        else
            # Extract actual error, skipping warnings, fingerprints, and banners
            ERROR_MSG=$(echo "$SSH_OUTPUT" | \
                grep -v "Permanently added" | \
                grep -v "Warning:" | \
                grep -v "^@@@@@" | \
                grep -v "^$" | \
                grep -v "^The authenticity" | \
                grep -v "^Are you sure" | \
                grep -E "(Permission denied|Connection refused|Connection timed out|Host key verification failed|Could not resolve|No route to host|Connection closed|Authentication failed|ssh_exchange_identification)" | \
                head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # If no specific error found, get first meaningful line (not just @@@ or empty)
            if [ -z "$ERROR_MSG" ]; then
                ERROR_MSG=$(echo "$SSH_OUTPUT" | \
                    grep -v "Permanently added" | \
                    grep -v "Warning:" | \
                    grep -v "^@@@@@" | \
                    grep -v "^$" | \
                    grep -v "^The authenticity" | \
                    grep -v "^Are you sure" | \
                    head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            fi
            # Truncate long error messages
            if [ ${#ERROR_MSG} -gt 80 ]; then
                ERROR_MSG="${ERROR_MSG:0:77}..."
            fi
            if [ -n "$ERROR_MSG" ]; then
                echo -e "${RED}  ✗ ${db} → barman: Failed${NC} ${YELLOW}(Error: ${ERROR_MSG})${NC}"
            else
                echo -e "${RED}  ✗ ${db} → barman: Failed${NC}"
            fi
            ((SSH_PATRONI_TO_BARMAN_FAIL++))
        fi
    else
        echo -e "${YELLOW}  ⚠ ${db}: Container not running${NC}"
        ((SSH_PATRONI_TO_BARMAN_FAIL++))
    fi
done

# Check SSH from Barman to Patroni nodes
SSH_BARMAN_TO_PATRONI_SUCCESS=0
SSH_BARMAN_TO_PATRONI_FAIL=0
echo -e "${BLUE}  From Barman to Patroni nodes:${NC}"
if docker ps --format '{{.Names}}' | grep -q "^barman$"; then
    # Get Barman's home directory
    BARMAN_HOME=$(docker exec barman getent passwd barman 2>/dev/null | cut -d: -f6 || echo "/var/lib/barman")
    
    for db in db1 db2 db3 db4; do
        if docker ps --format '{{.Names}}' | grep -q "^${db}$"; then
            SSH_OUTPUT=$(docker exec -u barman barman ssh -i "$BARMAN_HOME/.ssh/id_rsa" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=3 postgres@${db} 'echo SSH_SUCCESS' 2>&1)
            SSH_EXIT_CODE=$?
            if [ $SSH_EXIT_CODE -eq 0 ]; then
                echo -e "${GREEN}  ✓ barman → ${db}: Connected${NC}"
                ((SSH_BARMAN_TO_PATRONI_SUCCESS++))
            else
                # Extract actual error, skipping warnings, fingerprints, and banners
                ERROR_MSG=$(echo "$SSH_OUTPUT" | \
                    grep -v "Permanently added" | \
                    grep -v "Warning:" | \
                    grep -v "^@@@@@" | \
                    grep -v "^$" | \
                    grep -v "^The authenticity" | \
                    grep -v "^Are you sure" | \
                    grep -E "(Permission denied|Connection refused|Connection timed out|Host key verification failed|Could not resolve|No route to host|Connection closed|Authentication failed|ssh_exchange_identification)" | \
                    head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # If no specific error found, get first meaningful line (not just @@@ or empty)
                if [ -z "$ERROR_MSG" ]; then
                    ERROR_MSG=$(echo "$SSH_OUTPUT" | \
                        grep -v "Permanently added" | \
                        grep -v "Warning:" | \
                        grep -v "^@@@@@" | \
                        grep -v "^$" | \
                        grep -v "^The authenticity" | \
                        grep -v "^Are you sure" | \
                        head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                fi
                # Truncate long error messages
                if [ ${#ERROR_MSG} -gt 80 ]; then
                    ERROR_MSG="${ERROR_MSG:0:77}..."
                fi
                if [ -n "$ERROR_MSG" ]; then
                    echo -e "${RED}  ✗ barman → ${db}: Failed${NC} ${YELLOW}(Error: ${ERROR_MSG})${NC}"
                else
                    echo -e "${RED}  ✗ barman → ${db}: Failed${NC}"
                fi
                ((SSH_BARMAN_TO_PATRONI_FAIL++))
            fi
        else
            echo -e "${YELLOW}  ⚠ ${db}: Container not running${NC}"
            ((SSH_BARMAN_TO_PATRONI_FAIL++))
        fi
    done
else
    echo -e "${YELLOW}  ⚠ barman: Container not running${NC}"
    SSH_BARMAN_TO_PATRONI_FAIL=4
fi

if [ $SSH_PATRONI_TO_BARMAN_FAIL -gt 0 ] || [ $SSH_BARMAN_TO_PATRONI_FAIL -gt 0 ]; then
    echo -e "${YELLOW}Note: SSH connectivity is required for WAL archiving. Some connections failed.${NC}"
fi
echo ""

# Check external ports (informational - may not be accessible from host)
echo -e "${YELLOW}Checking external ports (from host)...${NC}"
PORT_CHECKS=0
PORT_SUCCESS=0

if check_port "localhost" "2379" "etcd1"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "22379" "etcd2"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB1_PORT}" "db1"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB2_PORT}" "db2"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB3_PORT}" "db3"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB4_PORT}" "db4"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${HAPROXY_WRITE_PORT}" "HAProxy Write"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${HAPROXY_READ_PORT}" "HAProxy Read"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${HAPROXY_STATS_PORT}" "HAProxy Stats"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB1_API_PORT}" "db1 Patroni API"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB2_API_PORT}" "db2 Patroni API"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB3_API_PORT}" "db3 Patroni API"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))
if check_port "localhost" "${PATRONI_DB4_API_PORT}" "db4 Patroni API"; then ((PORT_SUCCESS++)); fi
((PORT_CHECKS++))

if [ $PORT_SUCCESS -lt $PORT_CHECKS ]; then
    echo -e "${YELLOW}Note: Some ports may not be accessible from host. This is normal if containers are still starting.${NC}"
fi
echo ""

# Get cluster status
echo -e "${YELLOW}Patroni Cluster Status:${NC}"
if docker exec -it db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null; then
    echo ""
else
    echo -e "${RED}Could not retrieve cluster status${NC}"
    echo ""
fi

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Entrypoints and Usage${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${GREEN}PostgreSQL Connections:${NC}"
echo ""
echo -e "${YELLOW}For WRITE operations (routes to leader only):${NC}"
echo -e "  ${CYAN}psql -h localhost -p ${HAPROXY_WRITE_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL (without password - will prompt):"
echo -e "  ${CYAN}postgresql://postgres@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL (with password):"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_WRITE_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""
echo -e "${YELLOW}For READ operations (routes to replicas only, round-robin):${NC}"
echo -e "  ${CYAN}psql -h localhost -p ${HAPROXY_READ_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL (without password - will prompt):"
echo -e "  ${CYAN}postgresql://postgres@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL (with password):"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${HAPROXY_READ_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""
echo -e "${YELLOW}Direct connections (bypass HAProxy):${NC}"
echo "  # Direct connection to db1"
echo -e "  ${CYAN}psql -h localhost -p ${PATRONI_DB1_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL:"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB1_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""
echo "  # Direct connection to db2"
echo -e "  ${CYAN}psql -h localhost -p ${PATRONI_DB2_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL:"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB2_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""
echo "  # Direct connection to db3"
echo -e "  ${CYAN}psql -h localhost -p ${PATRONI_DB3_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL:"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB3_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""
echo "  # Direct connection to db4"
echo -e "  ${CYAN}psql -h localhost -p ${PATRONI_DB4_PORT} -U postgres -d ${DEFAULT_DATABASE}${NC}"
echo "  # Connection URL:"
echo -e "  ${CYAN}postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PATRONI_DB4_PORT}/${DEFAULT_DATABASE}${NC}"
echo ""

echo -e "${GREEN}Patroni REST API:${NC}"
echo "  # Check db1 status"
echo -e "  ${CYAN}curl http://localhost:${PATRONI_DB1_API_PORT}/patroni${NC}"
echo ""
echo "  # Check db2 status"
echo -e "  ${CYAN}curl http://localhost:${PATRONI_DB2_API_PORT}/patroni${NC}"
echo ""
echo "  # Check db3 status"
echo -e "  ${CYAN}curl http://localhost:${PATRONI_DB3_API_PORT}/patroni${NC}"
echo ""
echo "  # Check db4 status"
echo -e "  ${CYAN}curl http://localhost:${PATRONI_DB4_API_PORT}/patroni${NC}"
echo ""
echo "  # Check cluster status"
echo -e "  ${CYAN}docker exec -it db1 patronictl -c /etc/patroni/patroni.yml list${NC}"
echo ""

echo -e "${GREEN}HAProxy Stats:${NC}"
echo "  # View HAProxy statistics"
echo -e "  ${CYAN}curl http://localhost:${HAPROXY_STATS_PORT}/stats${NC}"
echo -e "  # Or open in browser: ${CYAN}http://localhost:${HAPROXY_STATS_PORT}/stats${NC}"
echo ""

echo -e "${GREEN}etcd Access:${NC}"
echo "  # Check etcd1 health"
echo -e "  ${CYAN}docker exec -it etcd1 etcdctl endpoint health --endpoints=http://etcd1:2379${NC}"
echo ""
echo "  # Check etcd2 health"
echo -e "  ${CYAN}docker exec -it etcd2 etcdctl endpoint health --endpoints=http://etcd2:2379${NC}"
echo ""

echo -e "${GREEN}Useful Commands:${NC}"
echo "  # View all logs"
echo -e "  ${CYAN}docker-compose logs -f${NC}"
echo ""
echo "  # View specific service logs"
echo -e "  ${CYAN}docker-compose logs -f db1${NC}"
echo -e "  ${CYAN}docker-compose logs -f db2${NC}"
echo -e "  ${CYAN}docker-compose logs -f haproxy${NC}"
echo ""
echo "  # Stop the stack"
echo -e "  ${CYAN}docker-compose down${NC}"
echo ""
echo "  # Stop and remove volumes"
echo -e "  ${CYAN}docker-compose down -v${NC}"
echo ""
echo "  # Restart a specific service"
echo -e "  ${CYAN}docker-compose restart db1${NC}"
echo ""

echo -e "${BLUE}========================================${NC}"

