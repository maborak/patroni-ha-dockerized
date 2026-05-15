#!/bin/bash
# scripts/backup/dump_database.sh — Logical backup (pg_dump) of a single database
# from a healthy replica, packaged as a .tgz on the host.
#
# Backup is taken from a replica (selected via Patroni REST API) to avoid loading
# the cluster leader. Falls back to leader only if explicitly forced via --node.
#
# Usage:
#   bash scripts/backup/dump_database.sh --db maborak
#   bash scripts/backup/dump_database.sh --interactive
#   bash scripts/backup/dump_database.sh --db tiktok --jobs 8 --output ./mybackups
#   bash scripts/backup/dump_database.sh --db maborak --node db3   # force source node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DB=""
NODE=""
OUTPUT_DIR="$PROJECT_ROOT/backups"
JOBS=4
INTERACTIVE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--db NAME] [--node dbN] [--output DIR] [--jobs N] [--interactive]

Creates a logical backup (.tgz) of a single database from a healthy replica.

Options:
  --db NAME           Database name to back up (required unless --interactive)
  --node dbN          Force specific source node (default: auto-pick healthy replica)
  --output DIR        Host directory for the .tgz (default: ./backups)
  --jobs N            pg_dump parallel jobs (default: 4)
  --interactive       Prompt for DB selection from a numbered list
  -h, --help          Show this help

Examples:
  $(basename "$0") --db maborak
  $(basename "$0") --interactive
  $(basename "$0") --db tiktok --jobs 8 --output ./mybackups
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --node) NODE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --interactive) INTERACTIVE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    echo -e "${RED}✗ --jobs must be a positive integer (got: $JOBS)${NC}" >&2
    exit 1
fi

# --- Pick source node ---------------------------------------------------------
if [ -z "$NODE" ]; then
    echo -e "${YELLOW}Finding a healthy replica...${NC}" >&2
    if ! NODE=$(detect_healthy_replica); then
        echo -e "${RED}✗ No healthy replica available.${NC}" >&2
        echo -e "${YELLOW}  Override with --node dbN (e.g. the leader) if you must.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Using replica: ${NODE}${NC}" >&2
else
    validate_node "$NODE" || exit 1
    LEADER=$(detect_leader_api 2>/dev/null || echo "")
    if [ "$NODE" = "$LEADER" ]; then
        echo -e "${YELLOW}⚠ Warning: ${NODE} is the cluster leader. Dump will load the primary.${NC}" >&2
    fi
fi

INTERNAL_PORT=$(get_internal_pg_port)

# --- Interactive DB selection -------------------------------------------------
if [ "$INTERACTIVE" = true ] || [ -z "$DB" ]; then
    echo -e "${YELLOW}Discovering databases on ${NODE}...${NC}" >&2
    DBS_RAW=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' ORDER BY datname;" 2>/dev/null || true)

    if [ -z "$DBS_RAW" ]; then
        echo -e "${RED}✗ No user databases found on ${NODE}.${NC}" >&2
        exit 1
    fi

    DB_ARRAY=()
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        DB_ARRAY+=("$d")
    done <<< "$DBS_RAW"

    echo "" >&2
    echo -e "${BLUE}${BOLD}Available databases on ${NODE}:${NC}" >&2
    for idx in "${!DB_ARRAY[@]}"; do
        echo -e "  ${CYAN}$((idx + 1)))${NC} ${DB_ARRAY[$idx]}" >&2
    done
    echo "" >&2

    echo -ne "${BOLD}Select database [1-${#DB_ARRAY[@]}]: ${NC}" >&2
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#DB_ARRAY[@]}" ]; then
        echo -e "${RED}✗ Invalid choice.${NC}" >&2
        exit 1
    fi
    DB="${DB_ARRAY[$((choice - 1))]}"
    echo -e "${GREEN}✓ Selected: $DB${NC}" >&2
fi

# --- Verify DB exists on source node ------------------------------------------
EXISTS=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
    "SELECT 1 FROM pg_database WHERE datname = '${DB//\'/\'\'}';" 2>/dev/null | tr -d ' ')
if [ "$EXISTS" != "1" ]; then
    echo -e "${RED}✗ Database '$DB' not found on ${NODE}.${NC}" >&2
    exit 1
fi

# --- Prepare paths ------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_NAME="${DB}_${TIMESTAMP}"
CONTAINER_DUMP_DIR="/tmp/${DUMP_NAME}"
CONTAINER_TGZ="/tmp/${DUMP_NAME}.tgz"
HOST_TGZ="${OUTPUT_DIR}/${DUMP_NAME}.tgz"

echo ""
echo -e "${BLUE}${BOLD}=== Backup Configuration ===${NC}"
echo -e "  ${CYAN}Database:${NC}    $DB"
echo -e "  ${CYAN}Source node:${NC} $NODE"
echo -e "  ${CYAN}Jobs:${NC}        $JOBS"
echo -e "  ${CYAN}Output:${NC}      $HOST_TGZ"
echo ""

cleanup() {
    docker exec "$NODE" rm -rf "$CONTAINER_DUMP_DIR" "$CONTAINER_TGZ" 2>/dev/null || true
}
trap cleanup EXIT

START_TS=$(date +%s)

echo -e "${YELLOW}[1/3] Running pg_dump (directory format, -j ${JOBS})...${NC}"
docker exec "$NODE" pg_dump \
    -U postgres -d "$DB" -p "$INTERNAL_PORT" -h localhost \
    -Fd -j "$JOBS" -f "$CONTAINER_DUMP_DIR"
echo -e "${GREEN}✓ pg_dump complete${NC}"

echo -e "${YELLOW}[2/3] Packaging into .tgz inside container...${NC}"
docker exec "$NODE" tar -czf "$CONTAINER_TGZ" -C /tmp "$DUMP_NAME"
echo -e "${GREEN}✓ Packaged${NC}"

echo -e "${YELLOW}[3/3] Copying to host...${NC}"
docker cp "$NODE:$CONTAINER_TGZ" "$HOST_TGZ"
echo -e "${GREEN}✓ Copied${NC}"

DURATION=$(($(date +%s) - START_TS))
SIZE=$(du -h "$HOST_TGZ" 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${BLUE}${BOLD}=== Backup Complete ===${NC}"
echo -e "  ${CYAN}File:${NC}     $HOST_TGZ"
echo -e "  ${CYAN}Size:${NC}     ${SIZE:-?}"
echo -e "  ${CYAN}Duration:${NC} ${DURATION}s"
echo -e "  ${CYAN}Source:${NC}   $NODE (replica)"
echo ""
echo -e "${CYAN}Restore example:${NC}"
echo -e "  tar -xzf '$HOST_TGZ' -C /tmp"
echo -e "  pg_restore -h localhost -p \${HAPROXY_WRITE_PORT:-5551} -U postgres \\"
echo -e "      -d <target_db> -j $JOBS '/tmp/${DUMP_NAME}'"
