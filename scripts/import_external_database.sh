#!/bin/bash

# Script to backup and import an external PostgreSQL database to the Patroni cluster master

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

POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}

# Check if pv (pipe viewer) is available for progress bars
PV_AVAILABLE=false
if command -v pv &> /dev/null; then
    PV_AVAILABLE=true
fi

# Parse command line arguments
CONN_STRING=""
TARGET_DB=""

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage:${NC} $0 --from <postgresql_connection_string> [--target-db <database_name>]"
    echo ""
    echo -e "${CYAN}Options:${NC}"
    echo -e "  ${BOLD}--from${NC}          PostgreSQL connection string (required)"
    echo -e "                          Format: postgresql://user:password@host:port/database"
    echo -e "  ${BOLD}--target-db${NC}     Target database name (optional, defaults to source database name)"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  $0 --from postgresql://amazon:amazon@127.0.0.1:2345/amazon"
    echo -e "  $0 --from postgresql://user:pass@localhost:5432/mydb --target-db mydb_imported"
    echo ""
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --from)
            CONN_STRING="$2"
            shift 2
            ;;
        --target-db)
            TARGET_DB="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            show_usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$CONN_STRING" ]; then
    echo -e "${RED}Error: --from option is required${NC}"
    echo ""
    show_usage
fi

# Parse PostgreSQL connection string: postgresql://user:password@host:port/database
if [[ "$CONN_STRING" =~ postgresql://([^:]+):([^@]+)@([^:]+):([^/]+)/(.+) ]]; then
    SOURCE_USER="${BASH_REMATCH[1]}"
    SOURCE_PASSWORD="${BASH_REMATCH[2]}"
    SOURCE_HOST="${BASH_REMATCH[3]}"
    SOURCE_PORT="${BASH_REMATCH[4]}"
    SOURCE_DB="${BASH_REMATCH[5]}"
else
    echo -e "${RED}Error: Invalid connection string format${NC}"
    echo -e "${YELLOW}Expected format: postgresql://user:password@host:port/database${NC}"
    echo -e "${YELLOW}Received: ${CONN_STRING}${NC}"
    exit 1
fi

# Target database name (default to source database name)
if [ -z "$TARGET_DB" ]; then
    TARGET_DB="${SOURCE_DB}"
fi

echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  External Database Import${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Source Database:${NC}"
echo -e "  ${BOLD}Host:${NC} ${SOURCE_HOST}"
echo -e "  ${BOLD}Port:${NC} ${SOURCE_PORT}"
echo -e "  ${BOLD}Database:${NC} ${SOURCE_DB}"
echo -e "  ${BOLD}User:${NC} ${SOURCE_USER}"
echo ""

# Detect leader node
echo -e "${YELLOW}Detecting cluster leader...${NC}"
LEADER_NODE=""
PATRONI_LIST=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
if [ -n "$PATRONI_LIST" ]; then
    LEADER_NODE=$(echo "$PATRONI_LIST" | grep -i "Leader" | awk '{print $2}' | head -1)
    if [ -n "$LEADER_NODE" ]; then
        echo -e "${GREEN}✓ Found leader: ${LEADER_NODE}${NC}"
    fi
fi

# Fallback: Try REST API
if [ -z "$LEADER_NODE" ]; then
    for node in db1 db2 db3 db4; do
        role=$(docker exec "$node" sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
        if [ "$role" = "primary" ] || [ "$role" = "Leader" ]; then
            LEADER_NODE="$node"
            echo -e "${GREEN}✓ Found leader via REST API: ${LEADER_NODE}${NC}"
            break
        fi
    done
fi

if [ -z "$LEADER_NODE" ]; then
    echo -e "${YELLOW}⚠ Warning: Could not detect leader, defaulting to db1${NC}"
    LEADER_NODE="db1"
fi

echo ""
echo -e "${CYAN}Target Database:${NC}"
echo -e "  ${BOLD}Container:${NC} ${LEADER_NODE} ${GREEN}(cluster leader)${NC}"
echo -e "  ${BOLD}Database:${NC} ${TARGET_DB}"
echo -e "  ${BOLD}Port:${NC} 5431 (internal)"
echo ""

# Show notice about missing pv if not available
if [ "$PV_AVAILABLE" = false ]; then
    echo -e "${YELLOW}ℹ Note:${NC} ${CYAN}pv${NC} (pipe viewer) is not installed. Progress bars will not be displayed."
    echo -e "   Install it to enable progress bars: ${BOLD}sudo apt-get install pv${NC} (Debian/Ubuntu)"
    echo -e "   or ${BOLD}sudo yum install pv${NC} (RHEL/CentOS) or ${BOLD}brew install pv${NC} (macOS)"
    echo ""
fi

# Check if target database exists
echo -e "${YELLOW}Checking if target database exists...${NC}"
DB_EXISTS=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" 2>/dev/null || echo "0")

if [ "$DB_EXISTS" = "1" ]; then
    echo -e "${YELLOW}⚠ Warning: Database '${TARGET_DB}' already exists!${NC}"
    read -p "Do you want to drop and recreate it? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo -e "${RED}Aborted by user${NC}"
        exit 1
    fi
    echo -e "${YELLOW}Dropping existing database...${NC}"
    docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -c "DROP DATABASE IF EXISTS \"${TARGET_DB}\";" || {
        echo -e "${RED}Error: Failed to drop database${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ Database dropped${NC}"
else
    echo -e "${GREEN}✓ Target database does not exist, will be created${NC}"
fi

# Create temporary backup file
BACKUP_FILE="/tmp/amazon_monitor_backup_$(date +%Y%m%d_%H%M%S).sql"
BACKUP_FILE_CONTAINER="/tmp/amazon_monitor_backup_$(date +%Y%m%d_%H%M%S).sql"

echo ""
echo -e "${CYAN}Step 1: Creating backup from source database...${NC}"
echo -e "${YELLOW}This may take a while depending on database size...${NC}"

# Check if pg_dump is available locally or in a container
if command -v pg_dump &> /dev/null; then
    # Use local pg_dump
    echo -e "${CYAN}Using local pg_dump...${NC}"
    if [ "$PV_AVAILABLE" = true ]; then
        PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
            -h "$SOURCE_HOST" \
            -p "$SOURCE_PORT" \
            -U "$SOURCE_USER" \
            -d "$SOURCE_DB" \
            --no-owner \
            --no-privileges \
            --clean \
            --if-exists \
            -F p \
            2>&1 | pv -N "Backing up" -s 0 > "$BACKUP_FILE" || {
            echo -e "${RED}Error: Failed to create backup${NC}"
            exit 1
        }
    else
        PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
            -h "$SOURCE_HOST" \
            -p "$SOURCE_PORT" \
            -U "$SOURCE_USER" \
            -d "$SOURCE_DB" \
            --no-owner \
            --no-privileges \
            --clean \
            --if-exists \
            -F p \
            > "$BACKUP_FILE" || {
            echo -e "${RED}Error: Failed to create backup${NC}"
            exit 1
        }
    fi
else
    # Use pg_dump from a PostgreSQL container
    echo -e "${CYAN}Using pg_dump from PostgreSQL container...${NC}"
    
    # If source host is localhost or 127.0.0.1, use host network mode to access host services
    DOCKER_NETWORK_ARGS=""
    if [ "$SOURCE_HOST" = "127.0.0.1" ] || [ "$SOURCE_HOST" = "localhost" ]; then
        echo -e "${YELLOW}Note: Using host network mode to access host database at ${SOURCE_HOST}:${SOURCE_PORT}${NC}"
        DOCKER_NETWORK_ARGS="--network host"
    fi
    
    if [ "$PV_AVAILABLE" = true ]; then
        docker run --rm $DOCKER_NETWORK_ARGS \
            -e PGPASSWORD="$SOURCE_PASSWORD" \
            postgres:17 \
            pg_dump \
            -h "$SOURCE_HOST" \
            -p "$SOURCE_PORT" \
            -U "$SOURCE_USER" \
            -d "$SOURCE_DB" \
            --no-owner \
            --no-privileges \
            --clean \
            --if-exists \
            -F p \
            2>&1 | pv -N "Backing up" -s 0 > "$BACKUP_FILE" || {
            echo -e "${RED}Error: Failed to create backup${NC}"
            exit 1
        }
    else
        docker run --rm $DOCKER_NETWORK_ARGS \
            -e PGPASSWORD="$SOURCE_PASSWORD" \
            postgres:17 \
            pg_dump \
            -h "$SOURCE_HOST" \
            -p "$SOURCE_PORT" \
            -U "$SOURCE_USER" \
            -d "$SOURCE_DB" \
            --no-owner \
            --no-privileges \
            --clean \
            --if-exists \
            -F p \
            > "$BACKUP_FILE" || {
            echo -e "${RED}Error: Failed to create backup${NC}"
            exit 1
        }
    fi
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo -e "${GREEN}✓ Backup created successfully (${BACKUP_SIZE})${NC}"

# Copy backup file to container
echo ""
echo -e "${CYAN}Step 2: Copying backup to container...${NC}"
docker cp "$BACKUP_FILE" "${LEADER_NODE}:${BACKUP_FILE_CONTAINER}" || {
    echo -e "${RED}Error: Failed to copy backup to container${NC}"
    rm -f "$BACKUP_FILE"
    exit 1
}
echo -e "${GREEN}✓ Backup copied to container${NC}"

# Create target database
echo ""
echo -e "${CYAN}Step 3: Creating target database...${NC}"
docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -c "CREATE DATABASE \"${TARGET_DB}\";" || {
    echo -e "${RED}Error: Failed to create target database${NC}"
    docker exec "$LEADER_NODE" rm -f "$BACKUP_FILE_CONTAINER"
    rm -f "$BACKUP_FILE"
    exit 1
}
echo -e "${GREEN}✓ Target database created${NC}"

# Import backup
echo ""
echo -e "${CYAN}Step 4: Importing backup to target database...${NC}"
echo -e "${YELLOW}This may take a while depending on database size...${NC}"

# Get backup file size for progress bar
if [ "$PV_AVAILABLE" = true ]; then
    BACKUP_SIZE_BYTES=$(stat -f%z "$BACKUP_FILE" 2>/dev/null || stat -c%s "$BACKUP_FILE" 2>/dev/null || echo "0")
    if [ "$BACKUP_SIZE_BYTES" != "0" ]; then
        # Use pv to show progress during import by piping through docker exec
        pv -s "$BACKUP_SIZE_BYTES" -N "Importing" "$BACKUP_FILE" | \
        docker exec -i "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" > /dev/null 2>&1 || {
            echo -e "${RED}Error: Failed to import backup${NC}"
            echo -e "${YELLOW}Note: Some errors may be expected (e.g., 'does not exist' for DROP statements)${NC}"
            # Check if import actually succeeded despite errors
            TABLE_COUNT=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
            if [ "$TABLE_COUNT" = "0" ]; then
                echo -e "${RED}Import failed - no tables found in target database${NC}"
                docker exec "$LEADER_NODE" rm -f "$BACKUP_FILE_CONTAINER"
                rm -f "$BACKUP_FILE"
                exit 1
            else
                echo -e "${YELLOW}⚠ Import completed with warnings, but ${TABLE_COUNT} tables were imported${NC}"
            fi
        }
    else
        # Fallback if we can't get file size
        docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -f "$BACKUP_FILE_CONTAINER" > /dev/null 2>&1 || {
            echo -e "${RED}Error: Failed to import backup${NC}"
            echo -e "${YELLOW}Note: Some errors may be expected (e.g., 'does not exist' for DROP statements)${NC}"
            # Check if import actually succeeded despite errors
            TABLE_COUNT=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
            if [ "$TABLE_COUNT" = "0" ]; then
                echo -e "${RED}Import failed - no tables found in target database${NC}"
                docker exec "$LEADER_NODE" rm -f "$BACKUP_FILE_CONTAINER"
                rm -f "$BACKUP_FILE"
                exit 1
            else
                echo -e "${YELLOW}⚠ Import completed with warnings, but ${TABLE_COUNT} tables were imported${NC}"
            fi
        }
    fi
else
    docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -f "$BACKUP_FILE_CONTAINER" > /dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to import backup${NC}"
        echo -e "${YELLOW}Note: Some errors may be expected (e.g., 'does not exist' for DROP statements)${NC}"
        # Check if import actually succeeded despite errors
        TABLE_COUNT=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
        if [ "$TABLE_COUNT" = "0" ]; then
            echo -e "${RED}Import failed - no tables found in target database${NC}"
            docker exec "$LEADER_NODE" rm -f "$BACKUP_FILE_CONTAINER"
            rm -f "$BACKUP_FILE"
            exit 1
        else
            echo -e "${YELLOW}⚠ Import completed with warnings, but ${TABLE_COUNT} tables were imported${NC}"
        fi
    }
fi

# Clean up backup files
echo ""
echo -e "${CYAN}Step 5: Cleaning up...${NC}"
docker exec "$LEADER_NODE" rm -f "$BACKUP_FILE_CONTAINER"
rm -f "$BACKUP_FILE"
echo -e "${GREEN}✓ Cleanup completed${NC}"

# Verify import
echo ""
echo -e "${CYAN}Step 6: Verifying import...${NC}"
TABLE_COUNT=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
SCHEMA_COUNT=$(docker exec "$LEADER_NODE" psql -U postgres -p 5431 -h localhost -d "$TARGET_DB" -tAc "SELECT COUNT(DISTINCT table_schema) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema');" 2>/dev/null || echo "0")

echo -e "${GREEN}✓ Import verification:${NC}"
echo -e "  ${BOLD}Tables imported:${NC} ${TABLE_COUNT}"
echo -e "  ${BOLD}Schemas:${NC} ${SCHEMA_COUNT}"

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Import Completed Successfully!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Connection Details:${NC}"
echo -e "  ${BOLD}Container:${NC} ${LEADER_NODE}"
echo -e "  ${BOLD}Database:${NC} ${TARGET_DB}"
echo -e "  ${BOLD}Command:${NC} docker exec -it ${LEADER_NODE} psql -U postgres -d ${TARGET_DB} -p 5431 -h localhost"
echo ""
echo -e "${YELLOW}Note: The database will be replicated to all cluster nodes automatically${NC}"
echo ""

