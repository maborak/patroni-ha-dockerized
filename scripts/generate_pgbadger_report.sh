#!/bin/bash

# Script to generate pgBadger reports from PostgreSQL logs
# Usage: ./generate_pgbadger_report.sh [options]
#
# Options:
#   --node <node>        Target specific node (db1, db2, db3, db4)
#   --all-nodes         Generate reports for all nodes
#   --date <date>       Specific date (YYYY-MM-DD) or "today", "yesterday" (default: today)
#   --output-dir <dir>  Output directory (default: ./reports)
#   --format <format>   Output format: html, json, text (default: html)
#   --verbose           Show detailed output

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
TARGET_DATE="today"
OUTPUT_DIR="./reports"
OUTPUT_FORMAT="html"
VERBOSE=false

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
        --date)
            TARGET_DATE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            if [[ ! "$OUTPUT_FORMAT" =~ ^(html|json|text)$ ]]; then
                echo -e "${RED}Invalid format: $OUTPUT_FORMAT${NC}"
                echo -e "${YELLOW}Valid formats: html, json, text${NC}"
                exit 1
            fi
            shift 2
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
            echo "  --all-nodes         Generate reports for all nodes"
            echo "  --date <date>       Date: YYYY-MM-DD, 'today', or 'yesterday' (default: today)"
            echo "  --output-dir <dir>  Output directory (default: ./reports)"
            echo "  --format <format>   Output format: html, json, text (default: html)"
            echo "  --verbose           Show detailed output"
            echo ""
            echo "Examples:"
            echo "  $0                                    # HTML report for leader, today"
            echo "  $0 --node db2 --date yesterday        # Report for db2, yesterday"
            echo "  $0 --all-nodes --format json          # JSON reports for all nodes"
            echo "  $0 --date 2026-01-05 --format html    # HTML report for specific date"
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

# Function to parse date
parse_date() {
    local date_input=$1
    case $date_input in
        today)
            date +%Y-%m-%d
            ;;
        yesterday)
            date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo ""
            ;;
        *)
            # Validate date format
            if [[ $date_input =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                echo "$date_input"
            else
                echo ""
            fi
            ;;
    esac
}

# Parse target date
PARSED_DATE=$(parse_date "$TARGET_DATE")
if [ -z "$PARSED_DATE" ]; then
    echo -e "${RED}Invalid date format: $TARGET_DATE${NC}"
    echo -e "${YELLOW}Use YYYY-MM-DD, 'today', or 'yesterday'${NC}"
    exit 1
fi

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
echo -e "${BLUE}${BOLD}  pgBadger Report Generator${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Target Date:${NC} ${BOLD}${PARSED_DATE}${NC}"
echo -e "${CYAN}Target Nodes:${NC} ${BOLD}${NODES[*]}${NC}"
echo -e "${CYAN}Output Format:${NC} ${BOLD}${OUTPUT_FORMAT}${NC}"
echo -e "${CYAN}Output Directory:${NC} ${BOLD}${OUTPUT_DIR}${NC}"
echo ""

# Process each node
TOTAL_SUCCESS=0
TOTAL_FAILED=0

for node in "${NODES[@]}"; do
    echo -e "${YELLOW}[Processing ${node}]${NC}"
    
    # Check if node container exists
    if ! docker ps --format '{{.Names}}' | grep -q "^${node}$"; then
        echo -e "${RED}  ✗ Container ${node} is not running${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    # Find log files for the target date
    # PostgreSQL creates two log files when using 'stderr,jsonlog':
    # 1. .json file: stderr output (text format) - NOT what we need
    # 2. .json.json file: jsonlog output (JSON format) - THIS is what we need for pgBadger
    # For new configs (after fix), .json files will be JSON format
    LOG_PATTERN="postgresql-${PARSED_DATE}*"
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}  Searching for log files: ${LOG_PATTERN}${NC}"
    fi
    
    # First, try to find .json.json files (actual JSON logs from current config)
    LOG_FILES=$(docker exec "$node" find /var/log/postgresql -name "${LOG_PATTERN}.json.json" -type f 2>/dev/null | sort || echo "")
    
    # If no .json.json files, check .json files to see if they're JSON format
    if [ -z "$LOG_FILES" ]; then
        ALL_JSON_FILES=$(docker exec "$node" find /var/log/postgresql -name "${LOG_PATTERN}.json" -type f ! -name "*.json.json" 2>/dev/null | sort || echo "")
        
        # Check each .json file to see if it's actually JSON format
        for file in $ALL_JSON_FILES; do
            # Check if file starts with { (JSON format indicator)
            first_char=$(docker exec "$node" head -c 1 "$file" 2>/dev/null | tr -d '\n' || echo "")
            if [ "$first_char" = "{" ]; then
                # This is a JSON format file
                if [ -z "$LOG_FILES" ]; then
                    LOG_FILES="$file"
                else
                    LOG_FILES="$LOG_FILES
$file"
                fi
            fi
        done
    fi
    
    if [ -z "$LOG_FILES" ]; then
        echo -e "${YELLOW}  ⚠ No log files found for ${PARSED_DATE} on ${node}${NC}"
        echo -e "${CYAN}  Available log files:${NC}"
        docker exec "$node" ls -1 /var/log/postgresql/*.json 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (none found)"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    LOG_COUNT=$(echo "$LOG_FILES" | wc -l | tr -d ' ')
    echo -e "${CYAN}  Found ${LOG_COUNT} log file(s)${NC}"
    
    if [ "$VERBOSE" = true ]; then
        echo "$LOG_FILES" | sed 's/^/    /'
    fi
    
    # Create temporary directory for log files
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    # Copy log files to temporary directory
    echo -e "${CYAN}  Copying log files...${NC}"
    for log_file in $LOG_FILES; do
        filename=$(basename "$log_file")
        docker cp "${node}:${log_file}" "${TEMP_DIR}/${filename}" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            if [ "$VERBOSE" = true ]; then
                echo -e "${GREEN}    ✓ Copied: ${filename}${NC}"
            fi
        else
            echo -e "${YELLOW}    ⚠ Failed to copy: ${filename}${NC}"
        fi
    done
    
    # Check if we have any log files
    if [ -z "$(ls -A ${TEMP_DIR}/*.json 2>/dev/null)" ]; then
        echo -e "${RED}  ✗ No log files copied${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        continue
    fi
    
    # Generate output filenames
    OUTPUT_FILE_HOST="${OUTPUT_DIR}/pgbadger-${node}-${PARSED_DATE}.${OUTPUT_FORMAT}"
    OUTPUT_FILE_CONTAINER="/var/lib/barman/pgbadger-reports/pgbadger-${node}-${PARSED_DATE}.${OUTPUT_FORMAT}"
    
    # Build pgBadger command
    # For JSON logs, pgBadger auto-detects format, but we can specify it explicitly
    # Note: When using jsonlog format, prefix is not needed (JSON has structured fields)
    PGBADGER_OPTS=(
        -f jsonlog
        -x "$OUTPUT_FORMAT"
        --outfile "$OUTPUT_FILE_CONTAINER"
    )
    
    # Prefix is only needed for stderr/csvlog formats, not for jsonlog
    # JSON logs have structured fields, so prefix parsing is not required
    
    # Add format-specific options
    case $OUTPUT_FORMAT in
        html)
            PGBADGER_OPTS+=(--jobs 2)
            ;;
        json)
            PGBADGER_OPTS+=(--jobs 2)
            ;;
        text)
            PGBADGER_OPTS+=(--jobs 2)
            ;;
    esac
    
    if [ "$VERBOSE" = true ]; then
        PGBADGER_OPTS+=(--verbose)
    fi
    
    # Run pgBadger
    echo -e "${CYAN}  Generating ${OUTPUT_FORMAT} report...${NC}"
    start_time=$(date +%s)
    
    # Copy log files to barman container and run pgBadger there
    docker exec barman mkdir -p /tmp/pgbadger-logs-${node} >/dev/null 2>&1
    docker cp "${TEMP_DIR}/." "barman:/tmp/pgbadger-logs-${node}/" >/dev/null 2>&1
    
    # Get list of log files in container (explicit list to avoid wildcard issues)
    LOG_FILES_LIST=$(docker exec barman sh -c "ls -1 /tmp/pgbadger-logs-${node}/*.json 2>/dev/null" | tr '\n' ' ')
    
    if [ -z "$LOG_FILES_LIST" ]; then
        echo -e "${RED}  ✗ No log files found in container after copy${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        docker exec barman rm -rf /tmp/pgbadger-logs-${node} >/dev/null 2>&1
        continue
    fi
    
    # Build pgBadger command with explicit file list
    # Pass options and files as separate arguments
    PGBADGER_ARGS=()
    for opt in "${PGBADGER_OPTS[@]}"; do
        PGBADGER_ARGS+=("$opt")
    done
    # Add log files explicitly (split by space)
    for log_file in $LOG_FILES_LIST; do
        PGBADGER_ARGS+=("$log_file")
    done
    
    # Run pgBadger with explicit file list
    if docker exec barman pgbadger "${PGBADGER_ARGS[@]}" 2>&1; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        # Copy report back to host (using the mounted volume)
        if [ -f "${OUTPUT_DIR}/pgbadger-${node}-${PARSED_DATE}.${OUTPUT_FORMAT}" ]; then
            echo -e "${GREEN}  ✓ Report generated: ${OUTPUT_FILE_HOST} (${duration}s)${NC}"
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
            
            # Show file size
            FILE_SIZE=$(du -h "$OUTPUT_FILE_HOST" | cut -f1)
            echo -e "${CYAN}    File size: ${FILE_SIZE}${NC}"
        else
            # Try to copy from container
            if docker cp "barman:${OUTPUT_FILE_CONTAINER}" "${OUTPUT_FILE_HOST}" >/dev/null 2>&1; then
                echo -e "${GREEN}  ✓ Report generated: ${OUTPUT_FILE_HOST} (${duration}s)${NC}"
                TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
                
                # Show file size
                FILE_SIZE=$(du -h "$OUTPUT_FILE_HOST" | cut -f1)
                echo -e "${CYAN}    File size: ${FILE_SIZE}${NC}"
            else
                echo -e "${YELLOW}  ⚠ Report generated but failed to copy to host${NC}"
                echo -e "${CYAN}    Report location in container: ${OUTPUT_FILE_CONTAINER}${NC}"
                TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
            fi
        fi
        
        # Cleanup
        docker exec barman rm -rf /tmp/pgbadger-logs-${node} >/dev/null 2>&1
    else
        echo -e "${RED}  ✗ Failed to generate report${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
    
    # Cleanup temp directory
    rm -rf "$TEMP_DIR"
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
if [ "$OUTPUT_FORMAT" = "html" ] && [ $TOTAL_SUCCESS -gt 0 ]; then
    echo -e "${CYAN}Open reports in browser:${NC}"
    for node in "${NODES[@]}"; do
        report_file="${OUTPUT_DIR}/pgbadger-${node}-${PARSED_DATE}.html"
        if [ -f "$report_file" ]; then
            echo -e "  file://$(realpath "$report_file")"
        fi
    done
fi
echo ""

if [ $TOTAL_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi

