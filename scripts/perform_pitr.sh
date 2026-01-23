#!/bin/bash

# Script to perform Point-In-Time Recovery (PITR) with Barman
# Usage: ./perform_pitr.sh <backup-id> <target-time> [--target <node>]
#
# Environment Variables:
#   PATRONI_CLUSTER_NAME - Name of the Patroni cluster (default: "patroni1")
#                          Example: PATRONI_CLUSTER_NAME=mycluster ./perform_pitr.sh ...

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Cluster configuration
# Cluster name can be set via PATRONI_CLUSTER_NAME environment variable
# Defaults to "patroni1" if not set
PATRONI_CLUSTER_NAME="${PATRONI_CLUSTER_NAME:-patroni1}"

# Parse arguments
AUTO_APPLY=false
TARGET_NODE=""
BACKUP_ID=""
TARGET_TIME=""
START_RESTORE=false
BACKUP_SERVER=""
WAL_METHOD="barman-wal-restore"  # Default: barman-wal-restore or barman-get-wal
AUTO_START=false  # Default: don't auto-start and monitor recovery

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            AUTO_APPLY=true
            TARGET_NODE="$2"
            shift 2
            ;;
        --server)
            BACKUP_SERVER="$2"
            shift 2
            ;;
        --restore)
            START_RESTORE=true
            shift
            ;;
        --wal-method)
            WAL_METHOD="$2"
            if [ "$WAL_METHOD" != "barman-wal-restore" ] && [ "$WAL_METHOD" != "barman-get-wal" ]; then
                echo -e "${RED}Invalid --wal-method: $WAL_METHOD${NC}"
                echo -e "${YELLOW}Valid options: barman-wal-restore, barman-get-wal${NC}"
                exit 1
            fi
            shift 2
            ;;
        --auto-start)
            AUTO_START=true
            shift
            ;;
        *)
            if [ -z "$BACKUP_ID" ]; then
                BACKUP_ID="$1"
            elif [ -z "$TARGET_TIME" ]; then
                TARGET_TIME="$1"
            else
                echo -e "${RED}Unknown argument: $1${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Check required arguments
if [ -z "$BACKUP_ID" ] || [ -z "$TARGET_TIME" ]; then
    echo -e "${RED}Usage:${NC} $0 <backup-id> <target-time> [--server <server>] [--target <node>] [--restore] [--wal-method <method>]"
    echo ""
    echo "Examples:"
    echo "  $0 20260104T153446 '2026-01-04 15:45:00'"
    echo "  $0 20260104T153446 '2026-01-04 15:45:00' --server db2"
    echo "  $0 20260104T153446 '2026-01-04 15:45:00' --server db2 --target db1"
    echo "  $0 20260104T153446 latest --server db2 --target db1 --restore"
    echo "  $0 20260104T153446 latest --server db2 --target db1 --restore --wal-method barman-get-wal"
    echo ""
    echo "Options:"
    echo "  --server <server>  Server where the backup exists (db1, db2, db3, db4)"
    echo "                     If not specified, will auto-detect by checking all servers"
    echo "  --target <node>    Automatically apply PITR to specified node (db1, db2, db3, db4)"
    echo "                     This will:"
    echo "                     - Stop Patroni on target node"
    echo "                     - Backup and replace data directory"
    echo "                     - Stop other nodes"
    echo "                     - Configure recovery settings"
    echo "  --restore          Start PostgreSQL recovery automatically (only with --target)"
    echo "                     If not specified, you must start PostgreSQL manually"
    echo "  --auto-start       Automatically start PostgreSQL and monitor recovery progress"
    echo "                     If not specified, recovery monitoring is skipped"
    echo "  --wal-method <method>  Method to fetch WAL files (default: barman-wal-restore)"
    echo "                        Options:"
    echo "                        - barman-wal-restore: Use barman-wal-restore command (recommended)"
    echo "                        - barman-get-wal: Use SSH with barman get-wal command"
    echo ""
    echo "Available backups:"
    for server in db1 db2 db3 db4; do
        BACKUPS=$(docker exec barman barman list-backup "$server" 2>/dev/null | head -10)
        if [ -n "$BACKUPS" ]; then
            echo -e "${CYAN}${server}:${NC}"
            echo "$BACKUPS"
        fi
    done
    exit 1
fi

# Default target node if not specified
if [ -z "$TARGET_NODE" ]; then
    TARGET_NODE="db1"
fi

# Load environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}

# Determine Patroni data directory based on node
case $TARGET_NODE in
    db1) PATRONI_DATA_DIR="/var/lib/postgresql/15/patroni1" ;;
    db2) PATRONI_DATA_DIR="/var/lib/postgresql/15/patroni2" ;;
    db3) PATRONI_DATA_DIR="/var/lib/postgresql/15/patroni3" ;;
    db4) PATRONI_DATA_DIR="/var/lib/postgresql/15/patroni4" ;;
    *) PATRONI_DATA_DIR="/var/lib/postgresql/15/patroni1" ;;
esac

# Helper functions
stop_patroni() {
    local node=$1
    echo -e "${YELLOW}  Stopping Patroni on ${node}...${NC}"
    if docker exec "$node" supervisorctl stop patroni >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Patroni stopped${NC}"
        sleep 2
        return 0
    else
        echo -e "${YELLOW}  ⚠ Patroni may already be stopped${NC}"
        return 0
    fi
}

start_patroni() {
    local node=$1
    echo -e "${YELLOW}  Starting Patroni on ${node}...${NC}"
    if docker exec "$node" supervisorctl start patroni >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Patroni started${NC}"
        sleep 3
        return 0
    else
        echo -e "${RED}  ✗ Failed to start Patroni${NC}"
        return 1
    fi
}

check_patroni_running() {
    local node=$1
    # Check if Patroni process is running via supervisorctl
    if docker exec "$node" supervisorctl status patroni 2>/dev/null | grep -q "RUNNING"; then
        return 0
    fi
    # Also check if patroni process exists
    if docker exec "$node" ps aux | grep -q "[p]atroni.*patroni.yml"; then
        return 0
    fi
    return 1
}

check_node_in_cluster() {
    local node=$1
    # Try to get cluster status from any available node
    local cluster_output=""
    for check_node in db1 db2 db3 db4; do
        if docker exec "$check_node" pg_isready -U postgres -p 5431 -h localhost >/dev/null 2>&1; then
            cluster_output=$(docker exec "$check_node" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
            if [ -n "$cluster_output" ] && echo "$cluster_output" | grep -q "Member"; then
                break
            fi
        fi
    done
    
    # Check if node appears in cluster output
    # The patronictl list output has format: | db1 | db1:5431 | Leader | ...
    # We need to match the node name in the Member column (first data column after |)
    if echo "$cluster_output" | grep -E "^[[:space:]]*\|[[:space:]]+${node}[[:space:]]+\|" >/dev/null 2>&1; then
        return 0  # Node is in cluster
    else
        return 1  # Node is not in cluster
    fi
}

echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  Point-In-Time Recovery (PITR)${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Backup ID:${NC} ${BOLD}${BACKUP_ID}${NC}"
echo -e "${CYAN}Target Time:${NC} ${BOLD}${TARGET_TIME}${NC}"
echo -e "${CYAN}Target Node:${NC} ${BOLD}${TARGET_NODE}${NC}"
if [ "$AUTO_APPLY" = "true" ]; then
    echo -e "${CYAN}Mode:${NC} ${BOLD}${GREEN}Automated (--target)${NC}"
else
    echo -e "${CYAN}Mode:${NC} ${BOLD}${YELLOW}Manual${NC}"
fi
echo ""

# Step 1: Verify backup exists and find which server it belongs to
echo -e "${YELLOW}[1/8] Verifying backup exists...${NC}"

# If --server was provided, use it; otherwise auto-detect
if [ -z "$BACKUP_SERVER" ]; then
    echo -e "${CYAN}Auto-detecting backup server...${NC}"
    for server in db1 db2 db3 db4; do
        if docker exec barman barman show-backup "$server" "$BACKUP_ID" > /dev/null 2>&1; then
            BACKUP_SERVER="$server"
            break
        fi
    done
else
    echo -e "${CYAN}Using specified server: ${BACKUP_SERVER}${NC}"
fi

# Verify the backup exists on the specified/detected server
if [ -z "$BACKUP_SERVER" ] || ! docker exec barman barman show-backup "$BACKUP_SERVER" "$BACKUP_ID" > /dev/null 2>&1; then
    echo -e "${RED}✗ Backup ${BACKUP_ID} not found"
    if [ -n "$BACKUP_SERVER" ]; then
        echo -e "  on server: ${BACKUP_SERVER}${NC}"
    else
        echo -e "  on any server!${NC}"
    fi
    echo "Available backups:"
    for server in db1 db2 db3 db4; do
        BACKUPS=$(docker exec barman barman list-backup "$server" 2>/dev/null | head -5)
        if [ -n "$BACKUPS" ]; then
            echo -e "${CYAN}${server}:${NC}"
            echo "$BACKUPS"
        fi
    done
    exit 1
fi
echo -e "${GREEN}✓ Backup found on server: ${BACKUP_SERVER}${NC}"
echo ""

# Step 2: Show backup details and validate target time
echo -e "${YELLOW}[2/8] Backup details:${NC}"
BACKUP_INFO=$(docker exec barman barman show-backup "$BACKUP_SERVER" "$BACKUP_ID" 2>&1)
echo "$BACKUP_INFO" | grep -E "(Backup|Begin time|End time|Begin WAL|End WAL)" | head -10
echo ""

# Extract backup end time (preserve the space between date and time)
BACKUP_END_TIME=$(echo "$BACKUP_INFO" | grep "End time" | sed 's/.*End time[[:space:]]*:[[:space:]]*\(.*\)/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
BACKUP_BEGIN_TIME=$(echo "$BACKUP_INFO" | grep "Begin time" | sed 's/.*Begin time[[:space:]]*:[[:space:]]*\(.*\)/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -n "$BACKUP_END_TIME" ] && [ "$TARGET_TIME" != "latest" ]; then
    echo -e "${CYAN}Validating target time...${NC}"
    echo -e "Backup begin time: ${BOLD}${BACKUP_BEGIN_TIME}${NC}"
    echo -e "Backup end time:   ${BOLD}${BACKUP_END_TIME}${NC}"
    echo -e "Target time:       ${BOLD}${TARGET_TIME}${NC}"
    echo ""
    
    # Convert times to epoch for comparison (use barman container for date command - works on macOS)
    TARGET_EPOCH=$(docker exec barman date -d "$TARGET_TIME" +%s 2>/dev/null || docker exec barman date -d "$TARGET_TIME UTC" +%s 2>/dev/null || echo "0")
    END_EPOCH=$(docker exec barman date -d "$BACKUP_END_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$TARGET_EPOCH" -lt "$END_EPOCH" ] && [ "$TARGET_EPOCH" -gt 0 ] && [ "$END_EPOCH" -gt 0 ]; then
        echo -e "${RED}✗ ERROR: Target time is before backup end time!${NC}"
        echo -e "${YELLOW}You can only recover to a time AFTER the backup completed.${NC}"
        echo ""
        echo -e "${CYAN}Valid recovery times:${NC}"
        echo -e "  After: ${BOLD}${BACKUP_END_TIME}${NC}"
        echo -e "  Or use: ${BOLD}latest${NC} (to recover to most recent state)"
        echo ""
        echo -e "${YELLOW}To find available recovery points, check WAL files:${NC}"
        echo -e "  docker exec barman barman show-server ${BACKUP_SERVER} | grep last_archived"
        exit 1
    fi
fi
echo ""

# Step 3: Check WAL availability
echo -e "${YELLOW}[3/8] Checking WAL archiving status...${NC}"
WAL_STATUS=$(docker exec barman barman status "$BACKUP_SERVER" 2>&1 | grep -E "(Failures|Last archived)" | head -2)
echo "$WAL_STATUS"
if echo "$WAL_STATUS" | grep -q "Failures.*[1-9]"; then
    echo -e "${YELLOW}⚠ Warning: WAL archiver has failures${NC}"
fi

# Check if WAL files are available for the target time
if [ "$TARGET_TIME" != "latest" ] && [ -n "$BACKUP_END_TIME" ]; then
    echo -e "${CYAN}Checking WAL availability for target time...${NC}"
    
    # Get the last archived WAL info
    LAST_ARCHIVED=$(docker exec barman barman show-server "$BACKUP_SERVER" 2>&1 | grep -i "last_archived_wal" | head -1 || echo "")
    if [ -n "$LAST_ARCHIVED" ]; then
        echo -e "  ${LAST_ARCHIVED}"
    fi
    
    # Check if target time is after backup end time
    # Use barman container for date command (works on macOS where date -d doesn't work)
    TARGET_EPOCH=$(docker exec barman date -d "$TARGET_TIME" +%s 2>/dev/null || docker exec barman date -d "$TARGET_TIME UTC" +%s 2>/dev/null || echo "0")
    END_EPOCH=$(docker exec barman date -d "$BACKUP_END_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$TARGET_EPOCH" -gt "$END_EPOCH" ] && [ "$TARGET_EPOCH" -gt 0 ] && [ "$END_EPOCH" -gt 0 ]; then
        TIME_DIFF=$((TARGET_EPOCH - END_EPOCH))
        echo -e "${CYAN}  Target time is ${TIME_DIFF} seconds after backup end time${NC}"
        
        # Warn if target time is very close to backup end (less than 10 seconds)
        # This often requires WAL files that may be partial or not yet archived
        if [ "$TIME_DIFF" -lt 10 ] && [ "$TIME_DIFF" -gt 0 ]; then
            echo -e "${YELLOW}  ⚠ WARNING: Target time is very close to backup end time (${TIME_DIFF} seconds)${NC}"
            echo -e "${YELLOW}  The required WAL file may be partial or not yet fully archived.${NC}"
            
            # Check if there's a later backup that might be better
            echo -e "${CYAN}  Checking for a later backup that might be better suited...${NC}"
            LATER_BACKUPS=$(docker exec barman barman list-backup "$BACKUP_SERVER" 2>/dev/null | grep -A 1 "$BACKUP_ID" | tail -1 || echo "")
            if [ -n "$LATER_BACKUPS" ] && echo "$LATER_BACKUPS" | grep -q "$BACKUP_SERVER"; then
                LATER_BACKUP_ID=$(echo "$LATER_BACKUPS" | awk '{print $2}')
                LATER_BACKUP_TIME=$(echo "$LATER_BACKUPS" | awk '{print $6, $7, $8}')
                echo -e "${CYAN}  Found later backup: ${LATER_BACKUP_ID} (${LATER_BACKUP_TIME})${NC}"
                LATER_BACKUP_INFO=$(docker exec barman barman show-backup "$BACKUP_SERVER" "$LATER_BACKUP_ID" 2>/dev/null | grep "End time" | sed 's/.*End time[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ' || echo "")
                if [ -n "$LATER_BACKUP_INFO" ]; then
                    LATER_END_EPOCH=$(docker exec barman date -d "$LATER_BACKUP_INFO" +%s 2>/dev/null || docker exec barman date -d "$LATER_BACKUP_INFO UTC" +%s 2>/dev/null || echo "0")
                    if [ "$TARGET_EPOCH" -le "$LATER_END_EPOCH" ] && [ "$LATER_END_EPOCH" -gt 0 ]; then
                        echo -e "${GREEN}  ✓ This later backup (${LATER_BACKUP_ID}) ends at ${LATER_BACKUP_INFO} and covers your target time!${NC}"
                        echo -e "${CYAN}  Consider using: ${BOLD}${LATER_BACKUP_ID}${NC} instead of ${BACKUP_ID}"
                    fi
                fi
            fi
            
            echo -e "${CYAN}  Recommendations:${NC}"
            echo -e "    1. Use 'latest' to recover to the most recent complete WAL file (RECOMMENDED)"
            echo -e "    2. Use the exact backup end time: ${BACKUP_END_TIME}"
            echo -e "    3. Wait a few seconds and ensure WAL archiving completes"
            if [ -n "$LATER_BACKUP_ID" ] && [ "$TARGET_EPOCH" -le "$LATER_END_EPOCH" ] && [ "$LATER_END_EPOCH" -gt 0 ]; then
                echo -e "    4. Use the later backup: ${LATER_BACKUP_ID}"
            fi
            echo ""
            echo -e "${YELLOW}  Note: If you use the backup end time, make sure to include microseconds: ${BACKUP_END_TIME}${NC}"
            echo ""
            # Use explicit file descriptor to ensure read works even if stdin is redirected
            if [ -t 0 ]; then
                read -p "  Continue anyway? (y/N): " -n 1 -r < /dev/tty || true
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}  Aborted.${NC}"
                    exit 1
                fi
            else
                echo -e "${YELLOW}  ⚠ Cannot prompt for confirmation (stdin not available). Continuing anyway...${NC}"
                echo -e "${YELLOW}  ⚠ If you want to abort, press Ctrl+C now.${NC}"
                sleep 2
            fi
        else
            echo -e "${YELLOW}  ⚠ Ensure WAL files are archived for this time period${NC}"
        fi
        
        # Check for WAL gaps by verifying WAL sequence from backup end to target time
        echo -e "${CYAN}  Verifying WAL sequence availability...${NC}"
        BACKUP_END_WAL=$(echo "$BACKUP_INFO" | grep "End WAL" | sed 's/.*End WAL[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ')
        BACKUP_TIMELINE=$(echo "$BACKUP_INFO" | grep "Timeline" | sed 's/.*Timeline[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ' || echo "")
        if [ -z "$BACKUP_TIMELINE" ] && [ -n "$BACKUP_END_WAL" ]; then
            BACKUP_TIMELINE_HEX=$(echo "$BACKUP_END_WAL" | cut -c1-8)
            BACKUP_TIMELINE=$((0x$BACKUP_TIMELINE_HEX))
        fi
        
        if [ -n "$BACKUP_END_WAL" ] && [ -n "$BACKUP_TIMELINE" ]; then
            # Estimate how many WAL segments are needed (each WAL is ~16MB, ~16 seconds)
            WAL_SEGMENTS_NEEDED=$((TIME_DIFF / 16 + 1))
            if [ "$WAL_SEGMENTS_NEEDED" -gt 20 ]; then
                WAL_SEGMENTS_NEEDED=20  # Limit check to first 20 segments to avoid too many checks
            fi
            
            # Extract segment number from backup end WAL
            END_SEGMENT=$(echo "$BACKUP_END_WAL" | sed 's/.*\([0-9A-F]\{8\}\)$/\1/')
            END_SEGMENT_DEC=$((0x$END_SEGMENT))
            
            GAPS_FOUND=0
            MISSING_WALS=""
            
            # Check WAL sequence, including across timeline switches
            for i in $(seq 1 $WAL_SEGMENTS_NEEDED); do
                NEXT_SEGMENT_DEC=$((END_SEGMENT_DEC + i))
                NEXT_SEGMENT_HEX=$(printf "%08X" $NEXT_SEGMENT_DEC 2>/dev/null || echo "")
                
                if [ -z "$NEXT_SEGMENT_HEX" ]; then
                    break
                fi
                
                # Check across all timelines (backup timeline and later ones)
                WAL_FOUND=false
                TIMELINE_TO_CHECK=$BACKUP_TIMELINE
                
                # Check up to 5 timelines ahead (in case of rapid timeline switches)
                for timeline_offset in $(seq 0 5); do
                    CHECK_TIMELINE=$((BACKUP_TIMELINE + timeline_offset))
                    TIMELINE_HEX=$(printf "%08X" $CHECK_TIMELINE 2>/dev/null || echo "")
                    if [ -z "$TIMELINE_HEX" ]; then
                        break
                    fi
                    
                    # Construct WAL filename: timeline (8 hex) + zeros (8 hex) + segment (8 hex) = 24 hex digits total
                    EXPECTED_WAL="${TIMELINE_HEX}00000000${NEXT_SEGMENT_HEX}"
                    WAL_DIR="${TIMELINE_HEX}00000000"
                    
                    # Check if WAL exists (complete or partial) in both wals directory and incoming directory
                    # WALs might be in incoming directory waiting for barman cron to process them
                    WAL_EXISTS=$(docker exec barman find /data/pg-backup/${BACKUP_SERVER}/wals/${WAL_DIR} -name "${EXPECTED_WAL}" ! -name "*.backup" 2>/dev/null | head -1 || echo "")
                    if [ -z "$WAL_EXISTS" ]; then
                        # Also check incoming directory (WALs waiting to be processed by barman cron)
                        WAL_EXISTS=$(docker exec barman find /data/pg-backup/${BACKUP_SERVER}/incoming -name "${EXPECTED_WAL}" ! -name "*.backup" 2>/dev/null | head -1 || echo "")
                    fi
                    if [ -n "$WAL_EXISTS" ]; then
                        WAL_FOUND=true
                        break
                    fi
                done
                
                if [ "$WAL_FOUND" = false ]; then
                    GAPS_FOUND=$((GAPS_FOUND + 1))
                    if [ -z "$MISSING_WALS" ]; then
                        MISSING_WALS="${EXPECTED_WAL}"
                    else
                        MISSING_WALS="${MISSING_WALS}, ${EXPECTED_WAL}"
                    fi
                    
                    # Stop checking after finding 3 consecutive gaps (likely a large gap)
                    if [ "$GAPS_FOUND" -ge 3 ]; then
                        break
                    fi
                fi
            done
            
            if [ "$GAPS_FOUND" -gt 0 ]; then
                echo ""
                echo -e "${RED}  ✗ WARNING: WAL gaps detected!${NC}"
                echo -e "${YELLOW}  Missing WAL files: ${MISSING_WALS}${NC}"
                echo -e "${YELLOW}  Recovery to ${TARGET_TIME} will likely FAIL due to missing WAL files.${NC}"
                echo ""
                
                # Check if WAL archiving appears to have stopped or is behind
                LAST_ARCHIVED_TIME_EPOCH=$(docker exec barman barman show-server "$BACKUP_SERVER" 2>&1 | grep -i "last_archived_time" | sed 's/.*last_archived_time[[:space:]]*:[[:space:]]*\(.*\)/\1/' | xargs -I {} docker exec barman date -d "{}" +%s 2>/dev/null || echo "0")
                LAST_ARCHIVED_WAL=$(docker exec barman barman show-server "$BACKUP_SERVER" 2>&1 | grep -i "last_archived_wal" | sed 's/.*last_archived_wal[[:space:]]*:[[:space:]]*\(.*\)/\1/' | sed 's/\..*$//' | tr -d ' ' || echo "")
                
                if [ "$LAST_ARCHIVED_TIME_EPOCH" -gt 0 ] && [ "$TARGET_EPOCH" -gt "$LAST_ARCHIVED_TIME_EPOCH" ]; then
                    ARCHIVE_GAP=$((TARGET_EPOCH - LAST_ARCHIVED_TIME_EPOCH))
                    echo -e "${RED}  ⚠ CRITICAL: WAL archiving appears to have STOPPED or is BEHIND!${NC}"
                    echo -e "${YELLOW}  Last archived WAL: ${LAST_ARCHIVED_WAL}${NC}"
                    echo -e "${YELLOW}  Last archived time: $(docker exec barman barman show-server "$BACKUP_SERVER" 2>&1 | grep -i "last_archived_time" | sed 's/.*last_archived_time[[:space:]]*:[[:space:]]*\(.*\)/\1/')${NC}"
                    echo -e "${YELLOW}  Target time: ${TARGET_TIME}${NC}"
                    echo -e "${YELLOW}  Gap: ${ARCHIVE_GAP} seconds (${ARCHIVE_GAP} seconds of WALs missing)${NC}"
                    
                    # Calculate how many WAL segments are missing
                    if [ -n "$LAST_ARCHIVED_WAL" ]; then
                        LAST_SEGMENT=$(echo "$LAST_ARCHIVED_WAL" | sed 's/.*\([0-9A-F]\{8\}\)$/\1/')
                        LAST_SEGMENT_DEC=$((0x$LAST_SEGMENT))
                        TARGET_SEGMENT_DEC=$((END_SEGMENT_DEC + WAL_SEGMENTS_NEEDED))
                        SEGMENTS_MISSING=$((TARGET_SEGMENT_DEC - LAST_SEGMENT_DEC))
                        if [ "$SEGMENTS_MISSING" -gt 0 ]; then
                            echo -e "${YELLOW}  Missing WAL segments: ${SEGMENTS_MISSING} (from segment $(printf "%08X" $((LAST_SEGMENT_DEC + 1))) to $(printf "%08X" $TARGET_SEGMENT_DEC))${NC}"
                        fi
                    fi
                    echo ""
                    echo -e "${CYAN}  Possible causes:${NC}"
                    echo -e "    1. Database stopped or crashed after backup"
                    echo -e "    2. WAL archiving was disabled or failed"
                    echo -e "    3. Database is in recovery mode and not archiving new WALs"
                    echo -e "    4. Network issues preventing WAL archiving to barman"
                    echo -e "    5. WALs are being archived but barman cron hasn't processed them yet (check incoming directory)"
                    echo ""
                else
                    echo -e "${CYAN}  Possible causes:${NC}"
                    echo -e "    1. Rapid timeline switches caused intermediate WALs to be lost"
                    echo -e "    2. WAL archiving was not active during this time period"
                    echo -e "    3. WAL files were deleted or not archived"
                    echo ""
                fi
                echo -e "${CYAN}  Recommendations:${NC}"
                echo -e "    1. ${BOLD}Use 'latest' to recover to the most recent available state (RECOMMENDED)${NC}"
                echo -e "       Command: bash scripts/perform_pitr.sh ${BACKUP_ID} latest --server ${BACKUP_SERVER} --target ${TARGET_NODE} --restore"
                echo -e "    2. Use the backup end time: ${BACKUP_END_TIME}"
                echo -e "    3. Check if a later backup has the required WALs"
                echo ""
                
                # Use explicit file descriptor to ensure read works even if stdin is redirected
                if [ -t 0 ]; then
                    read -p "  Continue anyway? (y/N): " -n 1 -r < /dev/tty || true
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}  Aborted.${NC}"
                        exit 1
                    fi
                else
                    echo -e "${YELLOW}  ⚠ Cannot prompt for confirmation (stdin not available). Continuing anyway...${NC}"
                    echo -e "${YELLOW}  ⚠ Recovery will likely fail due to missing WAL files.${NC}"
                    sleep 3
                fi
            else
                echo -e "${GREEN}  ✓ WAL sequence appears complete for target time${NC}"
            fi
        fi
        
        echo -e "${CYAN}  If recovery fails, check WAL availability:${NC}"
        echo -e "    docker exec barman ls -lh /data/pg-backup/${BACKUP_SERVER}/wals/*/"
    fi
fi
echo ""

# Step 4: Create recovery directory
RECOVERY_DIR="/tmp/pitr_recovery_$(date +%Y%m%d_%H%M%S)"
echo -e "${YELLOW}[4/8] Creating recovery directory: ${RECOVERY_DIR}${NC}"
mkdir -p "$RECOVERY_DIR"
chmod 700 "$RECOVERY_DIR"
echo -e "${GREEN}✓ Recovery directory created${NC}"
echo ""

# Step 5: Perform recovery
echo -e "${YELLOW}[5/8] Performing PITR recovery...${NC}"
echo -e "${CYAN}This may take several minutes depending on database size...${NC}"
echo ""

if [ "$TARGET_TIME" = "latest" ]; then
    # For 'latest', don't specify --target-time - barman will recover to end of available WAL
    RECOVERY_CMD="docker exec barman barman recover $BACKUP_SERVER $BACKUP_ID $RECOVERY_DIR"
    echo -e "${CYAN}Recovering to latest available state (end of WAL)...${NC}"
else
    RECOVERY_CMD="docker exec barman barman recover --target-time \"$TARGET_TIME\" $BACKUP_SERVER $BACKUP_ID $RECOVERY_DIR"
fi

echo "Command: $RECOVERY_CMD"
echo ""

if eval "$RECOVERY_CMD" 2>&1; then
    echo -e "${GREEN}✓ Recovery completed successfully${NC}"
else
    echo -e "${RED}✗ Recovery failed!${NC}"
    echo "Check Barman logs: docker exec barman tail -f /var/log/barman/barman.log"
    exit 1
fi
echo ""

# Step 6: Verify recovery files and copy from container to host
echo -e "${YELLOW}[6/8] Verifying recovery files...${NC}"

# Store original container path
CONTAINER_RECOVERY_DIR="$RECOVERY_DIR"
HOST_RECOVERY_DIR=""

# Check if files exist inside the container
if docker exec barman test -d "$CONTAINER_RECOVERY_DIR" 2>/dev/null && [ "$(docker exec barman ls -A $CONTAINER_RECOVERY_DIR 2>/dev/null | wc -l)" -gt 0 ]; then
    echo -e "${GREEN}✓ Recovery files created in container${NC}"
    
    # Get recovery directory size from container
    CONTAINER_SIZE=$(docker exec barman du -sh "$CONTAINER_RECOVERY_DIR" 2>/dev/null | cut -f1)
    echo "Recovery directory size: ${CONTAINER_SIZE}"
    echo ""
    
    # Show key files
    echo "Key files in container:"
    docker exec barman ls -lh "$CONTAINER_RECOVERY_DIR" 2>/dev/null | head -10
    echo ""
    
    # Copy files from container to host
    HOST_RECOVERY_DIR="/tmp/pitr_recovery_host_$(date +%Y%m%d_%H%M%S)"
    echo -e "${CYAN}Copying recovery files from container to host...${NC}"
    echo "Container path: ${CONTAINER_RECOVERY_DIR}"
    echo "Host path: ${HOST_RECOVERY_DIR}"
    
    # Create host directory
    mkdir -p "$HOST_RECOVERY_DIR"
    
    # Copy files from container
    if docker cp "barman:${CONTAINER_RECOVERY_DIR}/." "$HOST_RECOVERY_DIR/" 2>/dev/null; then
        echo -e "${GREEN}✓ Files copied to host${NC}"
        echo ""
        echo "Host recovery directory:"
        ls -lh "$HOST_RECOVERY_DIR" | head -10
        echo ""
    else
        echo -e "${YELLOW}⚠ Warning: Could not copy files to host, but files exist in container${NC}"
        echo -e "${CYAN}You can copy them manually:${NC}"
        echo "  docker cp barman:${CONTAINER_RECOVERY_DIR}/. ${HOST_RECOVERY_DIR}/"
        echo ""
    fi
else
    echo -e "${RED}✗ Recovery directory is empty or not found!${NC}"
    echo "Checking container for recovery directories:"
    docker exec barman find /tmp -name "pitr_recovery_*" -type d 2>/dev/null | head -5
    exit 1
fi
echo ""

# Step 7: Automated application (if --target specified)
if [ "$AUTO_APPLY" = "true" ]; then
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  Automated PITR Application${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""
    
    # Step 7.1: Stop Patroni on target node
    echo -e "${YELLOW}[7.1/10] Stopping Patroni on ${TARGET_NODE}...${NC}"
    stop_patroni "$TARGET_NODE"
    echo ""
    
    # Step 7.2: Verify node is not in cluster
    echo -e "${YELLOW}[7.2/10] Verifying ${TARGET_NODE} is not in cluster...${NC}"
    
    # Wait a bit for cluster to update after stopping Patroni
    sleep 3
    
    # Check multiple times with increasing wait
    MAX_CHECKS=5
    CHECK_COUNT=0
    IN_CLUSTER=true
    
    while [ $CHECK_COUNT -lt $MAX_CHECKS ]; do
        if check_node_in_cluster "$TARGET_NODE"; then
            CHECK_COUNT=$((CHECK_COUNT + 1))
            if [ $CHECK_COUNT -lt $MAX_CHECKS ]; then
                echo -e "${CYAN}  ${TARGET_NODE} still in cluster, waiting... (${CHECK_COUNT}/${MAX_CHECKS})${NC}"
                sleep 3
            else
                IN_CLUSTER=true
                break
            fi
        else
            IN_CLUSTER=false
            break
        fi
    done
    
    if [ "$IN_CLUSTER" = "true" ]; then
        echo -e "${YELLOW}  ⚠ Warning: ${TARGET_NODE} still appears in cluster after ${MAX_CHECKS} checks${NC}"
        echo -e "${CYAN}  Current cluster status:${NC}"
        for check_node in db1 db2 db3 db4; do
            if docker exec "$check_node" pg_isready -U postgres -p 5431 -h localhost >/dev/null 2>&1; then
                docker exec "$check_node" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | head -10
                break
            fi
        done
        echo ""
        echo -e "${YELLOW}  You may need to remove it manually:${NC}"
        echo -e "    docker exec db1 patronictl -c /etc/patroni/patroni.yml remove ${TARGET_NODE}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}  ✓ ${TARGET_NODE} is not in cluster${NC}"
    fi
    echo ""
    
    # Step 7.3: Backup current data directory
    echo -e "${YELLOW}[7.3/10] Backing up current data directory...${NC}"
    
    # Use timestamped backup directory to avoid conflicts
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DATA_DIR="${PATRONI_DATA_DIR}.backup_${BACKUP_TIMESTAMP}"
    
    if docker exec "$TARGET_NODE" test -d "$PATRONI_DATA_DIR" 2>/dev/null; then
        # Ensure PostgreSQL is fully stopped before moving
        echo -e "${CYAN}  Ensuring PostgreSQL is stopped...${NC}"
        sleep 2
        
        # Check if PostgreSQL process is still running
        if docker exec "$TARGET_NODE" ps aux | grep -q "[p]ostgres.*patroni1"; then
            echo -e "${YELLOW}  ⚠ PostgreSQL process still running, waiting...${NC}"
            sleep 5
            # Force kill if still running
            docker exec "$TARGET_NODE" pkill -9 -f "postgres.*patroni1" 2>/dev/null || true
            sleep 2
        fi
        
        # Check if backup directory already exists
        if docker exec "$TARGET_NODE" test -d "$BACKUP_DATA_DIR" 2>/dev/null; then
            echo -e "${YELLOW}  ⚠ Backup directory ${BACKUP_DATA_DIR} already exists${NC}"
            # Try with a different timestamp
            BACKUP_DATA_DIR="${PATRONI_DATA_DIR}.backup_${BACKUP_TIMESTAMP}_$$"
        fi
        
        # Try to move the directory
        if docker exec "$TARGET_NODE" mv "$PATRONI_DATA_DIR" "$BACKUP_DATA_DIR" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Data backed up to ${BACKUP_DATA_DIR}${NC}"
        else
            # If move fails, try copying instead (slower but more reliable)
            echo -e "${YELLOW}  ⚠ Move failed, trying copy instead...${NC}"
            if docker exec "$TARGET_NODE" cp -r "$PATRONI_DATA_DIR" "$BACKUP_DATA_DIR" 2>/dev/null; then
                echo -e "${GREEN}  ✓ Data backed up to ${BACKUP_DATA_DIR} (copied)${NC}"
                # Remove original after successful copy
                docker exec "$TARGET_NODE" rm -rf "$PATRONI_DATA_DIR" 2>/dev/null || true
            else
                echo -e "${RED}  ✗ Failed to backup data directory${NC}"
                echo -e "${CYAN}  Debug: Checking directory state...${NC}"
                docker exec "$TARGET_NODE" ls -ld "$PATRONI_DATA_DIR" 2>&1
                docker exec "$TARGET_NODE" fuser "$PATRONI_DATA_DIR" 2>&1 || echo "No processes using directory"
                exit 1
            fi
        fi
    else
        echo -e "${YELLOW}  ⚠ Data directory does not exist, skipping backup${NC}"
    fi
    echo ""
    
    # Step 7.4: Copy PITR data from barman to target node using rsync
    echo -e "${YELLOW}[7.4/10] Copying PITR data to ${TARGET_NODE} using rsync...${NC}"
    echo -e "${CYAN}  This may take several minutes...${NC}"
    
    # First, ensure target directory exists and is empty (or create it)
    echo -e "${CYAN}  Preparing target directory...${NC}"
    if docker exec "$TARGET_NODE" test -d "$PATRONI_DATA_DIR" 2>/dev/null; then
        # Directory exists, ensure it's empty or remove contents
        echo -e "${CYAN}  Clearing existing directory contents...${NC}"
        docker exec "$TARGET_NODE" rm -rf "${PATRONI_DATA_DIR:?}"/* "${PATRONI_DATA_DIR:?}"/.* 2>/dev/null || true
    else
        # Create directory
        if ! docker exec "$TARGET_NODE" mkdir -p "$PATRONI_DATA_DIR" 2>/dev/null; then
            echo -e "${RED}  ✗ Failed to create target directory${NC}"
            exit 1
        fi
    fi
    
    # Set ownership to postgres user
    docker exec "$TARGET_NODE" chown -R postgres:postgres "$PATRONI_DATA_DIR" 2>/dev/null || true
    
    # Verify source directory exists in barman container
    if ! docker exec barman test -d "$CONTAINER_RECOVERY_DIR" 2>/dev/null; then
        echo -e "${RED}  ✗ Recovery directory not found in barman container: ${CONTAINER_RECOVERY_DIR}${NC}"
        echo -e "${CYAN}  Available recovery directories:${NC}"
        docker exec barman find /tmp -name "pitr_recovery_*" -type d 2>/dev/null | head -5
        exit 1
    fi
    
    # Determine barman's SSH key location
    BARMAN_SSH_KEY="/var/lib/barman/.ssh/id_rsa"
    if ! docker exec barman test -f "$BARMAN_SSH_KEY" 2>/dev/null; then
        BARMAN_SSH_KEY="/home/barman/.ssh/id_rsa"
        if ! docker exec barman test -f "$BARMAN_SSH_KEY" 2>/dev/null; then
            echo -e "${YELLOW}  ⚠ SSH key not found, trying without explicit key path${NC}"
            BARMAN_SSH_KEY=""
        fi
    fi
    
    # Build rsync command with proper escaping and options
    # Use --delete to ensure clean copy, --exclude for problematic directories if needed
    if [ -n "$BARMAN_SSH_KEY" ]; then
        RSYNC_CMD="rsync -e 'ssh -i ${BARMAN_SSH_KEY} -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' -av --progress --delete ${CONTAINER_RECOVERY_DIR}/ postgres@${TARGET_NODE}:${PATRONI_DATA_DIR}/"
    else
        RSYNC_CMD="rsync -e 'ssh -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' -av --progress --delete ${CONTAINER_RECOVERY_DIR}/ postgres@${TARGET_NODE}:${PATRONI_DATA_DIR}/"
    fi
    
    echo -e "${CYAN}  Copying from barman:${CONTAINER_RECOVERY_DIR}${NC}"
    echo -e "${CYAN}  Copying to postgres@${TARGET_NODE}:${PATRONI_DATA_DIR}${NC}"
    echo -e "${CYAN}  Using rsync via SSH...${NC}"
    
    # Execute rsync from barman container
    # Capture both stdout and stderr
    RSYNC_OUTPUT=$(docker exec barman bash -c "$RSYNC_CMD" 2>&1)
    RSYNC_EXIT_CODE=$?
    
    # Show rsync output
    echo "$RSYNC_OUTPUT"
    
    # Check if rsync succeeded (exit code 0) or had minor issues (code 23 = partial transfer)
    if [ $RSYNC_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}  ✓ PITR data copied via rsync${NC}"
    elif [ $RSYNC_EXIT_CODE -eq 23 ]; then
        # Code 23 = partial transfer - check if critical files were copied
        echo -e "${YELLOW}  ⚠ rsync completed with warnings (some files may not have transferred)${NC}"
        echo -e "${CYAN}  Verifying critical files...${NC}"
        
        # Check for critical PostgreSQL files
        CRITICAL_FILES=("PG_VERSION" "backup_label" "postgresql.conf" "postgresql.auto.conf")
        MISSING_FILES=0
        for file in "${CRITICAL_FILES[@]}"; do
            if ! docker exec "$TARGET_NODE" test -f "${PATRONI_DATA_DIR}/${file}" 2>/dev/null; then
                echo -e "${YELLOW}    ⚠ Missing: ${file}${NC}"
                MISSING_FILES=$((MISSING_FILES + 1))
            fi
        done
        
        if [ $MISSING_FILES -eq 0 ]; then
            echo -e "${GREEN}  ✓ Critical files present, continuing...${NC}"
        else
            echo -e "${RED}  ✗ Critical files missing!${NC}"
            exit 1
        fi
    else
        echo -e "${RED}  ✗ Failed to copy PITR data via rsync (exit code: ${RSYNC_EXIT_CODE})${NC}"
        echo -e "${CYAN}  Debug info:${NC}"
        echo -e "    Source: barman:${CONTAINER_RECOVERY_DIR}"
        echo -e "    Target: postgres@${TARGET_NODE}:${PATRONI_DATA_DIR}"
        echo -e "    SSH Key: ${BARMAN_SSH_KEY:-default}"
        exit 1
    fi
    
    # Verify files were copied
    FILE_COUNT=$(docker exec "$TARGET_NODE" find "$PATRONI_DATA_DIR" -type f 2>/dev/null | wc -l)
    if [ "$FILE_COUNT" -gt 0 ]; then
        echo -e "${GREEN}  ✓ Verified: ${FILE_COUNT} files copied${NC}"
    else
        echo -e "${YELLOW}  ⚠ Warning: No files found in target directory${NC}"
    fi
    echo ""
    
    # Step 7.5: Set correct permissions
    echo -e "${YELLOW}[7.5/10] Setting correct permissions...${NC}"
    if docker exec "$TARGET_NODE" chown -R postgres:postgres "$PATRONI_DATA_DIR" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Permissions set${NC}"
    else
        echo -e "${RED}  ✗ Failed to set permissions${NC}"
        exit 1
    fi
    echo ""
    
    # Step 7.4a: Ensure SSH key is in default location for barman-wal-restore
    echo -e "${YELLOW}[7.4a/10] Setting up SSH key for barman-wal-restore...${NC}"
    # barman-wal-restore uses SSH and expects the key at ~/.ssh/id_rsa (default location)
    # Copy the key from /var/lib/postgresql/.ssh/barman_rsa to ~/.ssh/id_rsa if it doesn't exist
    docker exec "$TARGET_NODE" su - postgres -c "
        if [ -f /var/lib/postgresql/.ssh/barman_rsa ] && [ ! -f ~/.ssh/id_rsa ]; then
            cp /var/lib/postgresql/.ssh/barman_rsa ~/.ssh/id_rsa
            chmod 600 ~/.ssh/id_rsa
            echo 'SSH key copied to default location'
        elif [ -f ~/.ssh/id_rsa ]; then
            echo 'SSH key already in default location'
        else
            echo 'WARNING: SSH key not found at /var/lib/postgresql/.ssh/barman_rsa'
        fi
    " 2>&1
    echo -e "${GREEN}  ✓ SSH key configured${NC}"
    echo ""
    
    # Step 7.4b: Establish initial SSH connection to Barman to accept host key
    echo -e "${YELLOW}[7.4b/10] Establishing SSH connection to Barman...${NC}"
    echo -e "${CYAN}  This will accept the Barman host key to avoid connection errors during recovery${NC}"
    
    # Ensure .ssh directory exists and has correct permissions
    docker exec "$TARGET_NODE" su - postgres -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
    
    # Determine which SSH key to use
    SSH_KEY_PATH=""
    if docker exec "$TARGET_NODE" test -f /var/lib/postgresql/.ssh/id_rsa 2>/dev/null; then
        SSH_KEY_PATH="/var/lib/postgresql/.ssh/id_rsa"
    elif docker exec "$TARGET_NODE" test -f /var/lib/postgresql/.ssh/barman_rsa 2>/dev/null; then
        SSH_KEY_PATH="/var/lib/postgresql/.ssh/barman_rsa"
    fi
    
    # Perform initial SSH connection to accept host key
    # Use StrictHostKeyChecking=accept-new (SSH 7.6+) or yes (older versions)
    SSH_CMD=""
    if [ -n "$SSH_KEY_PATH" ]; then
        SSH_CMD="ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 barman@barman 'echo SSH connection successful'"
    else
        SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 barman@barman 'echo SSH connection successful'"
    fi
    
    if docker exec "$TARGET_NODE" su - postgres -c "$SSH_CMD" 2>&1 | grep -q "SSH connection successful"; then
        echo -e "${GREEN}  ✓ SSH connection to Barman established${NC}"
        echo -e "${CYAN}  Barman host key has been added to known_hosts${NC}"
    else
        # Fallback: try with StrictHostKeyChecking=yes (for older SSH versions)
        if [ -n "$SSH_KEY_PATH" ]; then
            SSH_CMD_FALLBACK="ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=yes -o ConnectTimeout=10 barman@barman 'echo SSH connection successful'"
        else
            SSH_CMD_FALLBACK="ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=10 barman@barman 'echo SSH connection successful'"
        fi
        
        if docker exec "$TARGET_NODE" su - postgres -c "$SSH_CMD_FALLBACK" 2>&1 | grep -q "SSH connection successful"; then
            echo -e "${GREEN}  ✓ SSH connection to Barman established${NC}"
            echo -e "${CYAN}  Barman host key has been added to known_hosts${NC}"
        else
            echo -e "${YELLOW}  ⚠ Warning: Could not establish SSH connection${NC}"
            echo -e "${CYAN}  Attempting to add Barman host key manually...${NC}"
            # Try to get Barman's host key and add it manually
            BARMAN_HOST_KEY=$(docker exec barman ssh-keyscan -t rsa barman 2>/dev/null | head -1 || echo "")
            if [ -n "$BARMAN_HOST_KEY" ]; then
                docker exec "$TARGET_NODE" su - postgres -c "echo '$BARMAN_HOST_KEY' >> ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts" 2>/dev/null
                echo -e "${GREEN}  ✓ Barman host key added to known_hosts${NC}"
            else
                echo -e "${YELLOW}  ⚠ Could not add host key automatically, but continuing anyway${NC}"
                echo -e "${CYAN}  The connection will be established during recovery when needed${NC}"
            fi
        fi
    fi
    echo ""
    
    # Step 7.5a: Fix postgresql.auto.conf with proper restore_command
    echo -e "${YELLOW}[7.5a/10] Fixing recovery configuration...${NC}"
    
    # First, check if postgresql.auto.conf exists in recovery directory (from barman)
    if docker exec barman test -f "$CONTAINER_RECOVERY_DIR/postgresql.auto.conf" 2>/dev/null; then
        # Copy the original from barman and modify restore_command
        docker exec barman cat "$CONTAINER_RECOVERY_DIR/postgresql.auto.conf" > /tmp/postgresql.auto.conf.orig
        docker cp /tmp/postgresql.auto.conf.orig "$TARGET_NODE:$PATRONI_DATA_DIR/postgresql.auto.conf"
        
        # Get recovery target time (preserve spaces in the timestamp)
        # If TARGET_TIME is 'latest', don't set recovery_target_time (recover to end of WAL)
        if [ "$TARGET_TIME" = "latest" ]; then
            RECOVERY_TARGET_TIME=""
        else
            RECOVERY_TARGET_TIME=$(grep "recovery_target_time" /tmp/postgresql.auto.conf.orig | sed "s/recovery_target_time = '\(.*\)'/\1/" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "$TARGET_TIME")
        fi
        
        # Build restore_command based on selected method
        if [ "$WAL_METHOD" = "barman-wal-restore" ]; then
            # restore_command using barman-wal-restore
            RESTORE_CMD="barman-wal-restore -U barman barman ${BACKUP_SERVER} %f %p"
            RESTORE_CMD_ESCAPED="barman-wal-restore -U barman barman ${BACKUP_SERVER} %f %p"
            echo -e "${CYAN}  Updating restore_command to use barman-wal-restore...${NC}"
        else
            # restore_command using SSH with barman get-wal (atomic-safe version)
            RESTORE_CMD="test -f %p || (umask 077; tmp=\"%p.tmp.\$\$\"; ssh -o BatchMode=yes barman@barman \"barman get-wal ${BACKUP_SERVER} %f\" > \"\$tmp\" && mv \"\$tmp\" %p)"
            RESTORE_CMD_ESCAPED="test -f %p || (umask 077; tmp=\\\"%p.tmp.\\\$\\\$\\\"; ssh -o BatchMode=yes barman@barman \\\"barman get-wal ${BACKUP_SERVER} %f\\\" > \\\"\\\$tmp\\\" && mv \\\"\\\$tmp\\\" %p)"
            echo -e "${CYAN}  Updating restore_command to use barman get-wal via SSH...${NC}"
        fi
        # Write the file using a temp file approach to handle special characters in restore_command
        # First write the header
        docker exec "$TARGET_NODE" bash -c "
            printf '# Do not edit this file manually!\n' > $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# It will be overwritten by the ALTER SYSTEM command.\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Restore command options:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman-wal-restore: barman-wal-restore -U barman barman %s %%f %%p\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman get-wal: test -f %%p || (umask 077; tmp=\\\"%%p.tmp.$$\"; ssh -o BatchMode=yes barman@barman \"barman get-wal %s %%f\" > \"\\\$tmp\" && mv \"\\\$tmp\" %%p)\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            if [ "$WAL_METHOD" = "barman-wal-restore" ]; then
                printf '# Using: barman-wal-restore method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            else
                printf '# Using: barman get-wal method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            fi
        " 2>&1
        # Get the restore command content for comments (before escaping)
        RESTORE_CMD_FOR_COMMENT=$(echo "$RESTORE_CMD" | tr -d '\n')
        
        # Add comments showing all recovery settings first
        docker exec "$TARGET_NODE" bash -c "
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Recovery settings (for reference):\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# restore_command = '\''%s'\''\n' '$RESTORE_CMD_FOR_COMMENT' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        
        # Only set recovery_target_time if not 'latest' (when 'latest', recover to end of WAL)
        if [ -n "$RECOVERY_TARGET_TIME" ]; then
            docker exec "$TARGET_NODE" bash -c "
                printf '# recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            " 2>&1
        fi
        
        docker exec "$TARGET_NODE" bash -c "
            printf '# recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        
        # Now write the actual settings
        # Write restore_command to temp file, then append it properly quoted as a single line
        echo "$RESTORE_CMD" | docker exec -i "$TARGET_NODE" bash -c "
            cat > /tmp/restore_cmd_content.txt
            # Remove any newlines and ensure it's a single line, escape single quotes for PostgreSQL ('' = escaped quote)
            RESTORE_CMD_CONTENT=\$(cat /tmp/restore_cmd_content.txt | tr -d '\n' | sed \"s/'/''/g\")
            printf \"restore_command = '%s'\n\" \"\$RESTORE_CMD_CONTENT\" >> $PATRONI_DATA_DIR/postgresql.auto.conf
            rm -f /tmp/restore_cmd_content.txt
        " 2>&1
        
        # Set recovery_target_timeline to 'latest' to allow following timeline switches
        # This is needed when there are timeline switches (e.g., from timeline 10 to 13)
        docker exec "$TARGET_NODE" bash -c "
            printf 'recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        
        if [ -n "$RECOVERY_TARGET_TIME" ]; then
            docker exec "$TARGET_NODE" bash -c "
                printf 'recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            " 2>&1
        fi
        
        docker exec "$TARGET_NODE" bash -c "
            printf 'recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# To start PostgreSQL manually for recovery, run:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# su - postgres -c \"/usr/lib/postgresql/15/bin/postgres -D %s -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info\"\n' '$PATRONI_DATA_DIR' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
    else
        # Create new postgresql.auto.conf if it doesn't exist
        # Build restore_command based on selected method
        if [ "$WAL_METHOD" = "barman-wal-restore" ]; then
            # restore_command using barman-wal-restore
            RESTORE_CMD_ESCAPED="barman-wal-restore -U barman barman ${BACKUP_SERVER} %f %p"
        else
            # restore_command using SSH with barman get-wal (atomic-safe version)
            RESTORE_CMD_ESCAPED="test -f %p || (umask 077; tmp=\\\"%p.tmp.\\\$\\\$\\\"; ssh -o BatchMode=yes barman@barman \\\"barman get-wal ${BACKUP_SERVER} %f\\\" > \\\"\\\$tmp\\\" && mv \\\"\\\$tmp\\\" %p)"
        fi
        if [ "$TARGET_TIME" = "latest" ]; then
            RECOVERY_TARGET_TIME=""
        else
            RECOVERY_TARGET_TIME="$TARGET_TIME"
        fi
        
        docker exec "$TARGET_NODE" bash -c "
            printf '# Do not edit this file manually!\n' > $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# It will be overwritten by the ALTER SYSTEM command.\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Restore command options:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman-wal-restore: barman-wal-restore -U barman barman %s %%f %%p\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman get-wal: test -f %%p || (umask 077; tmp=\\\"%%p.tmp.$$\"; ssh -o BatchMode=yes barman@barman \"barman get-wal %s %%f\" > \"\\\$tmp\" && mv \"\\\$tmp\" %%p)\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            if [ "$WAL_METHOD" = "barman-wal-restore" ]; then
                printf '# Using: barman-wal-restore method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            else
                printf '# Using: barman get-wal method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            fi
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Recovery settings (for reference):\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# restore_command = '\''%s'\''\n' '$RESTORE_CMD_ESCAPED' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        # Only set recovery_target_time if not 'latest' (when 'latest', recover to end of WAL)
        if [ -n "$RECOVERY_TARGET_TIME" ]; then
            docker exec "$TARGET_NODE" bash -c "
                printf '# recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            " 2>&1
        fi
        docker exec "$TARGET_NODE" bash -c "
            printf '# recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf 'restore_command = '\''%s'\''\n' '$RESTORE_CMD_ESCAPED' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        # Set recovery_target_timeline to 'latest' to allow following timeline switches
        # This is needed when there are timeline switches (e.g., from timeline 10 to 13)
        docker exec "$TARGET_NODE" bash -c "
            printf 'recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
        if [ -n "$RECOVERY_TARGET_TIME" ]; then
            docker exec "$TARGET_NODE" bash -c "
                printf 'recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            " 2>&1
        fi
        docker exec "$TARGET_NODE" bash -c "
            printf 'recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# To start PostgreSQL manually for recovery, run:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# su - postgres -c \"/usr/lib/postgresql/15/bin/postgres -D %s -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info\"\n' '$PATRONI_DATA_DIR' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
    fi
    
    docker exec "$TARGET_NODE" chown postgres:postgres "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null
    docker exec "$TARGET_NODE" chmod 600 "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null
    
    # Verify the file was created correctly
    if docker exec "$TARGET_NODE" grep -q "restore_command" "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Recovery configuration in postgresql.auto.conf${NC}"
        echo -e "${CYAN}  Using pure Barman configuration from postgresql.auto.conf${NC}"
    else
        echo -e "${RED}  ✗ Failed to create recovery configuration in postgresql.auto.conf${NC}"
        exit 1
    fi
    
    
    # Step 7.5b: Create recovery.signal file to enable recovery mode
    echo -e "${YELLOW}[7.5b/10] Creating recovery.signal file...${NC}"
    if docker exec "$TARGET_NODE" touch "$PATRONI_DATA_DIR/recovery.signal" 2>/dev/null; then
        docker exec "$TARGET_NODE" chown postgres:postgres "$PATRONI_DATA_DIR/recovery.signal" 2>/dev/null
        docker exec "$TARGET_NODE" chmod 600 "$PATRONI_DATA_DIR/recovery.signal" 2>/dev/null
        echo -e "${GREEN}  ✓ recovery.signal created${NC}"
    else
        echo -e "${RED}  ✗ Failed to create recovery.signal${NC}"
        exit 1
    fi
    echo ""
    
    # Define OTHER_NODES array (will be used after successful restore)
    OTHER_NODES=()
    for node in db1 db2 db3 db4; do
        if [ "$node" != "$TARGET_NODE" ]; then
            OTHER_NODES+=("$node")
        fi
    done
    
    # Step 7.6a: Verify recovery configuration and test PostgreSQL startup
    echo -e "${YELLOW}[7.6a/10] Verifying recovery configuration...${NC}"
    
    # Check if restore_command is in postgresql.conf or postgresql.auto.conf
    RESTORE_CMD_IN_CONF=$(docker exec "$TARGET_NODE" grep -h "restore_command" "$PATRONI_DATA_DIR/postgresql.conf" "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null | grep -v "^#" | head -1 || echo "")
    if [ -z "$RESTORE_CMD_IN_CONF" ]; then
        echo -e "${RED}  ✗ restore_command not found in postgresql.conf or postgresql.auto.conf${NC}"
        echo -e "${YELLOW}  Checking postgresql.auto.conf content...${NC}"
        docker exec "$TARGET_NODE" cat "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null | head -20
        exit 1
    else
        echo -e "${GREEN}  ✓ restore_command found in configuration${NC}"
        echo -e "${CYAN}  ${RESTORE_CMD_IN_CONF}${NC}"
    fi
    
    # Check for recovery_target_time
    RECOVERY_TARGET=$(docker exec "$TARGET_NODE" grep -h "recovery_target_time" "$PATRONI_DATA_DIR/postgresql.conf" "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null | grep -v "^#" | head -1 || echo "")
    if [ -z "$RECOVERY_TARGET" ]; then
        echo -e "${YELLOW}  ⚠ recovery_target_time not found (will recover to end of WAL)${NC}"
    else
        echo -e "${GREEN}  ✓ recovery_target_time found${NC}"
        echo -e "${CYAN}  ${RECOVERY_TARGET}${NC}"
    fi
    
    # Check for recovery.signal
    if docker exec "$TARGET_NODE" test -f "$PATRONI_DATA_DIR/recovery.signal" 2>/dev/null; then
        echo -e "${GREEN}  ✓ recovery.signal file exists${NC}"
    else
        echo -e "${YELLOW}  ⚠ recovery.signal file not found${NC}"
    fi
    
    if [ "$START_RESTORE" = true ]; then
        echo -e "${CYAN}  Starting PostgreSQL to begin recovery...${NC}"
        echo -e "${CYAN}  Recovery will proceed automatically to the target time${NC}"
        echo -e "${CYAN}  PostgreSQL output will be shown in real-time below.${NC}"
        echo -e "${CYAN}  The script will automatically detect when recovery completes and continue.${NC}"
        echo ""
        
        # Start PostgreSQL in background so we can monitor it
        echo -e "${YELLOW}  Starting PostgreSQL (recovery will begin automatically)...${NC}"
        echo ""
        
        # Create a temporary file to capture output for error detection
        POSTGRES_LOG="/tmp/postgres_recovery_$$.log"
        
        # Run PostgreSQL in background and capture output
        docker exec "$TARGET_NODE" su - postgres -c "/usr/lib/postgresql/15/bin/postgres -D $PATRONI_DATA_DIR -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info" > "$POSTGRES_LOG" 2>&1 &
        POSTGRES_PID=$!
        
        # Monitor PostgreSQL output in real-time and detect when recovery completes
        RECOVERY_COMPLETE=false
        RECOVERY_FAILED=false
        MAX_WAIT=600  # 10 minutes max wait
        WAITED=0
        
        echo -e "${CYAN}  Monitoring recovery progress...${NC}"
        echo ""
        
        # Tail the log file and show output in real-time
        tail -f "$POSTGRES_LOG" 2>/dev/null &
        TAIL_PID=$!
        
        while [ $WAITED -lt $MAX_WAIT ]; do
            sleep 1
            WAITED=$((WAITED + 1))
            
            # Check if PostgreSQL process is still running
            if ! kill -0 $POSTGRES_PID 2>/dev/null; then
                # Process exited, check exit code
                wait $POSTGRES_PID
                POSTGRES_EXIT_CODE=$?
                RECOVERY_FAILED=true
                break
            fi
            
            # Check log for recovery completion
            if grep -q "database system is ready to accept connections" "$POSTGRES_LOG" 2>/dev/null; then
                # Check if recovery actually completed (not just ready during recovery)
                if ! grep -q "recovery ended before configured recovery target was reached" "$POSTGRES_LOG" 2>/dev/null; then
                    # Check if we're actually out of recovery mode
                    sleep 2  # Give it a moment to fully complete
                    if docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
                        RECOVERY_COMPLETE=true
                        break
                    fi
                fi
            fi
            
            # Check for recovery failure
            if grep -q "recovery ended before configured recovery target was reached" "$POSTGRES_LOG" 2>/dev/null; then
                RECOVERY_FAILED=true
                break
            fi
        done
        
        # Stop tailing the log
        kill $TAIL_PID 2>/dev/null || true
        wait $TAIL_PID 2>/dev/null || true
        
        # Read captured output for error detection
        POSTGRES_OUTPUT=$(cat "$POSTGRES_LOG" 2>/dev/null || echo "")
        
        # Show the output
        echo "$POSTGRES_OUTPUT"
        echo ""
        
        if [ "$RECOVERY_COMPLETE" = true ]; then
            echo -e "${GREEN}  ✓ Recovery completed successfully!${NC}"
            echo -e "${CYAN}  Stopping PostgreSQL to continue with cluster setup...${NC}"
            # Stop PostgreSQL gracefully
            docker exec "$TARGET_NODE" pkill -TERM -f "postgres.*patroni1" 2>/dev/null || true
            sleep 2
            # Force kill if still running
            docker exec "$TARGET_NODE" pkill -9 -f "postgres.*patroni1" 2>/dev/null || true
            POSTGRES_EXIT_CODE=0
        elif [ "$RECOVERY_FAILED" = true ]; then
            echo -e "${RED}  ✗ Recovery failed or PostgreSQL exited unexpectedly${NC}"
            POSTGRES_EXIT_CODE=${POSTGRES_EXIT_CODE:-1}
        else
            echo -e "${YELLOW}  ⚠ Recovery monitoring timeout (${MAX_WAIT}s)${NC}"
            echo -e "${CYAN}  Stopping PostgreSQL...${NC}"
            docker exec "$TARGET_NODE" pkill -TERM -f "postgres.*patroni1" 2>/dev/null || true
            sleep 2
            docker exec "$TARGET_NODE" pkill -9 -f "postgres.*patroni1" 2>/dev/null || true
            POSTGRES_EXIT_CODE=1
        fi
        
        # Clean up log file
        rm -f "$POSTGRES_LOG" 2>/dev/null || true
        
        echo ""
        echo -e "${CYAN}  PostgreSQL stopped (exit code: ${POSTGRES_EXIT_CODE})${NC}"
        
        # Check for recovery failure
        if echo "$POSTGRES_OUTPUT" | grep -q "recovery ended before configured recovery target was reached"; then
            echo ""
            echo -e "${RED}✗ FATAL: Recovery ended before reaching target time!${NC}"
            echo -e "${YELLOW}This usually means WAL files are not available for the target time period.${NC}"
            echo ""
            
            # Extract the last LSN reached from the logs
            LAST_LSN=$(echo "$POSTGRES_OUTPUT" | grep "redo done at" | tail -1 | sed 's/.*redo done at \([0-9A-F/]*\).*/\1/' || echo "")
            if [ -n "$LAST_LSN" ]; then
                echo -e "${CYAN}Recovery reached LSN: ${LAST_LSN}${NC}"
                echo -e "${CYAN}Target time: ${TARGET_TIME}${NC}"
                echo ""
            fi
            
            # Check what WAL files are actually available
            echo -e "${CYAN}Checking available WAL files...${NC}"
            # Extract timeline from backup info
            BACKUP_TIMELINE=$(echo "$BACKUP_INFO" | grep "Timeline" | sed 's/.*Timeline[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ' || echo "")
            if [ -z "$BACKUP_TIMELINE" ]; then
                # Fallback: try to extract from End WAL (first 8 hex chars = timeline)
                BACKUP_END_WAL=$(echo "$BACKUP_INFO" | grep "End WAL" | sed 's/.*End WAL[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ')
                if [ -n "$BACKUP_END_WAL" ]; then
                    BACKUP_TIMELINE_HEX=$(echo "$BACKUP_END_WAL" | cut -c1-8)
                    # Convert hex timeline to decimal for printf
                    BACKUP_TIMELINE=$((0x$BACKUP_TIMELINE_HEX))
                fi
            fi
            # Format timeline as 8-digit hex (e.g., 7 -> 00000007)
            TIMELINE_PATTERN=$(printf "%08X" "$BACKUP_TIMELINE" 2>/dev/null || echo "00000004")
            AVAILABLE_WALS=$(docker exec barman find /data/pg-backup/${BACKUP_SERVER}/wals -type f -name "${TIMELINE_PATTERN}*" ! -name "*.backup" ! -name "*.partial" 2>/dev/null | xargs -I {} basename {} | sort -u || echo "")
            if [ -n "$AVAILABLE_WALS" ]; then
                echo -e "${CYAN}Available WAL files in barman:${NC}"
                echo "$AVAILABLE_WALS" | head -10
                WAL_COUNT=$(echo "$AVAILABLE_WALS" | wc -l)
                echo -e "${CYAN}  Total: ${WAL_COUNT} WAL file(s)${NC}"
                
                # Check for gaps
                BACKUP_END_WAL=$(echo "$BACKUP_INFO" | grep "End WAL" | sed 's/.*End WAL[[:space:]]*:[[:space:]]*\(.*\)/\1/' | tr -d ' ')
                if [ -n "$BACKUP_END_WAL" ]; then
                    echo -e "${CYAN}  Backup ended at WAL: ${BACKUP_END_WAL}${NC}"
                    # Extract the segment number (last part after the timeline)
                    END_SEGMENT=$(echo "$BACKUP_END_WAL" | sed 's/.*\([0-9A-F]\{8\}\)$/\1/')
                    NEXT_SEGMENT_HEX=$(printf "%08X" $((0x$END_SEGMENT + 1)) 2>/dev/null || echo "")
                    if [ -n "$NEXT_SEGMENT_HEX" ]; then
                        NEXT_WAL="${BACKUP_END_WAL%????????}${NEXT_SEGMENT_HEX}"
                        # Check if next WAL exists (complete or partial)
                        PARTIAL_WAL=$(docker exec barman find /data/pg-backup/${BACKUP_SERVER}/wals -type f -name "${NEXT_WAL}.partial" 2>/dev/null | head -1 || echo "")
                        if echo "$AVAILABLE_WALS" | grep -q "^${NEXT_WAL}$"; then
                            echo -e "${GREEN}  ✓ Next WAL file (${NEXT_WAL}) exists${NC}"
                        elif [ -n "$PARTIAL_WAL" ]; then
                            echo -e "${RED}  ✗ Next WAL file (${NEXT_WAL}) is PARTIAL - this is the problem!${NC}"
                            echo -e "${YELLOW}  PostgreSQL cannot use partial WAL files for recovery.${NC}"
                            echo -e "${YELLOW}  The WAL file is still being written or hasn't been fully archived.${NC}"
                            echo ""
                            echo -e "${CYAN}  Solutions:${NC}"
                            echo -e "    1. ${BOLD}Use 'latest' to recover to the most recent complete state (RECOMMENDED)${NC}"
                            echo -e "       Command: bash scripts/perform_pitr.sh ${BACKUP_ID} latest --server ${BACKUP_SERVER} --target ${TARGET_NODE} --restore"
                            echo -e "    2. Wait for the WAL file to be fully archived, then retry"
                            echo -e "    3. Use a target time before this WAL file is needed"
                        else
                            echo -e "${RED}  ✗ Next WAL file (${NEXT_WAL}) is MISSING - this is likely the problem!${NC}"
                            echo -e "${YELLOW}  WAL files must be sequential. Recovery cannot proceed without ${NEXT_WAL}.${NC}"
                        fi
                    fi
                fi
            else
                echo -e "${YELLOW}  Could not list WAL files${NC}"
            fi
            echo ""
            
            echo -e "${CYAN}Possible causes:${NC}"
            echo -e "  1. WAL archiving was not active during the target time period"
            echo -e "  2. WAL files were not archived to barman (check for gaps in WAL sequence)"
            echo -e "  3. The target time is beyond available WAL files"
            echo ""
            echo -e "${CYAN}Check WAL availability:${NC}"
            echo -e "  docker exec barman ls -lh /data/pg-backup/${BACKUP_SERVER}/wals/*/"
            echo -e "  docker exec barman barman show-server ${BACKUP_SERVER} | grep -i archive"
            echo ""
            echo -e "${CYAN}Check restore_command:${NC}"
            echo -e "  docker exec ${TARGET_NODE} cat ${PATRONI_DATA_DIR}/postgresql.auto.conf | grep restore_command"
            echo ""
            echo -e "${YELLOW}Solutions:${NC}"
            echo -e "  1. Try recovering to an earlier time (closer to backup end time: ${BACKUP_END_TIME})"
            echo -e "  2. Use 'latest' to recover to the most recent available state"
            echo -e "  3. Check why WAL archiving stopped or failed"
            exit 1
        elif [ "$POSTGRES_EXIT_CODE" != "0" ] && [ -n "$POSTGRES_EXIT_CODE" ]; then
            echo ""
            echo -e "${YELLOW}  PostgreSQL process exited with code ${POSTGRES_EXIT_CODE}${NC}"
            echo -e "${CYAN}  Check recovery status with: bash scripts/monitor_recovery.sh ${TARGET_NODE}${NC}"
            echo -e "${CYAN}  Check logs: docker exec ${TARGET_NODE} tail -100 /var/log/postgresql/*.log${NC}"
        else
            echo ""
            echo -e "${GREEN}  ✓ PostgreSQL recovery process completed${NC}"
            
            # Step 7.6: Stop other nodes (only after successful restore)
            echo ""
            echo -e "${YELLOW}[7.6/10] Stopping other cluster nodes...${NC}"
            for node in "${OTHER_NODES[@]}"; do
                echo -e "${CYAN}  Stopping ${node}...${NC}"
                stop_patroni "$node"
            done
            echo -e "${GREEN}  ✓ Other nodes stopped${NC}"
        fi
        echo ""
        
        # Step 7.7: Start Patroni on target node and verify it becomes leader
        echo -e "${YELLOW}[7.7/10] Starting Patroni on ${TARGET_NODE}...${NC}"
        START_PATRONI_CMD="docker exec ${TARGET_NODE} supervisorctl start patroni"
        echo -e "${CYAN}  Executing: ${START_PATRONI_CMD}${NC}"
        if start_patroni "$TARGET_NODE"; then
            echo -e "${GREEN}  ✓ Patroni started${NC}"
        else
            echo -e "${RED}  ✗ Failed to start Patroni${NC}"
            echo -e "${YELLOW}  Check logs: docker exec ${TARGET_NODE} tail -f /var/log/postgresql/*.log${NC}"
            exit 1
        fi
        
        # Wait a moment for Patroni to initialize
        sleep 5
        
        # Step 7.8: Verify target node is leader
        echo -e "${YELLOW}[7.8/10] Verifying ${TARGET_NODE} is leader...${NC}"
        MAX_WAIT=60
        WAITED=0
        while [ $WAITED -lt $MAX_WAIT ]; do
            if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q "${TARGET_NODE}.*Leader"; then
                echo -e "${GREEN}  ✓ ${TARGET_NODE} is now the leader${NC}"
                break
            fi
            sleep 2
            WAITED=$((WAITED + 2))
            echo -e "${CYAN}  Waiting for ${TARGET_NODE} to become leader... (${WAITED}s/${MAX_WAIT}s)${NC}"
        done
        
        if [ $WAITED -ge $MAX_WAIT ]; then
            echo -e "${YELLOW}  ⚠ ${TARGET_NODE} did not become leader automatically${NC}"
            FAILOVER_CMD="docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml failover ${PATRONI_CLUSTER_NAME} --candidate ${TARGET_NODE} --force"
            echo -e "${CYAN}  Executing failover: ${FAILOVER_CMD}${NC}"
            if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml failover "$PATRONI_CLUSTER_NAME" --candidate "$TARGET_NODE" --force 2>&1; then
                echo -e "${GREEN}  ✓ Failover command executed${NC}"
                sleep 5
            else
                echo -e "${YELLOW}  ⚠ Failover may have failed, check cluster status${NC}"
            fi
        fi
        
        # Step 7.9: Start other nodes (only if --auto-start is specified)
        if [ "$AUTO_START" = "true" ] && [ ${#OTHER_NODES[@]} -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}[7.9/10] Starting other cluster nodes...${NC}"
            for node in "${OTHER_NODES[@]}"; do
                echo -e "${CYAN}  Starting ${node}...${NC}"
                START_CMD="docker exec ${node} supervisorctl start patroni"
                echo -e "${YELLOW}    Executing: ${START_CMD}${NC}"
                if start_patroni "$node"; then
                    echo -e "${GREEN}    ✓ Patroni started on ${node}${NC}"
                else
                    echo -e "${YELLOW}    ⚠ Failed to start Patroni on ${node}, will continue${NC}"
                fi
                sleep 2
            done
            echo -e "${GREEN}  ✓ Other nodes started${NC}"
        elif [ ${#OTHER_NODES[@]} -gt 0 ]; then
            echo ""
            echo -e "${CYAN}[7.9/10] Skipping starting other nodes (--auto-start not specified)${NC}"
            echo -e "${CYAN}  To automatically start other nodes, use --auto-start${NC}"
        fi
        
        # Step 7.10: Reinitialize other nodes (only if --auto-start is specified)
        if [ "$AUTO_START" = "true" ] && [ ${#OTHER_NODES[@]} -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}[7.10/10] Reinitializing other nodes to join cluster...${NC}"
            echo -e "${CYAN}  This will reinitialize ${#OTHER_NODES[@]} node(s) as replicas from ${TARGET_NODE}${NC}"
            
            for node in "${OTHER_NODES[@]}"; do
                echo -e "${CYAN}  Reinitializing ${node}...${NC}"
                
                # Check if Patroni is running on the node
                if check_patroni_running "$node"; then
                    echo -e "${GREEN}    ✓ Patroni is running on ${node}${NC}"
                else
                    echo -e "${YELLOW}    ⚠ Patroni is not running on ${node}, attempting to start...${NC}"
                    START_CMD="docker exec ${node} supervisorctl start patroni"
                    echo -e "${YELLOW}      Executing: ${START_CMD}${NC}"
                    if start_patroni "$node"; then
                        echo -e "${GREEN}      ✓ Patroni started on ${node}${NC}"
                        sleep 5 # Give Patroni a moment to initialize
                    else
                        echo -e "${RED}      ✗ Failed to start Patroni on ${node}. Skipping reinitialization for this node.${NC}"
                        continue
                    fi
                fi
                
                REINIT_CMD="docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force"
                echo -e "${YELLOW}    Executing: ${REINIT_CMD}${NC}"
                if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml reinit "$PATRONI_CLUSTER_NAME" "$node" --force 2>&1; then
                    echo -e "${GREEN}    ✓ ${node} reinitialization started${NC}"
                else
                    echo -e "${YELLOW}    ⚠ ${node} reinitialization may have failed, check logs${NC}"
                fi
                sleep 2  # Small delay between reinitializations
            done
            echo -e "${GREEN}  ✓ Reinitialization commands executed${NC}"
            echo -e "${CYAN}  Note: Reinitialization may take several minutes. Monitor with:${NC}"
            echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
        fi
        
        echo ""
    else
        echo -e "${CYAN}  PostgreSQL recovery configuration is ready${NC}"
        echo -e "${YELLOW}  To start recovery manually, run:${NC}"
        echo -e "    docker exec ${TARGET_NODE} su - postgres -c \"/usr/lib/postgresql/15/bin/postgres -D ${PATRONI_DATA_DIR} -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info\""
        echo ""
        echo -e "${CYAN}  Or use Patroni to start:${NC}"
        echo -e "    docker exec ${TARGET_NODE} supervisorctl start patroni"
        echo ""
    fi
    
    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  PITR Application Complete (Step 7.6)${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""
    echo -e "${GREEN}✓ PITR data has been copied to ${TARGET_NODE}${NC}"
    echo -e "${GREEN}✓ Recovery configuration is set${NC}"
    
    if [ "$START_RESTORE" = true ]; then
        echo -e "${GREEN}✓ PostgreSQL recovery completed${NC}"
        echo -e "${GREEN}✓ Other cluster nodes have been stopped${NC}"
        echo -e "${GREEN}✓ Patroni started on ${TARGET_NODE}${NC}"
        if [ ${#OTHER_NODES[@]} -gt 0 ]; then
            echo -e "${GREEN}✓ Other nodes started and reinitialization initiated${NC}"
        fi
        echo ""
        echo -e "${CYAN}Cluster status:${NC}"
        echo -e "  docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
        echo ""
        echo -e "${CYAN}Monitor reinitialization progress:${NC}"
        echo -e "  docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
    else
        echo ""
        echo -e "${CYAN}To start recovery manually, run:${NC}"
        echo -e "  docker exec ${TARGET_NODE} su - postgres -c \"/usr/lib/postgresql/15/bin/postgres -D ${PATRONI_DATA_DIR} -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info\""
        echo ""
        echo -e "${CYAN}Or use Patroni to start:${NC}"
        echo -e "  docker exec ${TARGET_NODE} supervisorctl start patroni"
        echo ""
        echo -e "${CYAN}After recovery completes:${NC}"
        echo -e "  1. Monitor recovery: bash scripts/monitor_recovery.sh ${TARGET_NODE}"
        echo -e "  2. Check cluster status: docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
        echo -e "  3. Once recovery completes, promote to leader if needed:"
        echo -e "     docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml failover ${PATRONI_CLUSTER_NAME} --candidate ${TARGET_NODE} --force"
        echo -e "  4. Reinitialize other nodes:"
        for node in "${OTHER_NODES[@]}"; do
            echo -e "     docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force"
        done
    fi
    
    echo ""
    echo -e "${YELLOW}Note:${NC} Old data backed up to ${BACKUP_DATA_DIR}"
    echo ""
    exit 0
    
    # Step 7.7: Start Patroni on target node
    echo -e "${YELLOW}[7.7/10] Starting Patroni on ${TARGET_NODE}...${NC}"
    if start_patroni "$TARGET_NODE"; then
        echo -e "${GREEN}  ✓ Patroni started${NC}"
    else
        echo -e "${RED}  ✗ Failed to start Patroni${NC}"
        echo -e "${YELLOW}  Check logs: docker exec ${TARGET_NODE} tail -f /var/log/postgresql/*.log${NC}"
        exit 1
    fi
    
    # Step 7.7a: Re-apply postgresql.auto.conf after Patroni starts (it may have been overwritten)
    echo -e "${CYAN}[7.7a/10] Ensuring recovery configuration is set...${NC}"
    sleep 2  # Give Patroni a moment to initialize
    # Build restore_command based on selected method
    if [ "$WAL_METHOD" = "barman-wal-restore" ]; then
        # restore_command using barman-wal-restore with SSH batch mode
        RESTORE_CMD_ESCAPED="barman-wal-restore -U barman barman ${BACKUP_SERVER} %f %p"
    else
        # restore_command using SSH with barman get-wal (atomic-safe version)
        RESTORE_CMD_ESCAPED="test -f %p || (umask 077; tmp=\\\"%p.tmp.$$\\\"; ssh -o BatchMode=yes barman@barman \\\"barman get-wal ${BACKUP_SERVER} %f\\\" > \\\"\\\$tmp\\\" && mv \\\"\\\$tmp\\\" %p)"
    fi
        docker exec "$TARGET_NODE" bash -c "
            printf '# Do not edit this file manually!\n' > $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# It will be overwritten by the ALTER SYSTEM command.\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Restore command options:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman-wal-restore: barman-wal-restore -U barman barman %s %%f %%p\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '#   barman get-wal: test -f %%p || (umask 077; tmp=\\\"%%p.tmp.$$\"; ssh -o BatchMode=yes barman@barman \"barman get-wal %s %%f\" > \"\\\$tmp\" && mv \"\\\$tmp\" %%p)\n' '${BACKUP_SERVER}' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            if [ \"$WAL_METHOD\" = \"barman-wal-restore\" ]; then
                printf '# Using: barman-wal-restore method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            else
                printf '# Using: barman get-wal method\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            fi
            printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# Recovery settings (for reference):\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# restore_command = '\''%s'\''\n' '$RESTORE_CMD_ESCAPED' >> $PATRONI_DATA_DIR/postgresql.auto.conf
            printf '# recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
    # Only set recovery_target_time if not 'latest' (when 'latest', recover to end of WAL)
    if [ -n "$RECOVERY_TARGET_TIME" ]; then
        docker exec "$TARGET_NODE" bash -c "
            printf '# recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
    fi
    docker exec "$TARGET_NODE" bash -c "
        printf '# recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf 'restore_command = '\''%s'\''\n' '$RESTORE_CMD_ESCAPED' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf 'recovery_target_timeline = '\''latest'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
    " 2>&1
    if [ -n "$RECOVERY_TARGET_TIME" ]; then
        docker exec "$TARGET_NODE" bash -c "
            printf 'recovery_target_time = '\''%s'\''\n' '$RECOVERY_TARGET_TIME' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        " 2>&1
    fi
    docker exec "$TARGET_NODE" bash -c "
        printf 'recovery_target_action = '\''promote'\''\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf '\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf '# To start PostgreSQL manually for recovery, run:\n' >> $PATRONI_DATA_DIR/postgresql.auto.conf
        printf '# su - postgres -c \"/usr/lib/postgresql/15/bin/postgres -D %s -p 5431 -c logging_collector=off -c log_destination=stderr -c log_min_messages=info\"\n' '$PATRONI_DATA_DIR' >> $PATRONI_DATA_DIR/postgresql.auto.conf
    " 2>&1
    docker exec "$TARGET_NODE" chown postgres:postgres "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null
    docker exec "$TARGET_NODE" chmod 600 "$PATRONI_DATA_DIR/postgresql.auto.conf" 2>/dev/null
    echo -e "${GREEN}  ✓ Recovery configuration re-applied${NC}"
    echo ""
    
    # Step 7.8: Wait for PostgreSQL to start and recovery to begin
    echo -e "${YELLOW}[7.8/10] Waiting for PostgreSQL to start...${NC}"
    echo -e "${CYAN}  Note: Recovery can take several minutes depending on WAL size${NC}"
    MAX_WAIT=300  # Increased to 5 minutes for recovery
    WAITED=0
    POSTGRES_READY=false
    
    while [ $WAITED -lt $MAX_WAIT ]; do
        if docker exec "$TARGET_NODE" pg_isready -U postgres -p 5431 -h localhost >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ PostgreSQL is accepting connections${NC}"
            POSTGRES_READY=true
            break
        fi
        
        # Check if PostgreSQL process is running
        if ! docker exec "$TARGET_NODE" ps aux | grep -q "[p]ostgres.*patroni1"; then
            echo -e "${RED}  ✗ PostgreSQL process not running!${NC}"
            echo -e "${CYAN}  Check logs: docker logs ${TARGET_NODE}${NC}"
            exit 1
        fi
        
        # Show recovery status if possible
        RECOVERY_STATUS=$(docker exec "$TARGET_NODE" psql -U postgres -p 5431 -h localhost -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ' || echo "starting")
        if [ "$RECOVERY_STATUS" = "t" ] || [ "$RECOVERY_STATUS" = "true" ]; then
            echo -e "${CYAN}  Still in recovery... (${WAITED}s/${MAX_WAIT}s)${NC}"
        elif [ "$RECOVERY_STATUS" = "starting" ]; then
            echo -e "${CYAN}  Starting up... (${WAITED}s/${MAX_WAIT}s)${NC}"
        else
            echo -e "${CYAN}  Waiting... (${WAITED}s/${MAX_WAIT}s)${NC}"
        fi
        
        sleep 5
        WAITED=$((WAITED + 5))
    done
    
    if [ "$POSTGRES_READY" != "true" ]; then
        echo -e "${YELLOW}  ⚠ PostgreSQL did not become ready within ${MAX_WAIT}s${NC}"
        echo -e "${CYAN}  This is normal for large recoveries. Continuing to monitor recovery...${NC}"
        echo -e "${CYAN}  You can monitor progress with: bash scripts/monitor_recovery.sh ${TARGET_NODE}${NC}"
        # Don't exit - continue to recovery monitoring step
    fi
    echo ""
    
    # Step 7.9: Monitor recovery progress (only if --auto-start is specified)
    if [ "$AUTO_START" = "true" ]; then
        echo -e "${YELLOW}[7.9/10] Monitoring recovery progress...${NC}"
        echo -e "${CYAN}  Checking recovery status...${NC}"
    
    # Wait for PostgreSQL to be queryable first
    QUERY_WAIT=0
    MAX_QUERY_WAIT=120
    while [ $QUERY_WAIT -lt $MAX_QUERY_WAIT ]; do
        if docker exec "$TARGET_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -c "SELECT 1;" >/dev/null 2>&1; then
            break
        fi
        echo -e "${CYAN}  Waiting for PostgreSQL to accept queries... (${QUERY_WAIT}s/${MAX_QUERY_WAIT}s)${NC}"
        sleep 5
        QUERY_WAIT=$((QUERY_WAIT + 5))
    done
    
    MAX_RECOVERY_WAIT=600  # 10 minutes for recovery
    RECOVERY_WAITED=0
    IS_RECOVERY="unknown"
    PREV_WAL_LSN=""
    PROMOTE_ATTEMPTED=""
    
    while [ $RECOVERY_WAITED -lt $MAX_RECOVERY_WAIT ]; do
        IS_RECOVERY=$(docker exec "$TARGET_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ' || echo "unknown")
        
        if [ "$IS_RECOVERY" = "f" ] || [ "$IS_RECOVERY" = "false" ]; then
            echo -e "${GREEN}  ✓ Recovery completed!${NC}"
            
            # Step 7.10: Stop all nodes, then start and promote target
            echo ""
            echo -e "${YELLOW}[7.10/10] Stopping all nodes and promoting target node...${NC}"
            
            # Stop all nodes
            echo -e "${CYAN}  Stopping all cluster nodes...${NC}"
            for node in db1 db2 db3 db4; do
                if [ "$node" != "$TARGET_NODE" ]; then
                    echo -e "${CYAN}    Stopping ${node}...${NC}"
                    stop_patroni "$node"
                fi
            done
            
            # Stop target node (it's currently running PostgreSQL directly, not via Patroni)
            echo -e "${CYAN}    Stopping ${TARGET_NODE}...${NC}"
            docker exec "$TARGET_NODE" pkill -TERM -f "postgres.*patroni" 2>/dev/null || true
            sleep 3
            docker exec "$TARGET_NODE" pkill -9 -f "postgres.*patroni" 2>/dev/null || true
            
            # Start target node with Patroni
            echo -e "${CYAN}  Starting ${TARGET_NODE} with Patroni...${NC}"
            start_patroni "$TARGET_NODE"
            
            # Wait for PostgreSQL to be ready
            echo -e "${CYAN}  Waiting for PostgreSQL to be ready...${NC}"
            sleep 5
            MAX_START_WAIT=60
            START_WAITED=0
            while [ $START_WAITED -lt $MAX_START_WAIT ]; do
                if docker exec "$TARGET_NODE" pg_isready -U postgres -p 5431 -h localhost >/dev/null 2>&1; then
                    echo -e "${GREEN}  ✓ PostgreSQL is ready${NC}"
                    break
                fi
                sleep 2
                START_WAITED=$((START_WAITED + 2))
            done
            
            # Promote target node to leader
            echo -e "${CYAN}  Promoting ${TARGET_NODE} to leader...${NC}"
            if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml failover "$PATRONI_CLUSTER_NAME" --candidate "$TARGET_NODE" --force 2>&1; then
                echo -e "${GREEN}  ✓ Promotion command executed${NC}"
                sleep 5
                # Verify promotion
                CLUSTER_STATUS=$(docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
                if echo "$CLUSTER_STATUS" | grep -q "${TARGET_NODE}.*Leader"; then
                    echo -e "${GREEN}  ✓ ${TARGET_NODE} is now the leader${NC}"
                else
                    echo -e "${YELLOW}  ⚠ ${TARGET_NODE} promotion status unclear, check cluster status${NC}"
                fi
            else
                echo -e "${YELLOW}  ⚠ Promotion command failed, ${TARGET_NODE} may already be leader${NC}"
            fi
            
            break
        elif [ "$IS_RECOVERY" = "t" ] || [ "$IS_RECOVERY" = "true" ]; then
            # Get recovery progress info if available
            WAL_LSN=$(docker exec "$TARGET_NODE" psql -U postgres -d "$DEFAULT_DATABASE" -p 5431 -h localhost -t -A -c "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tr -d ' ' || echo "")
            if [ -n "$WAL_LSN" ] && [ "$WAL_LSN" != "" ]; then
                echo -e "${CYAN}  Recovery in progress... WAL LSN: ${WAL_LSN} (${RECOVERY_WAITED}s/${MAX_RECOVERY_WAIT}s)${NC}"
                
                # Check if LSN hasn't changed for a while (recovery might have reached target and paused)
                if [ -n "$PREV_WAL_LSN" ] && [ "$WAL_LSN" = "$PREV_WAL_LSN" ] && [ $RECOVERY_WAITED -gt 60 ]; then
                    # LSN hasn't changed for 60+ seconds, recovery might be paused at target time
                    if [ -z "$PROMOTE_ATTEMPTED" ]; then
                        echo -e "${YELLOW}  ⚠ Recovery appears paused (LSN unchanged for 60s). Promoting via Patroni...${NC}"
                        # Use Patroni's failover command to promote this node to leader
                        echo -e "${CYAN}  Executing: patronictl failover ${PATRONI_CLUSTER_NAME} --candidate ${TARGET_NODE} --force${NC}"
                        if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml failover "$PATRONI_CLUSTER_NAME" --candidate "$TARGET_NODE" --force >/dev/null 2>&1; then
                            echo -e "${GREEN}  ✓ Failover command executed${NC}"
                            sleep 10  # Give Patroni time to promote
                            PROMOTE_ATTEMPTED="true"
                        else
                            echo -e "${YELLOW}  ⚠ Failover command failed, will retry...${NC}"
                        fi
                    else
                        # Already attempted, just waiting for it to take effect
                        echo -e "${CYAN}  Waiting for promotion to complete... (${RECOVERY_WAITED}s/${MAX_RECOVERY_WAIT}s)${NC}"
                    fi
                fi
                PREV_WAL_LSN="$WAL_LSN"
            else
                echo -e "${CYAN}  Recovery in progress... (${RECOVERY_WAITED}s/${MAX_RECOVERY_WAIT}s)${NC}"
            fi
        else
            echo -e "${CYAN}  Waiting for PostgreSQL to be queryable... (${RECOVERY_WAITED}s/${MAX_RECOVERY_WAIT}s)${NC}"
        fi
        
        sleep 10
        RECOVERY_WAITED=$((RECOVERY_WAITED + 10))
    done
    
        if [ "$IS_RECOVERY" != "f" ] && [ "$IS_RECOVERY" != "false" ]; then
            echo -e "${YELLOW}  ⚠ Recovery still in progress after ${MAX_RECOVERY_WAIT}s${NC}"
            echo -e "${CYAN}  This is normal for large recoveries. You can continue monitoring:${NC}"
            echo -e "    bash scripts/monitor_recovery.sh ${TARGET_NODE}"
            echo -e "${CYAN}  Or check status manually:${NC}"
            echo -e "    docker exec ${TARGET_NODE} psql -U postgres -d ${DEFAULT_DATABASE} -p 5431 -h localhost -c \"SELECT pg_is_in_recovery();\""
        fi
        echo ""
        
        # Step 7.10: Stop all nodes, start target, and promote (only if recovery completed)
        if [ "$IS_RECOVERY" = "f" ] || [ "$IS_RECOVERY" = "false" ]; then
        echo -e "${YELLOW}[7.10/10] Stopping all nodes and promoting ${TARGET_NODE}...${NC}"
        
        # Stop all nodes
        echo -e "${CYAN}  Stopping all cluster nodes...${NC}"
        for node in db1 db2 db3 db4; do
            if [ "$node" != "$TARGET_NODE" ]; then
                echo -e "${CYAN}    Stopping ${node}...${NC}"
                stop_patroni "$node"
            fi
        done
        
        # Stop target node (it's currently running PostgreSQL directly, not via Patroni)
        echo -e "${CYAN}    Stopping ${TARGET_NODE} (PostgreSQL)...${NC}"
        docker exec "$TARGET_NODE" pkill -TERM -f "postgres.*patroni" 2>/dev/null || true
        sleep 3
        docker exec "$TARGET_NODE" pkill -9 -f "postgres.*patroni" 2>/dev/null || true
        
        # Start target node with Patroni
        echo -e "${CYAN}  Starting ${TARGET_NODE} with Patroni...${NC}"
        start_patroni "$TARGET_NODE"
        
        # Wait for PostgreSQL to be ready
        echo -e "${CYAN}  Waiting for PostgreSQL to be ready...${NC}"
        sleep 5
        MAX_START_WAIT=60
        START_WAITED=0
        while [ $START_WAITED -lt $MAX_START_WAIT ]; do
            if docker exec "$TARGET_NODE" pg_isready -U postgres -p 5431 -h localhost >/dev/null 2>&1; then
                echo -e "${GREEN}  ✓ PostgreSQL is ready${NC}"
                break
            fi
            sleep 2
            START_WAITED=$((START_WAITED + 2))
        done
        
        # Promote target node to leader
        echo -e "${CYAN}  Promoting ${TARGET_NODE} to leader...${NC}"
        if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml failover "$PATRONI_CLUSTER_NAME" --candidate "$TARGET_NODE" --force 2>&1; then
            echo -e "${GREEN}  ✓ Promotion command executed${NC}"
            sleep 5
            # Verify promotion
            CLUSTER_STATUS=$(docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || echo "")
            if echo "$CLUSTER_STATUS" | grep -q "${TARGET_NODE}.*Leader"; then
                echo -e "${GREEN}  ✓ ${TARGET_NODE} is now the leader${NC}"
            else
                echo -e "${YELLOW}  ⚠ ${TARGET_NODE} promotion status unclear, check cluster status${NC}"
            fi
        else
            echo -e "${YELLOW}  ⚠ Promotion command failed, ${TARGET_NODE} may already be leader${NC}"
        fi
        else
            echo -e "${YELLOW}[7.10/10] Recovery not yet complete, skipping node promotion${NC}"
            echo -e "${CYAN}  Recovery status: ${IS_RECOVERY}${NC}"
            echo -e "${CYAN}  Once recovery completes, manually:${NC}"
            echo -e "${CYAN}    1. Stop all nodes: docker-compose stop db1 db2 db3 db4${NC}"
            echo -e "${CYAN}    2. Start target node: docker exec ${TARGET_NODE} supervisorctl start patroni${NC}"
            echo -e "${CYAN}    3. Promote target: docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml failover ${PATRONI_CLUSTER_NAME} --candidate ${TARGET_NODE} --force${NC}"
        fi
    else
        echo -e "${YELLOW}[7.9/10] Skipping recovery monitoring (--auto-start not specified)${NC}"
        echo -e "${CYAN}  To automatically monitor recovery and promote the target node, use --auto-start${NC}"
        echo -e "${CYAN}  You can manually monitor recovery with:${NC}"
        echo -e "    bash scripts/monitor_recovery.sh ${TARGET_NODE}"
        echo ""
        echo -e "${CYAN}  Once recovery completes, manually:${NC}"
        echo -e "${CYAN}    1. Stop all nodes: docker-compose stop db1 db2 db3 db4${NC}"
        echo -e "${CYAN}    2. Start target node: docker exec ${TARGET_NODE} supervisorctl start patroni${NC}"
        echo -e "${CYAN}    3. Promote target: docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml failover ${PATRONI_CLUSTER_NAME} --candidate ${TARGET_NODE} --force${NC}"
    fi
    echo ""
    
    # Step 7.10: Verify target node is leader (only if auto-start was used)
    if [ "$AUTO_START" = "true" ]; then
        # Verify target node is leader
        echo ""
        echo -e "${CYAN}  Verifying ${TARGET_NODE} is leader...${NC}"
        sleep 5  # Give Patroni time to initialize
        MAX_LEADER_WAIT=60
        LEADER_WAITED=0
        ROLE="unknown"
        while [ $LEADER_WAITED -lt $MAX_LEADER_WAIT ]; do
            ROLE=$(docker exec "$TARGET_NODE" sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
            if [ "$ROLE" = "primary" ] || [ "$ROLE" = "Leader" ]; then
                echo -e "${GREEN}  ✓ ${TARGET_NODE} is now the leader!${NC}"
                break
            fi
            echo -e "${CYAN}  Waiting for ${TARGET_NODE} to become leader (current role: ${ROLE})... (${LEADER_WAITED}s/${MAX_LEADER_WAIT}s)${NC}"
            sleep 3
            LEADER_WAITED=$((LEADER_WAITED + 3))
        done
        
        if [ "$ROLE" != "primary" ] && [ "$ROLE" != "Leader" ]; then
            echo -e "${YELLOW}  ⚠ ${TARGET_NODE} is not yet the leader (current role: ${ROLE})${NC}"
            echo -e "${CYAN}  Attempting to promote ${TARGET_NODE} using Patroni failover...${NC}"
            if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml failover "$PATRONI_CLUSTER_NAME" --candidate "$TARGET_NODE" --force >/dev/null 2>&1; then
                echo -e "${GREEN}  ✓ Failover command executed${NC}"
                sleep 10
                ROLE=$(docker exec "$TARGET_NODE" sh -c "curl -s http://localhost:8001/patroni 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"role\", \"unknown\"))'" 2>/dev/null || echo "unknown")
                if [ "$ROLE" = "primary" ] || [ "$ROLE" = "Leader" ]; then
                    echo -e "${GREEN}  ✓ ${TARGET_NODE} is now the leader!${NC}"
            else
                echo -e "${YELLOW}  ⚠ ${TARGET_NODE} is still not the leader (current role: ${ROLE})${NC}"
                echo -e "${CYAN}  Check cluster status:${NC}"
                echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
            fi
        else
            echo -e "${RED}  ✗ Failed to execute failover command${NC}"
            echo -e "${CYAN}  Check cluster status:${NC}"
            echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
        fi
        fi
    fi
    echo ""
    
    # Step 7.11: Reinitialize other nodes to join the cluster (only if --auto-start is specified)
    if [ "$AUTO_START" = "true" ] && [ ${#OTHER_NODES[@]} -gt 0 ]; then
        echo -e "${YELLOW}[7.11/11] Reinitializing other nodes to join cluster...${NC}"
        echo -e "${CYAN}  This will reinitialize ${#OTHER_NODES[@]} node(s) as replicas from ${TARGET_NODE}${NC}"
        # Auto-start mode: proceed without prompting
        REPLY="y"
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            for node in "${OTHER_NODES[@]}"; do
                echo -e "${CYAN}  Checking ${node} before reinitialization...${NC}"
                
                # Check if Patroni is running on the node
                if ! check_patroni_running "$node"; then
                    echo -e "${YELLOW}    ⚠ Patroni is not running on ${node}. Starting Patroni...${NC}"
                    if start_patroni "$node"; then
                        echo -e "${GREEN}    ✓ Patroni started on ${node}${NC}"
                        sleep 5  # Give Patroni time to initialize
                    else
                        echo -e "${RED}    ✗ Failed to start Patroni on ${node}. Skipping reinitialization.${NC}"
                        echo -e "${CYAN}    You can start it manually and retry:${NC}"
                        echo -e "      docker exec ${node} supervisorctl start patroni"
                        continue
                    fi
                else
                    echo -e "${GREEN}    ✓ Patroni is running on ${node}${NC}"
                fi
                
                echo -e "${CYAN}  Reinitializing ${node}...${NC}"
                REINIT_CMD="docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force"
                echo -e "${YELLOW}    Executing: ${REINIT_CMD}${NC}"
                if docker exec "$TARGET_NODE" patronictl -c /etc/patroni/patroni.yml reinit "$PATRONI_CLUSTER_NAME" "$node" --force 2>&1; then
                    echo -e "${GREEN}    ✓ ${node} reinitialization started${NC}"
                else
                    echo -e "${YELLOW}    ⚠ ${node} reinitialization may have failed, check logs${NC}"
                fi
                sleep 2  # Small delay between reinitializations
            done
            echo -e "${GREEN}  ✓ Reinitialization commands executed${NC}"
            echo -e "${CYAN}  Note: Reinitialization may take several minutes. Monitor with:${NC}"
            echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
        else
            echo -e "${YELLOW}  Skipping reinitialization. You can run it manually:${NC}"
            for node in "${OTHER_NODES[@]}"; do
                echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force"
            done
        fi
        echo ""
    elif [ ${#OTHER_NODES[@]} -gt 0 ]; then
        echo -e "${CYAN}[7.11/11] Skipping reinitialization of other nodes (--auto-start not specified)${NC}"
        echo -e "${CYAN}  To automatically reinitialize other nodes, use --auto-start${NC}"
        echo -e "${CYAN}  You can manually reinitialize nodes with:${NC}"
        for node in "${OTHER_NODES[@]}"; do
            echo -e "    docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force"
        done
        echo ""
    fi
    
    # Final summary
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  Automated PITR Complete${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""
    echo -e "${GREEN}✓ PITR has been applied to ${TARGET_NODE}${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Verify data: bash scripts/count_database_stats.sh"
    echo -e "  2. Check cluster status: docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
    if [ ${#OTHER_NODES[@]} -gt 0 ]; then
        echo -e "  3. Monitor reinitialization progress (if started):"
        echo -e "     docker exec ${TARGET_NODE} patronictl -c /etc/patroni/patroni.yml list"
    fi
    echo ""
    echo -e "${YELLOW}Note:${NC} Old data backed up to ${BACKUP_DATA_DIR}"
    echo ""
    exit 0
fi

# Step 7: Show next steps (manual mode)
echo -e "${BLUE}${BOLD}========================================${NC}"
echo -e "${BLUE}${BOLD}  Recovery Complete - Next Steps${NC}"
echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
echo -e "${CYAN}Recovery files location:${NC}"
echo -e "  Container: ${BOLD}barman:${CONTAINER_RECOVERY_DIR}${NC}"
if [ -n "$HOST_RECOVERY_DIR" ] && [ -d "$HOST_RECOVERY_DIR" ] 2>/dev/null; then
    echo -e "  Host:      ${BOLD}${HOST_RECOVERY_DIR}${NC}"
fi
echo ""

echo -e "${YELLOW}To apply the recovery (Patroni-aware):${NC}"
echo ""
echo -e "${CYAN}${BOLD}Recommended Approach for Patroni Cluster:${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Keep container running! Stop services inside container.${NC}"
echo ""
echo "1. Stop Patroni (which manages PostgreSQL):"
echo "   docker exec $TARGET_NODE pkill -f 'patroni /etc/patroni/patroni.yml'"
echo "   # This will automatically stop PostgreSQL"
echo ""
echo "   OR stop PostgreSQL directly:"
echo "   docker exec $TARGET_NODE su - postgres -c 'pg_ctl -D ${PATRONI_DATA_DIR} stop'"
echo ""
echo "2. Optionally disable Patroni config (prevents auto-restart):"
echo "   docker exec $TARGET_NODE mv /etc/patroni/patroni.yml /etc/patroni/patroni.yml.disabled"
echo ""
echo "3. Optionally disable Patroni config (prevents auto-start):"
echo "   docker exec $TARGET_NODE mv /etc/patroni/patroni.yml /etc/patroni/patroni.yml.disabled"
echo ""
echo "4. Backup current data:"
echo "   docker exec $TARGET_NODE mv ${PATRONI_DATA_DIR} ${PATRONI_DATA_DIR}.backup"
echo ""
echo "5. Copy recovered data from Barman container:"
echo "   docker cp barman:${CONTAINER_RECOVERY_DIR}/. $TARGET_NODE:${PATRONI_DATA_DIR}/"
echo ""
if [ -n "$HOST_RECOVERY_DIR" ] && [ -d "$HOST_RECOVERY_DIR" ] 2>/dev/null; then
    echo "   OR copy from host:"
    echo "   docker cp ${HOST_RECOVERY_DIR}/. $TARGET_NODE:${PATRONI_DATA_DIR}/"
    echo ""
fi
echo "6. Set correct permissions:"
echo "   docker exec $TARGET_NODE chown -R postgres:postgres ${PATRONI_DATA_DIR}"
echo ""
echo "7. Start PostgreSQL manually (recovery will begin automatically):"
echo "   docker exec $TARGET_NODE su - postgres -c 'pg_ctl -D ${PATRONI_DATA_DIR} start'"
echo ""
echo "   OR if Patroni config is disabled, restart supervisor:"
echo "   docker exec $TARGET_NODE pkill -HUP supervisord"
echo ""
echo "8. Monitor recovery progress:"
echo "   docker exec $TARGET_NODE tail -f /var/log/postgresql/*.log"
echo ""
echo "9. Verify recovery completed:"
echo "   docker exec $TARGET_NODE psql -U postgres -p 5432 -h localhost -c \"SELECT pg_is_in_recovery();\""
echo "   # Should return 'f' (false) when recovery is complete"
echo ""
echo "10. Verify data:"
echo "    ./scripts/count_database_stats.sh"
echo ""
echo -e "${CYAN}${BOLD}To promote PITR node as new leader:${NC}"
echo ""
echo "1. Stop other cluster nodes:"
echo "   docker-compose stop db1 db2 db3 db4  # Stop all except $TARGET_NODE"
echo ""
echo "2. Clear etcd cluster state (optional, if needed):"
echo "   docker exec etcd1 etcdctl del --prefix /service/patroni/"
echo ""
echo "3. Re-enable Patroni (if disabled):"
echo "   docker exec $TARGET_NODE mv /etc/patroni/patroni.yml.disabled /etc/patroni/patroni.yml"
echo ""
echo "4. Re-enable Patroni config and restart:"
echo "   docker exec $TARGET_NODE mv /etc/patroni/patroni.yml.disabled /etc/patroni/patroni.yml"
echo "   docker exec $TARGET_NODE pkill -HUP supervisord"
echo "   # Patroni will start automatically via supervisor"
echo ""
echo "5. Wait for Patroni to initialize:"
echo "   sleep 10"
echo ""
echo "6. Check cluster status:"
echo "   docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml list"
echo ""
echo "7. If needed, manually promote:"
echo "   docker exec $TARGET_NODE patronictl -c /etc/patroni/patroni.yml switchover --master $TARGET_NODE --candidate $TARGET_NODE --force"
echo ""
echo -e "${RED}${BOLD}⚠ WARNING:${NC} Applying recovery will overwrite existing data!"
echo -e "${YELLOW}Make sure you have backups before proceeding!${NC}"
echo -e "${YELLOW}For Patroni clusters, it's recommended to stop the node first!${NC}"
echo ""
echo -e "${CYAN}See PITR_PATRONI_GUIDE.md for detailed Patroni-specific instructions.${NC}"
echo ""

