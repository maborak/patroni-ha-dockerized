#!/bin/bash
# Stress test script for PostgreSQL database
# Generates large amounts of data: tables, columns, rows, etc.

set -e
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../"

# Load environment variables
if [ -f .env ]; then
    source .env
fi

# Configuration
DB_HOST_IP="localhost"
DB_PORT="${HAPROXY_WRITE_PORT:-5551}"
DB_NAME="${DEFAULT_DATABASE:-maborak}"
DB_USER="postgres"
DB_PASSWORD="${POSTGRES_PASSWORD:-Dgo7cQ41WDTnd89G46TgfVtr}"

# Stress test parameters (can be overridden via environment variables)
NUM_TABLES="${NUM_TABLES:-10}"
ROWS_PER_TABLE="${ROWS_PER_TABLE:-1000}"
COLS_PER_TABLE="${COLS_PER_TABLE:-10}"
BATCH_SIZE="${BATCH_SIZE:-50}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  PostgreSQL Stress Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Configuration:"
echo -e "  Database: ${GREEN}${DB_NAME}${NC}"
echo -e "  Host:Port: ${GREEN}${DB_HOST_IP}:${DB_PORT}${NC}"
echo -e "  Tables: ${GREEN}${NUM_TABLES}${NC}"
echo -e "  Rows per table: ${GREEN}${ROWS_PER_TABLE}${NC}"
echo -e "  Columns per table: ${GREEN}${COLS_PER_TABLE}${NC}"
echo -e "  Batch size: ${GREEN}${BATCH_SIZE}${NC}"
echo ""

# Check if database is accessible
echo -e "${YELLOW}Checking database connectivity...${NC}"
if ! PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to database!${NC}"
    echo "  Host: ${DB_HOST_IP}:${DB_PORT}"
    echo "  Database: ${DB_NAME}"
    echo "  User: ${DB_USER}"
    exit 1
fi
echo -e "${GREEN}✓ Database connection successful${NC}"
echo ""

# Function to generate random string (optimized for speed)
generate_random_string() {
    local len=${1:-32}
    # Use openssl rand as primary method (fastest)
    openssl rand -base64 $((len * 3 / 4 + 1)) 2>/dev/null | tr -d '\n/+=' | head -c ${len} || \
    # Fallback to simpler method
    echo "$(date +%s)${RANDOM}${RANDOM}" | md5sum | head -c ${len} || \
    # Last resort
    printf "%0${len}d" $RANDOM
}

# Function to show progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    # Use stderr to avoid buffering issues and ensure immediate display
    printf "\r  [" >&2
    printf "%${filled}s" | tr ' ' '=' >&2
    printf "%${empty}s" | tr ' ' ' ' >&2
    printf "] %3d%% (%d/%d)" $percentage $current $total >&2
}

# Function to generate column definitions
generate_columns() {
    local num_cols=$1
    local cols=""
    for i in $(seq 1 $num_cols); do
        case $((i % 5)) in
            0) cols="${cols}, col_${i}_text TEXT" ;;
            1) cols="${cols}, col_${i}_int INTEGER" ;;
            2) cols="${cols}, col_${i}_bigint BIGINT" ;;
            3) cols="${cols}, col_${i}_varchar VARCHAR(255)" ;;
            4) cols="${cols}, col_${i}_numeric NUMERIC(10,2)" ;;
        esac
    done
    echo "$cols"
}

# Function to generate INSERT values
generate_insert_values() {
    local num_cols=$1
    local values=""
    for i in $(seq 1 $num_cols); do
        case $((i % 5)) in
            0) values="${values}, '$(generate_random_string 50)'" ;;
            1) values="${values}, $((RANDOM % 1000000))" ;;
            2) values="${values}, $((RANDOM * RANDOM))" ;;
            3) values="${values}, '$(generate_random_string 100)'" ;;
            4) values="${values}, $((RANDOM % 10000)).$((RANDOM % 100))" ;;
        esac
    done
    echo "$values"
}

# Start timing
START_TIME=$(date +%s)

# Create tables
echo -e "${YELLOW}Creating ${NUM_TABLES} tables...${NC}"
echo -e "${YELLOW}Writing to HAProxy write port: ${DB_HOST_IP}:${DB_PORT}${NC}"
echo ""
for i in $(seq 1 $NUM_TABLES); do
    TABLE_NAME="stress_table_$(printf "%03d" $i)"
    # Drop table if it exists to ensure clean state with correct column count
    PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q -c "DROP TABLE IF EXISTS ${TABLE_NAME} CASCADE;" > /dev/null 2>&1
    COLS=$(generate_columns $COLS_PER_TABLE)
    
    if PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q <<EOF > /dev/null 2>&1
CREATE TABLE ${TABLE_NAME} (
    id SERIAL PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP${COLS}
);
CREATE INDEX IF NOT EXISTS idx_${TABLE_NAME}_created ON ${TABLE_NAME}(created_at);
EOF
    then
        show_progress $i $NUM_TABLES
    else
        echo -e "\n${RED}ERROR: Failed to create table ${TABLE_NAME}${NC}"
    fi
done
echo -e "\n${GREEN}✓ All tables created${NC}"
echo ""

# Insert data
echo -e "${YELLOW}Inserting ${ROWS_PER_TABLE} rows into each table (${NUM_TABLES} tables)...${NC}"
echo -e "${YELLOW}Writing to HAProxy write port: ${DB_HOST_IP}:${DB_PORT}${NC}"
echo ""
TOTAL_ROWS=0
TOTAL_INSERTS=$((NUM_TABLES * ROWS_PER_TABLE))
CURRENT_INSERTS=0
# Initialize progress bar (use stderr to avoid buffering)
show_progress 0 $TOTAL_INSERTS

for i in $(seq 1 $NUM_TABLES); do
    TABLE_NAME="stress_table_$(printf "%03d" $i)"
    # Get column definitions for CREATE TABLE
    COLS_DEF=$(generate_columns $COLS_PER_TABLE | sed 's/^, //' | sed 's/, /, /g')
    # Get column names only for INSERT (extract from column definitions)
    # Pattern: extract column name before the type (e.g., "col_1_int INTEGER" -> "col_1_int")
    COLS=$(echo "$COLS_DEF" | sed -E 's/ (INTEGER|BIGINT|VARCHAR\(255\)|NUMERIC\(10,2\)|TEXT)//g')
    
    # Count columns (should match COLS_PER_TABLE)
    NUM_COLS=$COLS_PER_TABLE
    
    # Insert in batches
    BATCHES=$((ROWS_PER_TABLE / BATCH_SIZE))
    if [ $BATCHES -eq 0 ]; then
        BATCHES=1
    fi
    
    for batch in $(seq 1 $BATCHES); do
        ROWS_IN_BATCH=$BATCH_SIZE
        if [ $batch -eq $BATCHES ] && [ $((ROWS_PER_TABLE % BATCH_SIZE)) -ne 0 ]; then
            ROWS_IN_BATCH=$((ROWS_PER_TABLE % BATCH_SIZE))
        fi
        
        # Generate batch INSERT (optimized for large batches)
        INSERT_SQL="INSERT INTO ${TABLE_NAME} (${COLS}) VALUES "
        VALUES_LIST=""
        
        # Show progress during SQL generation for large batches
        if [ $ROWS_IN_BATCH -gt 20 ]; then
            printf "\r  Generating SQL for batch ${batch}/${BATCHES} (${ROWS_IN_BATCH} rows)..." >&2
        fi
        
        for row in $(seq 1 $ROWS_IN_BATCH); do
            VALUES=$(generate_insert_values $NUM_COLS | sed 's/^, //')
            if [ -n "$VALUES_LIST" ]; then
                VALUES_LIST="${VALUES_LIST}, "
            fi
            VALUES_LIST="${VALUES_LIST}(${VALUES})"
            
            # Show progress every 10 rows for large batches
            if [ $ROWS_IN_BATCH -gt 20 ] && [ $((row % 10)) -eq 0 ]; then
                printf "\r  Generating SQL for batch ${batch}/${BATCHES} (${row}/${ROWS_IN_BATCH} rows)..." >&2
            fi
        done
        
        INSERT_SQL="${INSERT_SQL}${VALUES_LIST};"
        
        # Clear the generation message
        if [ $ROWS_IN_BATCH -gt 20 ]; then
            printf "\r" >&2
        fi
        
        # Execute insert and show progress (update progress immediately after insert)
        # Debug: Show SQL length and first 100 chars
        if [ "${DEBUG:-}" = "1" ]; then
            echo -e "\n${YELLOW}DEBUG: Table: ${TABLE_NAME}, Batch: ${batch}/${BATCHES}, Rows: ${ROWS_IN_BATCH}${NC}" >&2
            echo -e "${YELLOW}DEBUG: SQL length: ${#INSERT_SQL} chars${NC}" >&2
            echo -e "${YELLOW}DEBUG: SQL preview: ${INSERT_SQL:0:200}...${NC}" >&2
        fi
        
        INSERT_RESULT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q -c "$INSERT_SQL" 2>&1)
        INSERT_EXIT_CODE=$?
        
        if [ $INSERT_EXIT_CODE -eq 0 ]; then
            TOTAL_ROWS=$((TOTAL_ROWS + ROWS_IN_BATCH))
            CURRENT_INSERTS=$((CURRENT_INSERTS + ROWS_IN_BATCH))
            # Update progress bar after each successful batch
            show_progress $CURRENT_INSERTS $TOTAL_INSERTS
        else
            printf "\n"
            echo -e "${RED}ERROR: Failed to insert into ${TABLE_NAME} (batch ${batch}/${BATCHES})${NC}"
            echo -e "${RED}Exit code: ${INSERT_EXIT_CODE}${NC}"
            echo -e "${RED}Error output:${NC}"
            echo "$INSERT_RESULT" | sed 's/^/  /'
            if [ "${DEBUG:-}" = "1" ]; then
                echo -e "${RED}DEBUG: SQL length: ${#INSERT_SQL} chars${NC}"
                echo -e "${RED}DEBUG: SQL (first 500 chars): ${INSERT_SQL:0:500}${NC}"
            fi
            # Still update progress to show we tried
            CURRENT_INSERTS=$((CURRENT_INSERTS + ROWS_IN_BATCH))
            show_progress $CURRENT_INSERTS $TOTAL_INSERTS
        fi
    done
done
echo -e "\n${GREEN}✓ All data inserted (${TOTAL_ROWS} total rows)${NC}"
echo ""

# Update some rows
echo -e "${YELLOW}Updating random rows (10% of each table)...${NC}"
TOTAL_UPDATES=$NUM_TABLES
CURRENT_UPDATES=0
for i in $(seq 1 $NUM_TABLES); do
    TABLE_NAME="stress_table_$(printf "%03d" $i)"
    UPDATE_COUNT=$((ROWS_PER_TABLE / 10))  # Update 10% of rows
    
    if PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q <<EOF > /dev/null 2>&1
UPDATE ${TABLE_NAME}
SET updated_at = CURRENT_TIMESTAMP,
    col_1_varchar = 'UPDATED_' || col_1_varchar
WHERE id IN (
    SELECT id FROM ${TABLE_NAME} ORDER BY RANDOM() LIMIT ${UPDATE_COUNT}
);
EOF
    then
        CURRENT_UPDATES=$((CURRENT_UPDATES + 1))
        show_progress $CURRENT_UPDATES $TOTAL_UPDATES
    else
        echo -e "\n${RED}ERROR: Failed to update ${TABLE_NAME}${NC}"
    fi
done
echo -e "\n${GREEN}✓ Updates completed${NC}"
echo ""

# Run some queries
echo -e "${YELLOW}Running test queries...${NC}"
for i in $(seq 1 5); do
    TABLE_NAME="stress_table_$(printf "%03d" $((RANDOM % NUM_TABLES + 1)))"
    
    echo -e "  Query ${i}/5: SELECT COUNT(*) FROM ${TABLE_NAME}..."
    COUNT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT COUNT(*) FROM ${TABLE_NAME};" | tr -d ' ')
    echo -e "    ${GREEN}✓${NC} Count: ${COUNT} rows"
done
echo ""

# Get database statistics
echo -e "${YELLOW}Database Statistics:${NC}"
TOTAL_TABLES=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'stress_table_%';" | tr -d ' ')
TOTAL_ROWS=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT SUM(n_live_tup) FROM pg_stat_user_tables WHERE schemaname = 'public' AND relname LIKE 'stress_table_%';" | tr -d ' ')
DB_SIZE=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST_IP}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'));" | tr -d ' ')

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "  Total tables created: ${GREEN}${TOTAL_TABLES}${NC}"
echo -e "  Total rows inserted: ${GREEN}${TOTAL_ROWS}${NC}"
echo -e "  Database size: ${GREEN}${DB_SIZE}${NC}"
echo -e "  Duration: ${GREEN}${DURATION}${NC} seconds"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Stress test completed successfully!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "To clean up the test data, run:"
echo -e "  ${YELLOW}PGPASSWORD=\"${DB_PASSWORD}\" psql -h ${DB_HOST_IP} -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} -c \"DROP TABLE IF EXISTS stress_table_001, stress_table_002, ... CASCADE;\"${NC}"
echo ""
echo -e "Or use the cleanup script:"
echo -e "  ${YELLOW}./scripts/testing/cleanup_stress_test.sh${NC}"

