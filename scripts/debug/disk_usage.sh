#!/bin/bash

# Script to summarize disk usage across all docker-compose services
# Shows container filesystem, volumes, and images sizes
# Usage: bash scripts/debug/disk_usage.sh [--json|--cleanup]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../.."

OUTPUT_FORMAT="human"
DO_CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --json)    OUTPUT_FORMAT="json" ;;
        --cleanup) DO_CLEANUP=true ;;
    esac
done

# DB nodes that have PostgreSQL logs
DB_NODES=(db1 db2 db3 db4)
PG_LOG_DIR="/var/log/postgresql"

# Services from docker-compose
SERVICES=(etcd1 etcd2 db1 db2 db3 db4 barman haproxy pgbouncer pgbouncer-ro)

# Named volumes from docker-compose
VOLUMES=(etcd1_data etcd2_data db1_data db2_data db3_data db4_data barman_data barman_backup)

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

        # Truncate the current active log (keeps fd open for PostgreSQL)
        if [ -n "$current_log" ]; then
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
# Main
# ============================================================================

if [ "$DO_CLEANUP" = true ]; then
    cleanup_logs
elif [ "$OUTPUT_FORMAT" = "json" ]; then
    print_json
else
    print_human
fi
