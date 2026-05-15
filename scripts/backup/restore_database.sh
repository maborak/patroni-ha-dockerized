#!/bin/bash
# scripts/backup/restore_database.sh — Restore a single database from a .tgz produced
# by dump_database.sh, into the cluster leader.
#
# Restore always targets the LEADER (writes need to land on the primary).
# By default refuses to overwrite an existing database; pass --clean to drop+recreate
# (a y/N prompt is shown before the drop).
#
# Usage:
#   bash scripts/backup/restore_database.sh --archive backups/pazuzu_20260515_204914.tgz
#   bash scripts/backup/restore_database.sh --archive backups/x.tgz --target mydb_copy
#   bash scripts/backup/restore_database.sh --archive backups/x.tgz --clean
#   bash scripts/backup/restore_database.sh --interactive

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

ARCHIVE=""
TARGET=""
NODE=""
JOBS=4
CLEAN=false
NO_OWNER=false
NO_ACL=false
INTERACTIVE=false
ASSUME_YES=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--archive PATH] [--target NAME] [--node dbN] [--jobs N] [--clean] [--no-owner] [--no-acl] [--interactive] [--yes]

Restore a single database from a .tgz produced by dump_database.sh, into the leader.

Options:
  --archive PATH      Path to .tgz archive (required unless --interactive)
  --target NAME       Target database name (default: parse from archive filename)
  --node dbN          Force destination node (default: cluster leader)
  --jobs N            pg_restore parallel jobs (default: 4)
  --clean             Drop the target database first if it exists (prompts y/N)
  --no-owner          pg_restore --no-owner (skip ownership restoration)
  --no-acl            pg_restore --no-acl (skip GRANT/REVOKE restoration)
  --interactive       Pick archive from ./backups/ via numbered menu
  --yes               Skip the y/N confirmation before --clean (use with care)
  -h, --help          Show this help

Examples:
  $(basename "$0") --archive backups/pazuzu_20260515_204914.tgz
  $(basename "$0") --archive backups/pazuzu_20260515_204914.tgz --target pazuzu_copy
  $(basename "$0") --interactive --clean
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --archive) ARCHIVE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --node) NODE="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --clean) CLEAN=true; shift ;;
        --no-owner) NO_OWNER=true; shift ;;
        --no-acl) NO_ACL=true; shift ;;
        --interactive) INTERACTIVE=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    echo -e "${RED}✗ --jobs must be a positive integer (got: $JOBS)${NC}" >&2
    exit 1
fi

# --- Interactive archive picker -----------------------------------------------
if [ "$INTERACTIVE" = true ] || [ -z "$ARCHIVE" ]; then
    BACKUP_DIR="$PROJECT_ROOT/backups"
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}✗ No backups directory found at $BACKUP_DIR${NC}" >&2
        exit 1
    fi

    ARCHIVES=()
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        ARCHIVES+=("$f")
    done < <(ls -1t "$BACKUP_DIR"/*.tgz 2>/dev/null || true)

    if [ ${#ARCHIVES[@]} -eq 0 ]; then
        echo -e "${RED}✗ No .tgz archives found in $BACKUP_DIR${NC}" >&2
        exit 1
    fi

    echo "" >&2
    echo -e "${BLUE}${BOLD}Available archives (newest first):${NC}" >&2
    for idx in "${!ARCHIVES[@]}"; do
        f="${ARCHIVES[$idx]}"
        size=$(du -h "$f" | awk '{print $1}')
        printf "  ${CYAN}%2d)${NC} %s  (%s)\n" "$((idx + 1))" "$(basename "$f")" "$size" >&2
    done
    echo "" >&2

    echo -ne "${BOLD}Select archive [1-${#ARCHIVES[@]}]: ${NC}" >&2
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ARCHIVES[@]}" ]; then
        echo -e "${RED}✗ Invalid choice.${NC}" >&2
        exit 1
    fi
    ARCHIVE="${ARCHIVES[$((choice - 1))]}"
    echo -e "${GREEN}✓ Selected: $(basename "$ARCHIVE")${NC}" >&2
fi

# Resolve to absolute path
if [ ! -f "$ARCHIVE" ]; then
    echo -e "${RED}✗ Archive not found: $ARCHIVE${NC}" >&2
    exit 1
fi
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

# --- Determine target DB name -------------------------------------------------
if [ -z "$TARGET" ]; then
    BASE=$(basename "$ARCHIVE" .tgz)
    # Strip trailing _YYYYmmdd_HHMMSS if present
    TARGET=$(echo "$BASE" | sed -E 's/_[0-9]{8}_[0-9]{6}$//')
    if [ -z "$TARGET" ] || [ "$TARGET" = "$BASE" ] && ! [[ "$BASE" =~ _[0-9]{8}_[0-9]{6}$ ]]; then
        echo -e "${YELLOW}⚠ Could not parse DB name from filename; using full basename: $BASE${NC}" >&2
        TARGET="$BASE"
    fi
fi

# --- Pick destination node (leader) -------------------------------------------
if [ -z "$NODE" ]; then
    echo -e "${YELLOW}Detecting cluster leader...${NC}" >&2
    NODE=$(detect_leader_api 2>/dev/null || detect_leader)
    if [ -z "$NODE" ]; then
        echo -e "${RED}✗ Could not detect leader. Specify --node.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Leader: ${NODE}${NC}" >&2
else
    validate_node "$NODE" || exit 1
    LEADER=$(detect_leader_api 2>/dev/null || echo "")
    if [ -n "$LEADER" ] && [ "$NODE" != "$LEADER" ]; then
        echo -e "${YELLOW}⚠ Warning: $NODE is not the current leader ($LEADER). Restore will fail if $NODE is read-only.${NC}" >&2
    fi
fi

INTERNAL_PORT=$(get_internal_pg_port)

# --- Quote helper for psql identifiers ----------------------------------------
quote_ident() {
    local s="${1//\"/\"\"}"
    echo "\"$s\""
}
quote_literal() {
    local s="${1//\'/\'\'}"
    echo "'$s'"
}

TARGET_QUOTED_IDENT=$(quote_ident "$TARGET")
TARGET_QUOTED_LIT=$(quote_literal "$TARGET")

# --- Check if target DB exists ------------------------------------------------
EXISTS=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
    "SELECT 1 FROM pg_database WHERE datname = ${TARGET_QUOTED_LIT};" 2>/dev/null | tr -d ' ')

# --- Show plan ----------------------------------------------------------------
ARCHIVE_SIZE=$(du -h "$ARCHIVE" | awk '{print $1}')
echo ""
echo -e "${BLUE}${BOLD}=== Restore Plan ===${NC}"
echo -e "  ${CYAN}Archive:${NC}      $ARCHIVE  (${ARCHIVE_SIZE})"
echo -e "  ${CYAN}Target DB:${NC}    $TARGET"
echo -e "  ${CYAN}Target node:${NC}  $NODE (leader)"
echo -e "  ${CYAN}Jobs:${NC}         $JOBS"
EXTRA_FLAGS=""
[ "$NO_OWNER" = true ] && EXTRA_FLAGS="$EXTRA_FLAGS --no-owner"
[ "$NO_ACL" = true ] && EXTRA_FLAGS="$EXTRA_FLAGS --no-acl"
echo -e "  ${CYAN}pg_restore opts:${NC}${EXTRA_FLAGS:- (default)}"
if [ "$EXISTS" = "1" ]; then
    if [ "$CLEAN" = true ]; then
        echo -e "  ${CYAN}Mode:${NC}         ${YELLOW}${BOLD}DROP + RECREATE${NC} (target already exists)"
    else
        echo ""
        echo -e "${RED}✗ Target database '$TARGET' already exists on $NODE.${NC}" >&2
        echo -e "${YELLOW}  Pass --clean to drop and recreate it, or --target NAME to restore into a different DB.${NC}" >&2
        exit 1
    fi
else
    echo -e "  ${CYAN}Mode:${NC}         CREATE new database"
fi
echo ""

# --- Confirm destructive action ----------------------------------------------
if [ "$EXISTS" = "1" ] && [ "$CLEAN" = true ] && [ "$ASSUME_YES" = false ]; then
    echo -ne "${RED}${BOLD}This will DROP database '$TARGET' on $NODE. Continue? [y/N]: ${NC}"
    read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) echo -e "${YELLOW}Aborted.${NC}"; exit 1 ;;
    esac
fi

# --- Prepare paths inside container -------------------------------------------
ARCHIVE_BASE=$(basename "$ARCHIVE")
DUMP_DIR_NAME="${ARCHIVE_BASE%.tgz}"
CONTAINER_TGZ="/tmp/$ARCHIVE_BASE"
CONTAINER_DUMP_DIR="/tmp/$DUMP_DIR_NAME"

cleanup() {
    docker exec "$NODE" rm -rf "$CONTAINER_TGZ" "$CONTAINER_DUMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

START_TS=$(date +%s)

echo -e "${YELLOW}[1/5] Copying archive into ${NODE}...${NC}"
docker cp "$ARCHIVE" "$NODE:$CONTAINER_TGZ"
echo -e "${GREEN}✓ Copied${NC}"

echo -e "${YELLOW}[2/5] Extracting archive in ${NODE}...${NC}"
docker exec "$NODE" tar -xzf "$CONTAINER_TGZ" -C /tmp
if ! docker exec "$NODE" test -f "$CONTAINER_DUMP_DIR/toc.dat"; then
    echo -e "${RED}✗ Extracted directory does not look like a pg_dump archive (no toc.dat at $CONTAINER_DUMP_DIR).${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Extracted${NC}"

if [ "$EXISTS" = "1" ] && [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}[3/5] Dropping existing database '$TARGET'...${NC}"
    docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -v ON_ERROR_STOP=1 -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ${TARGET_QUOTED_LIT} AND pid <> pg_backend_pid();" >/dev/null
    docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -v ON_ERROR_STOP=1 -c \
        "DROP DATABASE ${TARGET_QUOTED_IDENT};"
    echo -e "${GREEN}✓ Dropped${NC}"
    EXISTS=0
fi

if [ "$EXISTS" != "1" ]; then
    echo -e "${YELLOW}[4/5] Creating empty database '$TARGET'...${NC}"
    docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -v ON_ERROR_STOP=1 -c \
        "CREATE DATABASE ${TARGET_QUOTED_IDENT};"
    echo -e "${GREEN}✓ Created${NC}"
fi

echo -e "${YELLOW}[5/5] Running pg_restore (-j $JOBS)...${NC}"
set +e
docker exec "$NODE" pg_restore \
    -U postgres -d "$TARGET" -p "$INTERNAL_PORT" -h localhost \
    -Fd -j "$JOBS" $EXTRA_FLAGS \
    "$CONTAINER_DUMP_DIR"
RESTORE_EXIT=$?
set -e

DURATION=$(($(date +%s) - START_TS))

# pg_restore exit codes:
#   0 — success
#   1 — completed with warnings (some objects could not be restored; common when not using --no-owner)
#   >1 — fatal error
if [ "$RESTORE_EXIT" -gt 1 ]; then
    echo ""
    echo -e "${RED}✗ pg_restore failed (exit $RESTORE_EXIT)${NC}" >&2
    exit "$RESTORE_EXIT"
elif [ "$RESTORE_EXIT" -eq 1 ]; then
    echo -e "${YELLOW}⚠ pg_restore finished with warnings (exit 1). Common with role/ownership mismatches; data should be intact.${NC}"
else
    echo -e "${GREEN}✓ pg_restore complete${NC}"
fi

# Post-restore stats
TABLE_COUNT=$(docker exec "$NODE" psql -U postgres -d "$TARGET" -p "$INTERNAL_PORT" -h localhost -t -A -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE';" 2>/dev/null | tr -d ' ')
DB_SIZE=$(docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c \
    "SELECT pg_size_pretty(pg_database_size(${TARGET_QUOTED_LIT}));" 2>/dev/null | tr -d ' ')

echo ""
echo -e "${BLUE}${BOLD}=== Restore Complete ===${NC}"
echo -e "  ${CYAN}Target DB:${NC} $TARGET"
echo -e "  ${CYAN}Node:${NC}      $NODE"
echo -e "  ${CYAN}Tables:${NC}    ${TABLE_COUNT:-?}"
echo -e "  ${CYAN}DB size:${NC}   ${DB_SIZE:-?}"
echo -e "  ${CYAN}Duration:${NC}  ${DURATION}s"
echo ""
echo -e "${CYAN}Connect:${NC}"
echo -e "  make psql DATABASE=$TARGET"
