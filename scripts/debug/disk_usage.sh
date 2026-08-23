#!/bin/bash

# Script to summarize disk usage across all docker-compose services
# Shows container filesystem, volumes, images, and per-node PostgreSQL data breakdown.
#
# Usage: bash scripts/debug/disk_usage.sh [--json]
#        bash scripts/debug/disk_usage.sh --cleanup-<category> [--keep-days=N]
#
# Cleanup categories:
#   --cleanup, --cleanup-logs   PostgreSQL rotated logs + truncate active log
#   --cleanup-dumps             Remove .tgz dumps in backups/ and mybk/ older than KEEP_DAYS
#   --cleanup-docker            docker image prune + docker builder prune
#   --cleanup-snapshots         Remove scripts/db_stats_before_pitr_*.json older than KEEP_DAYS
#   --cleanup-temp              Remove stale pgsql_tmp/ files (>60min old) on running db nodes
#   --cleanup-all               Run every cleanup category
#
# Retention:
#   --keep-days=N               Days to keep for dumps/snapshots (default 7)

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUTPUT_FORMAT="human"
DO_CLEANUP_LOGS=false
DO_CLEANUP_DUMPS=false
DO_CLEANUP_DOCKER=false
DO_CLEANUP_SNAPSHOTS=false
DO_CLEANUP_TEMP=false
DO_CLEANUP_BARMAN=false
DO_DRY_RUN=false
KEEP_DAYS=7

usage() {
    cat <<EOF
Usage: $(basename "$0") [REPORT_OPTIONS | CLEANUP_OPTIONS]

Summarize disk usage across the Patroni HA stack and clean up reclaimable space.

REPORT (default — no flags):
  Shows container writable layers, named volume sizes, per-node PostgreSQL
  data-directory breakdown (base/, pg_wal/, pg_log/, pgsql_tmp, other), and
  Docker image sizes.

  --json                  Emit machine-readable JSON (includes pgdata section)

CLEANUP (mutually exclusive with --json; multiple categories may be combined):
  --cleanup, --cleanup-logs
                          Remove rotated PostgreSQL logs and truncate the
                          active log on each running db node.
                          (PG keeps the fd open, so truncate is safe.)

  --cleanup-dumps         Remove .tgz files in backups/ and mybk/ older than
                          KEEP_DAYS (default 7). Output of dump_database.sh.

  --cleanup-docker        docker image prune -f + docker builder prune -f.
                          Removes only dangling images and build cache.

  --cleanup-snapshots     Remove scripts/db_stats_before_pitr_*.json older
                          than KEEP_DAYS (default 7). PITR test artifacts.

  --cleanup-temp          Remove stale files in pgsql_tmp/ directories on
                          each running db node. Only files older than 60
                          minutes are removed (avoids racing active sorts).

  --cleanup-backup        Delete all active Backup backups. Shows current
                          backups and requests interactive confirmation
                          before executing.

  --cleanup-all           Run every cleanup category above (excludes Backup).

RETENTION:
  --keep-days=N           Days to keep for --cleanup-dumps and
                          --cleanup-snapshots. Files older than N days
                          (mtime) are removed. Default: ${KEEP_DAYS}.

  --dry-run, --dryrun     Show what would be cleaned up without actually
                          deleting anything (supported by --cleanup-dumps).

  -h, --help              Show this help.

NOT TOUCHED (unless explicitly requested via --cleanup-backup):
  - WAL files in pg_wal/        — owned by PostgreSQL / Backup archiving
  - Backup backups & WAL archive — managed by Backup retention_policy (or deleted via --cleanup-backup)
  - Named volumes (dbN_data, backup_repo, etcd*_data)

EXAMPLES:
  $(basename "$0")                              # report only
  $(basename "$0") --json | jq '.pgdata.db1'    # JSON, drill into db1
  $(basename "$0") --cleanup                    # logs only (backwards compat)
  $(basename "$0") --cleanup-dumps --keep-days=14
  $(basename "$0") --cleanup-all --keep-days=30
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)            usage; exit 0 ;;
        --json)               OUTPUT_FORMAT="json" ;;
        --dry-run|--dryrun)   DO_DRY_RUN=true ;;
        --cleanup|--cleanup-logs) DO_CLEANUP_LOGS=true ;;
        --cleanup-dumps)      DO_CLEANUP_DUMPS=true ;;
        --cleanup-docker)     DO_CLEANUP_DOCKER=true ;;
        --cleanup-snapshots)  DO_CLEANUP_SNAPSHOTS=true ;;
        --cleanup-temp)       DO_CLEANUP_TEMP=true ;;
        --cleanup-backup)     DO_CLEANUP_BARMAN=true ;;
        --cleanup-all)
            DO_CLEANUP_LOGS=true
            DO_CLEANUP_DUMPS=true
            DO_CLEANUP_DOCKER=true
            DO_CLEANUP_SNAPSHOTS=true
            DO_CLEANUP_TEMP=true
            ;;
        --keep-days=*)        KEEP_DAYS="${arg#--keep-days=}" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

ANY_CLEANUP=false
if [ "$DO_CLEANUP_LOGS" = true ] || [ "$DO_CLEANUP_DUMPS" = true ] || \
   [ "$DO_CLEANUP_DOCKER" = true ] || [ "$DO_CLEANUP_SNAPSHOTS" = true ] || \
   [ "$DO_CLEANUP_TEMP" = true ] || [ "$DO_CLEANUP_BARMAN" = true ]; then
    ANY_CLEANUP=true
fi

# DB nodes that have PostgreSQL logs
DB_NODES=($(get_db_nodes))
PG_LOG_DIR="/var/log/postgresql"

# Services from docker-compose
SERVICES=(etcd1 etcd2 etcd3 $(get_db_nodes) backup haproxy pgbouncer pgbouncer-ro)

# Named volumes from docker-compose
VOLUMES=(etcd1_data etcd2_data etcd3_data)
for db in $(get_db_nodes); do VOLUMES+=("${db}_data"); done
VOLUMES+=(backup_data backup_repo)

# Get the docker-compose project name prefix
# Docker Compose uses the directory name lowercased as the volume prefix
get_project_prefix() {
    local dir_name
    dir_name=$(basename "$PROJECT_DIR")
    echo "${dir_name}" | tr '[:upper:]' '[:lower:]'
}

PROJECT_PREFIX=$(get_project_prefix)

# Temp files for caches (bash 3.2 lacks associative arrays)
CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$CACHE_DIR"' EXIT

# Parse a human-readable Docker size string (e.g., "10.9GB", "111kB") to bytes
parse_docker_size() {
    local size_str="$1"
    local num unit
    num=$(echo "$size_str" | sed 's/[^0-9.]//g')
    unit=$(echo "$size_str" | sed 's/[0-9.]//g')
    case "$unit" in
        B)   printf "%.0f" "$num" 2>/dev/null || echo "0" ;;
        kB)  printf "%.0f" "$(echo "$num * 1000" | bc)" 2>/dev/null || echo "0" ;;
        KB)  printf "%.0f" "$(echo "$num * 1024" | bc)" 2>/dev/null || echo "0" ;;
        MB)  printf "%.0f" "$(echo "$num * 1000000" | bc)" 2>/dev/null || echo "0" ;;
        GB)  printf "%.0f" "$(echo "$num * 1000000000" | bc)" 2>/dev/null || echo "0" ;;
        TB)  printf "%.0f" "$(echo "$num * 1000000000000" | bc)" 2>/dev/null || echo "0" ;;
        *)   echo "0" ;;
    esac
}

# Format bytes to human-readable
format_size() {
    local size=$1
    if [ "$size" -ge 1073741824 ]; then
        printf "%.2f GB" "$(echo "scale=2; $size / 1073741824" | bc)"
    elif [ "$size" -ge 1048576 ]; then
        printf "%.1f MB" "$(echo "scale=1; $size / 1048576" | bc)"
    elif [ "$size" -ge 1024 ]; then
        printf "%.1f KB" "$(echo "scale=1; $size / 1024" | bc)"
    else
        printf "%d B" "$size"
    fi
}

# Build caches from docker ps -s and docker system df -v
build_caches() {
    # Cache container writable layer sizes
    mkdir -p "$CACHE_DIR/containers"
    local line name size_str
    while IFS=$'\t' read -r name size_str; do
        if [ -n "$name" ]; then
            local writable_size
            writable_size=$(echo "$size_str" | sed 's/ .*//')
            parse_docker_size "$writable_size" > "$CACHE_DIR/containers/$name"
        fi
    done < <(docker ps -as --format '{{.Names}}\t{{.Size}}' 2>/dev/null || true)

    # Cache volume sizes from docker system df -v
    mkdir -p "$CACHE_DIR/volumes"
    local in_volumes=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "^VOLUME NAME"; then
            in_volumes=true
            continue
        fi
        # Stop at next section (Build cache or empty)
        if $in_volumes; then
            if echo "$line" | grep -qE "^(Build|Images|Containers|REPOSITORY|CONTAINER)" ; then
                in_volumes=false
                continue
            fi
            if [ -z "$line" ]; then
                continue
            fi
            local vol_name vol_size
            vol_name=$(echo "$line" | awk '{print $1}')
            vol_size=$(echo "$line" | awk '{print $NF}')
            if [ -n "$vol_name" ] && [ -n "$vol_size" ]; then
                parse_docker_size "$vol_size" > "$CACHE_DIR/volumes/$vol_name"
            fi
        fi
    done < <(docker system df -v 2>/dev/null || true)
}

build_caches

# Get container disk usage (read/write layer) from cache
get_container_size() {
    local container=$1
    if [ -f "$CACHE_DIR/containers/$container" ]; then
        cat "$CACHE_DIR/containers/$container"
    else
        echo "0"
    fi
}

# Get volume disk usage from cache
get_volume_size() {
    local volume=$1
    local full_name
    for prefix in "${PROJECT_PREFIX}_" "patroni-ha-dockerized_" ""; do
        full_name="${prefix}${volume}"
        if [ -f "$CACHE_DIR/volumes/$full_name" ]; then
            cat "$CACHE_DIR/volumes/$full_name"
            return
        fi
    done
    echo "0"
}

# Get image size for a container
get_image_size() {
    local container=$1
    local image_id
    image_id=$(docker inspect --format='{{.Image}}' "$container" 2>/dev/null) || { echo "0"; return; }
    docker image inspect --format='{{.Size}}' "$image_id" 2>/dev/null || echo "0"
}

# Get image name for a container (empty string if container not found)
get_image_name() {
    local container=$1
    docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || true
}

# Check if a value is in a list (replacement for associative array set membership)
# Usage: list_contains "$list" "$item"
list_contains() {
    local list="$1" item="$2"
    echo "$list" | grep -qF "|${item}|" 2>/dev/null
}

# ============================================================================
# PostgreSQL data-directory breakdown (per node)
# Returns size in bytes for: base/, pg_wal/, pg_log/, pgsql_tmp, and "other"
# pgsql_tmp lives inside base/<dboid>/ so it is reported separately AND
# subtracted from base/ to make the columns sum to the data-dir total.
# ============================================================================

get_pgdata_subdir_size() {
    local node="$1" path="$2"
    docker exec "$node" sh -c "du -sb '$path' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "0"
}

get_pgdata_tmp_size() {
    local node="$1" data_dir="$2"
    docker exec "$node" sh -c \
        "find '$data_dir' -type d -name pgsql_tmp 2>/dev/null \
         | while read -r d; do du -sb \"\$d\" 2>/dev/null; done \
         | awk '{s+=\$1} END {print s+0}'" 2>/dev/null || echo "0"
}

# Populate cache of pgdata breakdown so we compute du once per node
build_pgdata_cache() {
    mkdir -p "$CACHE_DIR/pgdata"
    local data_dir
    data_dir=$(get_patroni_data_dir)

    for node in "${DB_NODES[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$node" 2>/dev/null || echo "not_found")
        if [ "$status" != "running" ]; then
            printf "%s|%s|%s|%s|%s|%s|%s\n" "$status" 0 0 0 0 0 0 > "$CACHE_DIR/pgdata/$node"
            continue
        fi

        local total base wal log tmp other base_excl_tmp
        total=$(get_pgdata_subdir_size "$node" "$data_dir")
        base=$(get_pgdata_subdir_size "$node" "$data_dir/base")
        wal=$(get_pgdata_subdir_size "$node" "$data_dir/pg_wal")
        log=$(get_pgdata_subdir_size "$node" "$data_dir/pg_log")
        tmp=$(get_pgdata_tmp_size "$node" "$data_dir")
        total=${total:-0}; base=${base:-0}; wal=${wal:-0}; log=${log:-0}; tmp=${tmp:-0}
        base_excl_tmp=$((base - tmp))
        [ "$base_excl_tmp" -lt 0 ] && base_excl_tmp=0
        other=$((total - base - wal - log))
        [ "$other" -lt 0 ] && other=0

        # status | base_excl_tmp | pg_wal | pg_log | pgsql_tmp | other | total
        printf "%s|%s|%s|%s|%s|%s|%s\n" \
            "$status" "$base_excl_tmp" "$wal" "$log" "$tmp" "$other" "$total" \
            > "$CACHE_DIR/pgdata/$node"
    done
}

# ============================================================================
# Human-readable output
# ============================================================================

print_human() {
    local total_container=0
    local total_volume=0
    local total_image=0

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           Patroni HA Stack — Disk Usage Summary             ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # --- Container writable layers ---
    echo -e "${BOLD}${BLUE}▶ Container Writable Layers${NC}"
    printf "  ${CYAN}%-20s %15s   %s${NC}\n" "CONTAINER" "SIZE" "STATUS"
    echo "  ──────────────────── ─────────────── ──────────"
    for svc in "${SERVICES[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
        if [ "$status" = "running" ] || [ "$status" = "exited" ] || [ "$status" = "created" ]; then
            local size_bytes
            size_bytes=$(get_container_size "$svc")
            size_bytes=${size_bytes:-0}
            total_container=$((total_container + size_bytes))
            local size_human
            size_human=$(format_size "$size_bytes")
            if [ "$status" = "running" ]; then
                printf "  ${GREEN}%-20s${NC} %15s   ${GREEN}%s${NC}\n" "$svc" "$size_human" "$status"
            else
                printf "  ${YELLOW}%-20s${NC} %15s   ${YELLOW}%s${NC}\n" "$svc" "$size_human" "$status"
            fi
        else
            printf "  ${RED}%-20s${NC} %15s   ${RED}%s${NC}\n" "$svc" "-" "$status"
        fi
    done
    echo ""

    # --- Named volumes ---
    echo -e "${BOLD}${BLUE}▶ Named Volumes${NC}"
    printf "  ${CYAN}%-35s %15s${NC}\n" "VOLUME" "SIZE"
    echo "  ─────────────────────────────────── ───────────────"
    for vol in "${VOLUMES[@]}"; do
        local size_bytes
        size_bytes=$(get_volume_size "$vol")
        size_bytes=${size_bytes:-0}
        total_volume=$((total_volume + size_bytes))
        local size_human
        size_human=$(format_size "$size_bytes")
        printf "  %-35s %15s\n" "$vol" "$size_human"
    done
    echo ""

    # --- PostgreSQL data breakdown (per node) ---
    echo -e "${BOLD}${BLUE}▶ PostgreSQL Data Breakdown ${NC}(inside pg_data; pgsql_tmp is excluded from base/)"
    printf "  ${CYAN}%-8s %12s %12s %12s %12s %12s %12s${NC}\n" \
        "NODE" "base/" "pg_wal/" "pg_log/" "pgsql_tmp" "other" "TOTAL"
    echo "  ──────── ──────────── ──────────── ──────────── ──────────── ──────────── ────────────"
    for node in "${DB_NODES[@]}"; do
        if [ ! -f "$CACHE_DIR/pgdata/$node" ]; then
            printf "  ${RED}%-8s${NC} ${RED}(no data)${NC}\n" "$node"
            continue
        fi
        local row status base_excl_tmp wal log tmp other total
        row=$(cat "$CACHE_DIR/pgdata/$node")
        IFS='|' read -r status base_excl_tmp wal log tmp other total <<< "$row"
        if [ "$status" != "running" ]; then
            printf "  ${RED}%-8s${NC} ${RED}(%s)${NC}\n" "$node" "$status"
            continue
        fi
        printf "  ${GREEN}%-8s${NC} %12s %12s %12s %12s %12s %12s\n" \
            "$node" \
            "$(format_size "$base_excl_tmp")" \
            "$(format_size "$wal")" \
            "$(format_size "$log")" \
            "$(format_size "$tmp")" \
            "$(format_size "$other")" \
            "$(format_size "$total")"
    done
    echo ""

    # --- Docker images ---
    echo -e "${BOLD}${BLUE}▶ Docker Images${NC}"
    printf "  ${CYAN}%-35s %15s${NC}\n" "IMAGE" "SIZE"
    echo "  ─────────────────────────────────── ───────────────"
    local seen_images=""
    for svc in "${SERVICES[@]}"; do
        local image_name
        image_name=$(get_image_name "$svc")
        if [ -z "$image_name" ]; then
            continue
        fi
        if ! list_contains "$seen_images" "$image_name"; then
            seen_images="${seen_images}|${image_name}|"
            local size_bytes
            size_bytes=$(get_image_size "$svc")
            size_bytes=${size_bytes:-0}
            total_image=$((total_image + size_bytes))
            local size_human
            size_human=$(format_size "$size_bytes")
            printf "  %-35s %15s\n" "$image_name" "$size_human"
        fi
    done
    echo ""

    # --- Totals ---
    echo -e "${BOLD}${CYAN}──────────────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-35s %15s${NC}\n" "Container writable layers:" "$(format_size $total_container)"
    printf "  ${BOLD}%-35s %15s${NC}\n" "Named volumes:" "$(format_size $total_volume)"
    printf "  ${BOLD}%-35s %15s${NC}\n" "Docker images:" "$(format_size $total_image)"
    echo -e "${BOLD}${CYAN}──────────────────────────────────────────────────────────────${NC}"
    local grand_total=$((total_container + total_volume + total_image))
    printf "  ${BOLD}${GREEN}%-35s %15s${NC}\n" "TOTAL:" "$(format_size $grand_total)"
    echo ""
}

# ============================================================================
# JSON output
# ============================================================================

print_json() {
    local json='{"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","containers":{'
    local first=true

    for svc in "${SERVICES[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not_found")
        local size_bytes=0
        if [ "$status" != "not_found" ]; then
            size_bytes=$(get_container_size "$svc")
            size_bytes=${size_bytes:-0}
        fi
        if [ "$first" = true ]; then first=false; else json+=","; fi
        json+='"'"$svc"'":{"size_bytes":'"$size_bytes"',"status":"'"$status"'"}'
    done

    json+='},"volumes":{'
    first=true
    for vol in "${VOLUMES[@]}"; do
        local size_bytes
        size_bytes=$(get_volume_size "$vol")
        size_bytes=${size_bytes:-0}
        if [ "$first" = true ]; then first=false; else json+=","; fi
        json+='"'"$vol"'":{"size_bytes":'"$size_bytes"'}'
    done

    json+='},"images":{'
    first=true
    local seen_images_json=""
    for svc in "${SERVICES[@]}"; do
        local image_name
        image_name=$(get_image_name "$svc")
        if [ -z "$image_name" ]; then
            continue
        fi
        if ! list_contains "$seen_images_json" "$image_name"; then
            seen_images_json="${seen_images_json}|${image_name}|"
            local size_bytes
            size_bytes=$(get_image_size "$svc")
            size_bytes=${size_bytes:-0}
            if [ "$first" = true ]; then first=false; else json+=","; fi
            json+='"'"$image_name"'":{"size_bytes":'"$size_bytes"'}'
        fi
    done

    json+='},"pgdata":{'
    first=true
    for node in "${DB_NODES[@]}"; do
        if [ ! -f "$CACHE_DIR/pgdata/$node" ]; then
            continue
        fi
        local row status base_excl_tmp wal log tmp other total
        row=$(cat "$CACHE_DIR/pgdata/$node")
        IFS='|' read -r status base_excl_tmp wal log tmp other total <<< "$row"
        if [ "$first" = true ]; then first=false; else json+=","; fi
        json+='"'"$node"'":{"status":"'"$status"'","base_excl_tmp_bytes":'"$base_excl_tmp"',"pg_wal_bytes":'"$wal"',"pg_log_bytes":'"$log"',"pgsql_tmp_bytes":'"$tmp"',"other_bytes":'"$other"',"total_bytes":'"$total"'}'
    done

    json+='}}'
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
}

# ============================================================================
# Cleanup — remove PostgreSQL log files from db nodes
# ============================================================================

cleanup_logs() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           Patroni HA Stack — Log Cleanup                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local total_freed=0

    for node in "${DB_NODES[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$node" 2>/dev/null || echo "not found")
        if [ "$status" != "running" ]; then
            printf "  ${RED}%-10s${NC} — %s, skipping\n" "$node" "$status"
            continue
        fi

        # Find the current active log (most recently modified) and old/rotated logs
        local current_log
        current_log=$(docker exec "$node" sh -c "ls -t $PG_LOG_DIR/postgresql-* 2>/dev/null | head -1" || true)
        local old_logs
        old_logs=$(docker exec "$node" sh -c "ls -t $PG_LOG_DIR/postgresql-* 2>/dev/null | tail -n +2" || true)

        if [ -z "$current_log" ] && [ -z "$old_logs" ]; then
            printf "  ${GREEN}%-10s${NC} — no log files found\n" "$node"
            continue
        fi

        # Calculate total size before cleanup
        local size_before
        size_before=$(docker exec "$node" sh -c "du -sb $PG_LOG_DIR/postgresql-* 2>/dev/null | awk '{s+=\$1} END {print s+0}'" || echo "0")

        # Size of old rotated logs (will be rm'd)
        local old_size=0
        local old_count=0
        if [ -n "$old_logs" ]; then
            old_count=$(echo "$old_logs" | wc -l | tr -d ' ')
            old_size=$(docker exec "$node" sh -c "du -sb $(echo "$old_logs" | tr '\n' ' ') 2>/dev/null | awk '{s+=\$1} END {print s+0}'" || echo "0")
        fi

        # Size of current active log (will be truncated)
        local current_size=0
        if [ -n "$current_log" ]; then
            current_size=$(docker exec "$node" sh -c "du -sb $current_log 2>/dev/null | awk '{print \$1}'" || echo "0")
        fi

        local total_node_size=$((old_size + current_size))
        local total_count=$((old_count + 1))
        printf "  ${YELLOW}%-10s${NC} — %s files, %s\n" "$node" "$total_count" "$(format_size "$total_node_size")"

        # Remove old rotated logs (no process has them open)
        if [ -n "$old_logs" ]; then
            docker exec "$node" sh -c "rm -f $(echo "$old_logs" | tr '\n' ' ')" 2>/dev/null
            printf "  ${GREEN}%-10s${NC} — removed %s old logs (%s)\n" "$node" "$old_count" "$(format_size "$old_size")"
        fi

        # Truncate the current active log (keeps fd open for PostgreSQL).
        # Before truncating, archive a copy so the forensic trail isn't lost during
        # an incident (H3): the log is the only place Patroni + PG event sequences
        # live for the leader-change / replica-lag / WAL-archive-failure events
        # that operators need to see post-mortem.
        if [ -n "$current_log" ]; then
            local archive_name="${current_log}.pretruncate.$(date -u +%Y%m%dT%H%M%SZ)"
            if docker exec "$node" cp "$current_log" "$archive_name" 2>/dev/null; then
                printf "  ${CYAN}%-10s${NC} — archived to %s\n" "$node" "$(basename "$archive_name")"
            else
                printf "  ${YELLOW}%-10s${NC} — could not archive log (proceeding with truncate anyway)\n" "$node"
            fi
            docker exec "$node" truncate -s 0 "$current_log" 2>/dev/null
            printf "  ${GREEN}%-10s${NC} — truncated active log (%s)\n" "$node" "$(format_size "$current_size")"
        fi

        total_freed=$((total_freed + total_node_size))
    done

    echo ""
    echo -e "${BOLD}${CYAN}──────────────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}${GREEN}%-35s %15s${NC}\n" "Total space freed:" "$(format_size $total_freed)"
    echo ""
}

# ============================================================================
# Cleanup — remove old .tgz dumps in backups/ and mybk/ (older than KEEP_DAYS)
# ============================================================================

cleanup_dumps() {
    echo ""
    if [ "$DO_DRY_RUN" = true ]; then
        echo -e "${BOLD}${CYAN}▶ Dry-run: .tgz dumps older than ${KEEP_DAYS} days${NC}"
    else
        echo -e "${BOLD}${CYAN}▶ Cleanup: .tgz dumps older than ${KEEP_DAYS} days${NC}"
    fi
    echo ""

    # Build a set of archive paths referenced by ACTIVE resume sessions —
    # an in-flight restore can be resumed only if its source archive is still
    # on disk. Pulling them mid-resume strands the partial DB.
    local protected_list=""
    if [ -d "$PROJECT_DIR/.restore-state" ]; then
        protected_list=$(grep -h "^ARCHIVE=" "$PROJECT_DIR/.restore-state"/*.env 2>/dev/null \
            | sed -E "s/^ARCHIVE='(.*)'$/\1/" || true)
        if [ -n "$protected_list" ]; then
            local n_protected
            n_protected=$(printf '%s\n' "$protected_list" | grep -c '^/' || true)
            printf "  ${CYAN}protected:${NC} %d archive(s) referenced by active resume state\n" "$n_protected"
        fi
    fi

    local total_freed=0 count=0 skipped=0
    local dirs=("$PROJECT_DIR/backups" "$PROJECT_DIR/mybk")

    # Collect files matching target criteria first
    local files_to_delete=()

    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            printf "  ${YELLOW}%-20s${NC} — directory not present, skipping\n" "$(basename "$dir")/"
            continue
        fi

        local found
        found=$(find "$dir" -maxdepth 2 -type f -name "*.tgz" -mtime "+${KEEP_DAYS}" 2>/dev/null || true)
        if [ -z "$found" ]; then
            printf "  ${GREEN}%-20s${NC} — no dumps older than ${KEEP_DAYS} days\n" "$(basename "$dir")/"
            continue
        fi

        while IFS= read -r f; do
            [ -z "$f" ] && continue
            # Skip files referenced by an active .restore-state/*.env
            # Compare by canonical absolute path (both sides should already be absolute).
            if [ -n "$protected_list" ] && printf '%s\n' "$protected_list" | grep -Fxq "$f"; then
                printf "  ${CYAN}kept:${NC}    %s ${YELLOW}(referenced by active resume)${NC}\n" \
                    "${f#"$PROJECT_DIR"/}"
                skipped=$((skipped + 1))
                continue
            fi
            local size
            size=$(wc -c < "$f" | tr -d ' ' 2>/dev/null || echo "0")
            size=${size:-0}
            total_freed=$((total_freed + size))
            count=$((count + 1))
            files_to_delete+=("$f")
        done <<< "$found"
    done

    if [ "$count" -eq 0 ]; then
        echo ""
        if [ "$DO_DRY_RUN" = true ]; then
            printf "  ${BOLD}${GREEN}%-35s %15s${NC} (0 files would be removed, %s kept)\n" \
                "Total space that would be freed:" "$(format_size 0)" "$skipped"
        else
            printf "  ${BOLD}${GREEN}%-35s %15s${NC} (0 files removed, %s kept)\n" \
                "Total space freed:" "$(format_size 0)" "$skipped"
        fi
        echo ""
        return 0
    fi

    # Display selected files
    echo ""
    if [ "$DO_DRY_RUN" = true ]; then
        echo -e "${YELLOW}The following $count dump file(s) would be removed:${NC}"
    else
        echo -e "${YELLOW}The following $count dump file(s) are selected for removal:${NC}"
    fi
    for f in "${files_to_delete[@]}"; do
        local f_size
        f_size=$(wc -c < "$f" | tr -d ' ' 2>/dev/null || echo "0")
        echo -e "  - ${f#"$PROJECT_DIR"/} (${CYAN}$(format_size "$f_size")${NC})"
    done
    echo ""

    if [ "$DO_DRY_RUN" = true ]; then
        printf "  ${BOLD}${GREEN}%-35s %15s${NC} (%s files would be removed, %s kept — dry-run)\n" \
            "Total space that would be freed:" "$(format_size "$total_freed")" "$count" "$skipped"
        echo ""
        return 0
    fi

    # Warning and confirmation prompt
    echo -e "${RED}${BOLD}⚠️  WARNING: YOU ARE ABOUT TO DELETE $count DATABASE DUMP(S)!${NC}"
    echo -e "${RED}This operation is destructive and cannot be undone.${NC}"
    echo ""

    local confirm=""
    if [ -t 0 ]; then
        read -p "Are you sure you want to proceed with deleting these dump files? (yes/NO): " confirm
    else
        echo -e "${RED}Error: Cannot prompt for confirmation (non-interactive shell).${NC}" >&2
        echo -e "${RED}Dump files deletion aborted for safety.${NC}" >&2
        return 1
    fi

    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Cleanup cancelled. No files were deleted.${NC}"
        echo ""
        return 0
    fi

    # Perform actual deletion
    echo ""
    echo -e "${YELLOW}Deleting dump files...${NC}"
    for f in "${files_to_delete[@]}"; do
        local size
        size=$(wc -c < "$f" | tr -d ' ' 2>/dev/null || echo "0")
        size=${size:-0}
        rm -f "$f"
        printf "  ${GREEN}✓ removed:${NC} %s (${CYAN}%s${NC})\n" \
            "${f#"$PROJECT_DIR"/}" "$(format_size "$size")"
    done

    echo ""
    printf "  ${BOLD}${GREEN}%-35s %15s${NC} (%s files removed, %s kept)\n" \
        "Total space freed:" "$(format_size "$total_freed")" "$count" "$skipped"
    echo ""
}

# ============================================================================
# Cleanup — Docker dangling images and build cache
# ============================================================================

cleanup_docker() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Cleanup: Docker dangling images + build cache${NC}"
    echo ""

    echo -e "  ${YELLOW}docker image prune -f${NC}"
    docker image prune -f 2>&1 | sed 's/^/    /'
    echo ""

    echo -e "  ${YELLOW}docker builder prune -f${NC}"
    docker builder prune -f 2>&1 | sed 's/^/    /'
    echo ""
}

# ============================================================================
# Cleanup — orphan PITR snapshot JSONs in scripts/
# ============================================================================

cleanup_snapshots() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Cleanup: PITR snapshot JSONs older than ${KEEP_DAYS} days${NC}"
    echo ""

    local found
    found=$(find "$PROJECT_DIR/scripts" -maxdepth 1 -type f \
        -name "db_stats_before_pitr_*.json" -mtime "+${KEEP_DAYS}" 2>/dev/null || true)

    local total_freed=0 count=0
    if [ -n "$found" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local size
            size=$(wc -c < "$f" | tr -d ' ' 2>/dev/null || echo "0")
            size=${size:-0}
            total_freed=$((total_freed + size))
            count=$((count + 1))
            rm -f "$f"
            printf "  ${YELLOW}removed:${NC} %s ${CYAN}(%s)${NC}\n" \
                "$(basename "$f")" "$(format_size "$size")"
        done <<< "$found"
    else
        printf "  ${GREEN}%s${NC}\n" "no snapshots older than ${KEEP_DAYS} days"
    fi

    echo ""
    printf "  ${BOLD}${GREEN}%-35s %15s${NC} (%s files)\n" "Total space freed:" "$(format_size "$total_freed")" "$count"
    echo ""
}

# ============================================================================
# Cleanup — stale PG temp files (pgsql_tmp/) on each running db node
# Only removes files older than 60 minutes to avoid races with active sorts.
# ============================================================================

cleanup_temp() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Cleanup: stale PG temp files (pgsql_tmp/, >60 min old)${NC}"
    echo ""

    local data_dir
    data_dir=$(get_patroni_data_dir)
    local total_freed=0

    for node in "${DB_NODES[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$node" 2>/dev/null || echo "not_found")
        if [ "$status" != "running" ]; then
            printf "  ${RED}%-10s${NC} — %s, skipping\n" "$node" "$status"
            continue
        fi

        # Size of stale temp files (older than 60 minutes)
        local size
        size=$(docker exec "$node" sh -c \
            "find '$data_dir' -type d -name pgsql_tmp 2>/dev/null \
             | while read -r d; do find \"\$d\" -type f -mmin +60 -printf '%s\n' 2>/dev/null; done \
             | awk '{s+=\$1} END {print s+0}'" 2>/dev/null || echo "0")
        size=${size:-0}

        if [ "$size" -eq 0 ]; then
            printf "  ${GREEN}%-10s${NC} — no stale temp files\n" "$node"
            continue
        fi

        docker exec "$node" sh -c \
            "find '$data_dir' -type d -name pgsql_tmp 2>/dev/null \
             | while read -r d; do find \"\$d\" -type f -mmin +60 -delete 2>/dev/null; done" \
            >/dev/null 2>&1 || true
        printf "  ${GREEN}%-10s${NC} — freed %s\n" "$node" "$(format_size "$size")"
        total_freed=$((total_freed + size))
    done

    echo ""
    printf "  ${BOLD}${GREEN}%-35s %15s${NC}\n" "Total space freed:" "$(format_size "$total_freed")"
    echo ""
}

# ============================================================================
# Cleanup — delete all active Backup backups
# ============================================================================

cleanup_barman() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           Patroni HA Stack — Backup Backup Cleanup           ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local barman_status
    barman_status=$(docker inspect --format='{{.State.Status}}' backup 2>/dev/null || echo "not_found")
    if [ "$barman_status" != "running" ]; then
        echo -e "${RED}Error: backup container is not running (status: ${barman_status}).${NC}" >&2
        return 1
    fi

    # Collect backups and WAL sizes across all configured DB nodes
    local backups=()
    local backup_servers=()
    local backup_ids=()
    local total_backups=0
    local total_wal_bytes=0
    local server_wal_sizes=()

    for server in "${DB_NODES[@]}"; do
        # Calculate size of WAL archive, incoming, streaming, and error queues
        local wal_bytes
        wal_bytes=$(docker exec backup sh -c "du -sb /data/pg-backup/${server}/wals /data/pg-backup/${server}/incoming /data/pg-backup/${server}/streaming /data/pg-backup/${server}/errors 2>/dev/null | awk '{s+=\$1} END {print s+0}'" 2>/dev/null || echo "0")
        wal_bytes=${wal_bytes:-0}
        total_wal_bytes=$((total_wal_bytes + wal_bytes))
        server_wal_sizes+=("$wal_bytes")

        # Calculate backups
        local server_backups
        server_backups=$(docker exec backup barman list-backup "$server" 2>/dev/null || true)
        if [ -n "$server_backups" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                if [ -n "$line" ]; then
                    backups+=("$line")
                    local b_id
                    b_id=$(echo "$line" | awk '{print $2}')
                    backup_servers+=("$server")
                    backup_ids+=("$b_id")
                    total_backups=$((total_backups + 1))
                fi
            done <<< "$server_backups"
        fi
    done

    if [ "$total_backups" -eq 0 ] && [ "$total_wal_bytes" -eq 0 ]; then
        echo -e "${GREEN}No Backup backups or archived WAL files found to clean up.${NC}"
        echo ""
        return 0
    fi

    if [ "$total_backups" -gt 0 ]; then
        echo -e "${YELLOW}Found $total_backups active Backup backup(s):${NC}"
        for b in "${backups[@]}"; do
            echo -e "  - $b"
        done
        echo ""
    fi

    echo -e "${YELLOW}WAL Archives & Staging Queues:${NC}"
    for ((idx=0; idx<${#DB_NODES[@]}; idx++)); do
        local node="${DB_NODES[$idx]}"
        local size_bytes="${server_wal_sizes[$idx]}"
        echo -e "  - ${node}: $(format_size "$size_bytes")"
    done
    echo ""

    echo -e "${RED}${BOLD}⚠️  WARNING: YOU ARE ABOUT TO PURGE ALL BACKUP BACKUPS AND WAL ARCHIVES!${NC}"
    echo -e "${RED}This operation is highly destructive and will reclaim all Backup volume space.${NC}"
    echo -e "${RED}You will lose all ability to perform backups or Point-In-Time Recovery (PITR).${NC}"
    echo ""

    # Confirmation Gate
    local confirm=""
    if [ -t 0 ]; then
        read -p "Are you absolutely sure you want to delete all Backup backups and WALs? (yes/NO): " confirm
    else
        # If not a TTY, print warning and return an error to prevent accidental deletion
        echo -e "${RED}Error: Cannot prompt for confirmation (non-interactive shell).${NC}" >&2
        echo -e "${RED}Backup backup deletion aborted for safety.${NC}" >&2
        return 1
    fi

    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Backup backup cleanup cancelled.${NC}"
        echo ""
        return 0
    fi

    # Perform active base backup deletions
    if [ "$total_backups" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Deleting backups...${NC}"
        local deleted_count=0
        local failed_count=0

        for ((i=0; i<total_backups; i++)); do
            local server="${backup_servers[$i]}"
            local b_id="${backup_ids[$i]}"
            echo -e "  Deleting backup ${CYAN}$b_id${NC} for server ${CYAN}$server${NC}..."
            if docker exec backup backup delete "$server" "$b_id" >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓ Deleted $b_id (standard)${NC}"
                deleted_count=$((deleted_count + 1))
            else
                echo -e "  ${YELLOW}⚠ Standard deletion failed (likely minimum redundancy policy).${NC}"
                echo -e "    Attempting forced deletion (\"the hard way\")..."
                
                # Remove base backup directory and metadata .info file directly inside container
                local base_dir="/data/pg-backup/${server}/base/${b_id}"
                local meta_file="/data/pg-backup/${server}/meta/${b_id}-backup.info"
                
                if docker exec backup rm -rf "$base_dir" "$meta_file" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}✓ Force-deleted $b_id files and metadata${NC}"
                    deleted_count=$((deleted_count + 1))
                else
                    echo -e "  ${RED}✗ Failed to force-delete $b_id${NC}"
                    failed_count=$((failed_count + 1))
                fi
            fi
        done
        echo ""
    fi

    # Purge WAL archives and queues for all servers to reclaim space completely
    echo -e "${YELLOW}Purging WAL archives and staging queues...${NC}"
    for server in "${DB_NODES[@]}"; do
        echo -e "  Cleaning WALs and queues for ${CYAN}$server${NC}..."
        # Delete subdirectories/files inside wals, incoming, streaming, errors
        if docker exec backup sh -c "find /data/pg-backup/${server}/wals/ /data/pg-backup/${server}/incoming/ /data/pg-backup/${server}/streaming/ /data/pg-backup/${server}/errors/ -mindepth 1 -delete 2>/dev/null || true"; then
            # Cleanly rebuild the index
            docker exec backup backup rebuild-xlogdb "$server" >/dev/null 2>&1 &
            echo -e "  ${GREEN}✓ Purged WALs and queues for $server${NC}"
        else
            echo -e "  ${RED}✗ Failed to purge WALs for $server${NC}"
        fi
    done

    echo ""
    echo -e "${GREEN}✓ Successfully completed Backup cleanup and fully reclaimed volume space.${NC}"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

build_pgdata_cache

if [ "$ANY_CLEANUP" = true ]; then
    if [ "$DO_CLEANUP_LOGS"      = true ]; then cleanup_logs;      fi
    if [ "$DO_CLEANUP_DUMPS"     = true ]; then cleanup_dumps;     fi
    if [ "$DO_CLEANUP_DOCKER"    = true ]; then cleanup_docker;    fi
    if [ "$DO_CLEANUP_SNAPSHOTS" = true ]; then cleanup_snapshots; fi
    if [ "$DO_CLEANUP_TEMP"      = true ]; then cleanup_temp;      fi
    if [ "$DO_CLEANUP_BARMAN"    = true ]; then cleanup_barman;    fi
elif [ "$OUTPUT_FORMAT" = "json" ]; then
    print_json
else
    print_human
fi
