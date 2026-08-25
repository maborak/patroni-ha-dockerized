#!/bin/bash
# scripts/backup/dump_database.sh — Logical backup (pg_dump) of a single database.
#
# Sources:
#   • this Patroni cluster — always dumped from a healthy replica (never the
#     leader) unless a specific node is forced via --node;
#   • any remote PostgreSQL reachable from this host, given a libpq URI
#     (--from postgresql://user:pass@host:port/db).
#
# Destinations:
#   • folder   → <dir>/<db>_<ts>.tgz
#   • file     → exact .tgz path
#
# Usage:
#   bash scripts/backup/dump_database.sh --db maborak
#   bash scripts/backup/dump_database.sh --interactive
#   bash scripts/backup/dump_database.sh --from postgresql://u:p@host:5432/app \
#        --target /srv/dumps
#   bash scripts/backup/dump_database.sh --db mydb --jobs 8

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DB=""
NODE=""
FROM_URI=""              # postgresql:// remote source (overrides local cluster)
OUTPUT_DIR="$PROJECT_ROOT/backups"
TARGET_SPEC=""           # folder | /path/file.tgz
JOBS=4
INTERACTIVE=false
ASSUME_YES=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--db NAME | --from URI] [--node dbN] [--target DIR|FILE]
                       [--output DIR] [--jobs N] [--interactive] [--yes]

Logical backup (.tgz) of a single database.

Sources:
  --db NAME           Database on THIS cluster (dumped from a healthy replica)
  --from URI          Remote libpq source, e.g. postgresql://u:p@host:5432/db
                      (dumped via an ephemeral postgres client container)

Destinations (--target):
  DIR                 <DIR>/<db>_<timestamp>.tgz          (default: ./backups)
  /path/file.tgz      exact output file

Options:
  --node dbN          Force specific source node (local cluster only)
  --jobs N            pg_dump parallel jobs (default: 4)
  --interactive       Guided prompts (source, database, destination)
  --yes               Skip confirmations
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --db) DB="$2"; shift 2 ;;
        --from|--dsn) FROM_URI="$2"; shift 2 ;;
        --node) NODE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --target) TARGET_SPEC="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --interactive) INTERACTIVE=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$FROM_URI" ] && [ -n "$DB" ] && die "--db and --from are mutually exclusive"
case "${FROM_URI:-}" in
    postgresql://*|postgres://*) ;;
    "") ;;
    *) die "--from must be a postgresql:// URI" ;;
esac

# ── Destination classification ──────────────────────────────────────────
TARGET_TYPE="folder"
classify() {
    case "$1" in *.tgz|*.tar.gz) TARGET_TYPE="file" ;; *) TARGET_TYPE="folder" ;; esac
}
[ -n "$TARGET_SPEC" ] && classify "$TARGET_SPEC"

# ── Resolve SOURCE ───────────────────────────────────────────────────────
if [ "$INTERACTIVE" = true ] && [ -z "$FROM_URI" ]; then
    echo "" >&2
    echo -e "${BLUE}${BOLD}Source${NC}" >&2
    echo -e "  ${CYAN}1)${NC} This cluster (healthy replica)" >&2
    echo -e "  ${CYAN}2)${NC} Remote PostgreSQL URL" >&2
    echo -ne "${BOLD}Source [1]: ${NC}" >&2
    read -r schoice; schoice=${schoice:-1}
    if [ "$schoice" = "2" ]; then
        read -rp "URL (postgresql://user:pass@host:port/db): " FROM_URI >&2
        [ -n "$FROM_URI" ] || { echo -e "${RED}✗ URL required${NC}" >&2; exit 1; }
    fi
fi

if [ -z "$FROM_URI" ]; then
    # ---- LOCAL CLUSTER SOURCE -------------------------------------------
    if [ "$INTERACTIVE" = true ] || [ -z "$DB" ]; then
        INTERNAL_PORT=5431
        if [ -z "$NODE" ]; then
            NODE=$(timeout 10 podman exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
                | awk '$4=="Replica" && $6=="streaming"{print $2}' | head -1)
            NODE=${NODE:-$(timeout 10 podman exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
                | awk '$4=="Leader"{print $2}' | head -1)}
        fi
        [ -n "$NODE" ] || { echo -e "${RED}✗ no healthy node found${NC}" >&2; exit 1; }

        DBS_RAW=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
            "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1;" 2>/dev/null)
        [ -n "$DBS_RAW" ] || { echo -e "${RED}✗ cannot list databases on $NODE${NC}" >&2; exit 1; }

        DB_ARRAY=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && DB_ARRAY+=("$line")
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

    EXISTS=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
        "SELECT 1 FROM pg_database WHERE datname = '${DB//\'/\'\'}';" 2>/dev/null | tr -d ' ')
    [ "$EXISTS" = "1" ] || { echo -e "${RED}✗ Database '$DB' not found on ${NODE}.${NC}" >&2; exit 1; }
    SOURCE_DESC="cluster replica/node: $NODE"
else
    # ---- REMOTE URI SOURCE ----------------------------------------------
    DB=$(python3 - "$FROM_URI" << 'PY'
import sys, urllib.parse as up
u = up.urlparse(sys.argv[1])
print(up.unquote(u.path.lstrip('/')) or 'postgres')
PY
)
    SOURCE_DESC="remote: $(echo "$FROM_URI" | sed -E 's#//[^@]*@#//***:@#')"
fi

# ── Prepare paths ────────────────────────────────────────────────────────
case "$TARGET_TYPE" in
    file)   OUTPUT_DIR="$(dirname "$TARGET_SPEC")" ;;
    folder) OUTPUT_DIR="$TARGET_SPEC" ;;
esac
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_NAME="${DB}_${TIMESTAMP}"
FINAL_PATH="$OUTPUT_DIR/${DUMP_NAME}.tgz"

# ── Pre-flight info ──────────────────────────────────────────────────────
if [ -z "$FROM_URI" ]; then
    DB_SIZE=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
        "SELECT pg_size_pretty(pg_database_size('${DB//\'/\'\'}'));" 2>/dev/null | tr -d ' ')
fi

echo ""
echo -e "${BLUE}${BOLD}=== Dump Plan ===${NC}"
echo -e "  ${CYAN}Database:${NC}    $DB  (${DB_SIZE:-size unknown pre-connect})"
if [ -n "$FROM_URI" ]; then
    echo -e "  ${CYAN}Source:${NC}       $SOURCE_DESC"
else
    echo -e "  ${CYAN}Source node:${NC} $NODE"
fi
echo -e "  ${CYAN}Jobs:${NC}        $JOBS  (pg_dump -Fd parallel)"
echo -e "  ${CYAN}Destination:${NC} $FINAL_PATH"
echo ""

if [ "$ASSUME_YES" = false ]; then
    echo -ne "${BOLD}Action — [${GREEN}s${NC}${BOLD}]tart  [${RED}c${NC}${BOLD}]ancel: ${NC}"
    read -r confirm
    case "$confirm" in
        s|S|start|START|y|Y|yes|YES) echo -e "${GREEN}✓ Starting...${NC}" ;;
        *) echo -e "${YELLOW}Cancelled.${NC}"; exit 1 ;;
    esac
fi

START_TS=$(date +%s)

if [ -n "$FROM_URI" ]; then
    # ── REMOTE: ephemeral client container writes the directory dump ──
    echo -e "${YELLOW}[1/3] pg_dump via ephemeral client container...${NC}"
    OUTDIR_ABS=$(cd "$OUTPUT_DIR" && pwd)
    DUMP_SUB="$DUMP_NAME.dir"
    rm -rf "$OUTDIR_ABS/$DUMP_SUB"
    mkdir -p "$OUTDIR_ABS/$DUMP_SUB"
    timeout 3600 podman run --rm --network=host \
        -v "$OUTDIR_ABS:/out" \
        docker.io/library/postgres:${POSTGRES_VERSION:-18}-alpine \
        pg_dump --dbname="$FROM_URI" -Fd -j "$JOBS" -f "/out/$DUMP_SUB"
    ok_dir="$OUTDIR_ABS/$DUMP_SUB"
else
    # ── LOCAL CLUSTER: dump inside the node container ──
    CONTAINER_DUMP_DIR="/tmp/${DUMP_NAME}.dir"
    CONTAINER_TGZ="/tmp/${DUMP_NAME}.tgz"
    echo -e "${YELLOW}[1/3] Running pg_dump on $NODE (-Fd -j ${JOBS})...${NC}"
    docker exec "$NODE" pg_dump \
        -U postgres -d "$DB" -p "$INTERNAL_PORT" -h localhost \
        -Fd -j "$JOBS" -f "$CONTAINER_DUMP_DIR"
    echo -e "${GREEN}✓ pg_dump complete${NC}"
    echo -e "${YELLOW}[2/3] Packaging inside container...${NC}"
    docker exec "$NODE" tar -czf "$CONTAINER_TGZ" -C /tmp "${DUMP_NAME}.dir"
    docker exec "$NODE" mv "/tmp/${DUMP_NAME}.dir" "/tmp/${DUMP_NAME}" 2>/dev/null || true
    CONTAINER_DUMP_DIR="/tmp/${DUMP_NAME}"
    echo -e "${GREEN}✓ Packaged${NC}"
fi

# ── Package (host side) ──────────────────────────────────────────────────
if [ -n "$FROM_URI" ]; then
    echo -e "${YELLOW}[2/3] Packaging directory dump...${NC}"
    tar -czf "$FINAL_PATH" -C "$OUTDIR_ABS" "$DUMP_SUB"
    rm -rf "$ok_dir"
    echo -e "${GREEN}✓ Packaged${NC}"
else
    echo -e "${YELLOW}[3/3] Copying to host...${NC}"
    docker cp "$NODE:$CONTAINER_TGZ" "$FINAL_PATH"
    docker exec "$NODE" rm -rf "$CONTAINER_TGZ" "$CONTAINER_DUMP_DIR" 2>/dev/null || true
    echo -e "${GREEN}✓ Copied${NC}"
fi

DURATION=$(( $(date +%s) - START_TS ))
SIZE=$(du -h "$FINAL_PATH" 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${BLUE}${BOLD}=== Backup Complete ===${NC}"
echo -e "  ${CYAN}File:${NC}     $FINAL_PATH"
echo -e "  ${CYAN}Size:${NC}     ${SIZE:-?}"
echo -e "  ${CYAN}Duration:${NC} ${DURATION}s"
if [ -z "$FROM_URI" ]; then
    echo -e "  ${CYAN}Restore:${NC}"
    echo -e "    make restore-db ARCHIVE='$FINAL_PATH'"
fi
