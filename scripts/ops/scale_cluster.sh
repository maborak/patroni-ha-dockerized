#!/bin/bash
# scripts/ops/scale_cluster.sh
# ============================================================================
# Scale the Patroni cluster: grow or shrink the number of PostgreSQL nodes.
#
# Grow:   regenerates configs, starts new dbN containers which join as
#         replicas (Patroni basebackup), then waits until every member is
#         running/streaming.
# Shrink: removes the highest-numbered nodes. If the current leader is among
#         them, a switchover to a surviving node is performed first. After
#         `compose up` prunes the orphaned containers, their data/log volumes
#         and Backup server data are deleted (irreversible — type-to-confirm).
#
# Usage:
#   bash scripts/ops/scale_cluster.sh --replicas 5 [--yes] [--dry-run]
#                                     [--skip-wait] [--timeout SECONDS]
#   make scale REPLICAS=5 [YES=1] [DRY_RUN=1] [SKIP_WAIT=1] [TIMEOUT=900]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# ----------------------------------------------------------------------------
# Logging helpers (same style as ops/lib/cross_cluster.sh)
# ----------------------------------------------------------------------------
log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
fatal()  { echo -e "${RED}✗ FATAL:${NC} $*" >&2; exit 1; }
step()   { echo -e "\n${BOLD}${BLUE}════ $* ════${NC}\n" >&2; }
banner() { echo -e "\n${BOLD}${MAGENTA}$*${NC}\n" >&2; }

REPLICAS_ARG=""
YES=0
DRY_RUN=0
SKIP_WAIT=0
TIMEOUT="${SCALE_WAIT_TIMEOUT:-900}"
SCRIPT_PHASE="init"

print_help() {
    cat <<EOF
Usage: $0 --replicas N [options]

Scale the Patroni cluster to N replicas (+1 leader = N+1 members total).
Nodes are always named db1..dbN contiguously.

Options:
  --replicas N     Target number of replicas (required, >= 1)
  --yes            Skip all interactive confirmations
  --dry-run        Print the plan and commands without executing them
  --skip-wait      Do not wait for all members to reach running/streaming
  --timeout SECS   Seconds to wait for cluster health (default: ${TIMEOUT})
  -h, --help       Show this help

Examples:
  make scale REPLICAS=5                 # grow/shrink to 6 members total
  make scale REPLICAS=1 DRY_RUN=1       # preview what would happen
  make scale REPLICAS=2 YES=1           # unattended
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --replicas)  REPLICAS_ARG="${2:-}"; shift ;;
        --yes)       YES=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --skip-wait) SKIP_WAIT=1 ;;
        --timeout)   TIMEOUT="${2:-}"; shift ;;
        -h|--help)   print_help; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; print_help; exit 1 ;;
    esac
    shift

done

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "" >&2
        echo -e "${RED}${BOLD}════ SCALE ABORTED at phase: $SCRIPT_PHASE ════${NC}" >&2
        case "$SCRIPT_PHASE" in
            preflight|confirm)
                echo "Cluster is INTACT — nothing was changed." >&2
                ;;
            switchover)
                echo "Leader switchover may be incomplete. Check: make status" >&2
                echo "Manual switchover: make switchover NEW_LEADER=dbN" >&2
                ;;
            generate|compose-up)
                echo ".env was updated but compose changes may be partial." >&2
                echo "Retry with: make scale REPLICAS=<n>" >&2
                ;;
            volumes|backup-cleanup)
                echo "Containers/volumes may be partially removed." >&2
                echo "Check: make status · docker volume ls | grep db · docker exec backup ls /var/lib/backup" >&2
                ;;
            wait-healthy)
                echo "Scale applied but cluster did not become healthy within ${TIMEOUT}s." >&2
                echo "Inspect: make status · docker logs db<N> · make check" >&2
                ;;
        esac
    fi
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
SCRIPT_PHASE="preflight"

if [ -z "$REPLICAS_ARG" ]; then
    echo "Current topology: ${PATRONI_NODES} members (${PATRONI_REPLICAS} replicas + 1 leader)" >&2
    fatal "--replicas N is required. Example: make scale REPLICAS=5"
fi

case "$REPLICAS_ARG" in
    ''|*[!0-9]*) fatal "--replicas must be an integer (got '$REPLICAS_ARG')" ;;
esac
if [ "$REPLICAS_ARG" -lt 1 ]; then
    fatal "--replicas must be >= 1 (the leader is additional)"
fi

TARGET_REPLICAS="$REPLICAS_ARG"
TARGET_NODES=$((TARGET_REPLICAS + 1))
CURRENT_NODES="$PATRONI_NODES"

# Prefer compose v2 plugin, fall back to legacy binary (same as check_stack.sh)
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    fatal "docker compose is not available"
fi

STACK_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^db[0-9]\+$' || true)
if [ "$STACK_RUNNING" -eq 0 ] && [ "$DRY_RUN" != "1" ]; then
    fatal "No db containers are running. Start the stack first: make up"
fi

banner "Cluster Scale: ${CURRENT_NODES} → ${TARGET_NODES} members"
log "Cluster: ${PATRONI_CLUSTER_NAME} · PG ${POSTGRES_VERSION:-15} · dry-run=${DRY_RUN}"

CURRENT_LEADER=""
if [ "$STACK_RUNNING" -gt 0 ]; then
    CURRENT_LEADER=$(detect_leader_api 2>/dev/null || detect_leader 2>/dev/null || echo "")
fi

# Build node lists
REMOVED_NODES=""
GROWN_NODES=""
if [ "$TARGET_NODES" -gt "$CURRENT_NODES" ]; then
    MODE="grow"
    for i in $(seq "$((CURRENT_NODES + 1))" "$TARGET_NODES"); do
        GROWN_NODES="${GROWN_NODES} db${i}"
    done
elif [ "$TARGET_NODES" -lt "$CURRENT_NODES" ]; then
    MODE="shrink"
    for i in $(seq "$((TARGET_NODES + 1))" "$CURRENT_NODES"); do
        REMOVED_NODES="${REMOVED_NODES} db${i}"
    done
else
    ok "Cluster already has ${TARGET_NODES} members — nothing to do."
    exit 0
fi

# ----------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------
step "Plan (${MODE})"

VOLUMES_TO_DELETE=""
BARMAN_DIRS_TO_DELETE=""
if [ "$MODE" = "shrink" ]; then
    for n in $REMOVED_NODES; do
        VOLUMES_TO_DELETE="${VOLUMES_TO_DELETE}\n    ✗ volume ${n}_data (PostgreSQL data — DELETED)"
        VOLUMES_TO_DELETE="${VOLUMES_TO_DELETE}\n    ✗ volume ${n}_logs (JSON logs — DELETED)"
        if [ "${BACKUP_TOOL:-barman}" = "pgbackrest" ]; then
            BARMAN_DIRS_TO_DELETE="${BARMAN_DIRS_TO_DELETE} /var/lib/pgbackrest/backup/$n"
        else
            BARMAN_DIRS_TO_DELETE="${BARMAN_DIRS_TO_DELETE} /var/lib/backup/$n /data/pg-backup/$n"
        fi
    done
    echo -e "  Removing nodes:${REMOVED_NODES}" >&2
    echo -e "${YELLOW}  Data loss summary:${NC}" >&2
    echo -e "    ✗ containers:${REMOVED_NODES}" >&2
    echo -e "$VOLUMES_TO_DELETE" >&2
    echo -e "    ✗ Backup backups/WAL for these servers (see cleanup below)" >&2
    if echo " $REMOVED_NODES " | grep -q " ${CURRENT_LEADER} "; then
        echo -e "${YELLOW}    ⚠ ${CURRENT_LEADER} is the CURRENT LEADER — a switchover will be performed first.${NC}" >&2
    fi
else
    echo -e "  Adding nodes:${GROWN_NODES}" >&2
    echo "  New nodes join as replicas and sync from the leader (basebackup)." >&2
    echo "  Ports are appended to .env automatically." >&2
fi

if [ "$DRY_RUN" = "1" ]; then
    step "Dry-run — commands that would run"
    echo "  1. PATRONI_REPLICAS=${TARGET_REPLICAS} bash scripts/generate_configs.sh" >&2
    if [ "$MODE" = "shrink" ]; then
        echo "  2. (if leader is removed) patronictl switchover --candidate <survivor>" >&2
        echo "  3. $DOCKER_COMPOSE up -d --remove-orphans      # prunes orphaned db containers" >&2
        echo "  4. docker volume rm <project>_db<N>_data <project>_db<N>_logs   # per removed node" >&2
        echo "  5. docker exec backup rm -rf$BARMAN_DIRS_TO_DELETE" >&2
    else
        echo "  2. $DOCKER_COMPOSE up -d --remove-orphans" >&2
        echo "  3. wait until all ${TARGET_NODES} members are running/streaming (timeout ${TIMEOUT}s)" >&2
    fi
    ok "Dry-run complete — .env and configs were NOT modified."
    exit 0
fi

# Leader as reported by patronictl (authoritative; no API fallback guessing)
leader_via_patronictl() {
    local out
    out=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || true)
    # print only the first match so no downstream consumer exits early
    # (grep -q/head would trigger SIGPIPE + pipefail false negatives)
    echo "$out" | awk -F'|' '/Leader/ && !/Standby/ {if (!found) {gsub(/ /, "", $2); print $2; found=1}}'
}

# ----------------------------------------------------------------------------
# Shrink: switchover first if the leader is being removed
# ----------------------------------------------------------------------------
SCRIPT_PHASE="switchover"
if [ "$MODE" = "shrink" ] && [ -n "$CURRENT_LEADER" ] \
        && echo " $REMOVED_NODES " | grep -q " ${CURRENT_LEADER} "; then
    log "${CURRENT_LEADER} is the leader — picking a survivor to promote..."
    CANDIDATE=""
    for i in $(seq 1 "$TARGET_NODES"); do
        api_port=$(get_api_port "$i")
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://localhost:${api_port}/replica" 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            CANDIDATE="db${i}"
            break
        fi
    done
    [ -n "$CANDIDATE" ] || fatal "No healthy surviving replica found for switchover."
    log "Switchover ${CURRENT_LEADER} → ${CANDIDATE}"
    if ! docker exec "$CANDIDATE" patronictl -c /etc/patroni/patroni.yml switchover \
            --leader "$CURRENT_LEADER" --candidate "$CANDIDATE" --force >/dev/null 2>&1; then
        fatal "Switchover failed. Aborting scale — cluster unchanged. Try manually: make switchover NEW_LEADER=$CANDIDATE"
    fi
    elapsed=0
    while [ "$elapsed" -lt 120 ]; do
        [ "$(leader_via_patronictl)" = "$CANDIDATE" ] && break
        sleep 5
        elapsed=$((elapsed + 5))
    done
    [ "$(leader_via_patronictl)" = "$CANDIDATE" ] \
        || fatal "${CANDIDATE} did not become leader within 120s. Aborting — nothing deleted."
    ok "${CANDIDATE} is the new leader"
fi

# ----------------------------------------------------------------------------
# Confirm (shrink is destructive; grow is cheap but still worth a glance)
# ----------------------------------------------------------------------------
SCRIPT_PHASE="confirm"
if [ "$MODE" = "shrink" ]; then
    if [ "$YES" != "1" ]; then
        echo "" >&2
        echo -e "${RED}${BOLD}WARNING: shrinking deletes ALL data of:${NC}${REMOVED_NODES}" >&2
        echo "  - containers, data + log volumes, Backup backups & WAL archives" >&2
        echo "  There is NO undo. Save data first if needed (make backup / make dump-db)." >&2
        printf "%bType exactly 'SCALE' to confirm:%b " "${YELLOW}${BOLD}" "${NC}" >&2
        read -r answer
        [ "$answer" = "SCALE" ] || fatal "Aborted by user."
    else
        log "[--yes] auto-confirming destructive shrink"
    fi
else
    confirm_grow() {
        if [ "$YES" = "1" ]; then return 0; fi
        printf "%bProceed with adding%s? (yes/no): %b" "${YELLOW}" "${GROWN_NODES}" "${NC}" >&2
        read -r answer
        [ "$answer" = "yes" ]
    }
    if ! confirm_grow; then
        fatal "Aborted by user."
    fi
fi

# ----------------------------------------------------------------------------
# Regenerate configs with the new replica count
# ----------------------------------------------------------------------------
SCRIPT_PHASE="generate"
step "Generating configs for ${TARGET_NODES} members"
PATRONI_REPLICAS="$TARGET_REPLICAS" bash "$SCRIPT_DIR/../generate_configs.sh" >&2

# ----------------------------------------------------------------------------
# Apply via compose (--remove-orphans prunes removed/newly-absent services)
# ----------------------------------------------------------------------------
SCRIPT_PHASE="compose-up"
step "Applying compose changes"
# shellcheck disable=SC2086
$DOCKER_COMPOSE up -d --remove-orphans

# backup/supervisord.conf (with the per-server backup loop) is COPYd into the
# backup image at build time — rebuild so the loop covers the new node set.
if [ "$MODE" = "grow" ]; then
    log "Rebuilding backup image so its backup loop covers the new nodes..."
    # shellcheck disable=SC2086
    $DOCKER_COMPOSE build backup >/dev/null
    # shellcheck disable=SC2086
    $DOCKER_COMPOSE up -d backup
fi

# ----------------------------------------------------------------------------
# Shrink cleanup: volumes + Backup server data (AFTER compose re-created
# haproxy/pgbadger/backup without the removed mounts)
# ----------------------------------------------------------------------------
SCRIPT_PHASE="volumes"
if [ "$MODE" = "shrink" ]; then
    step "Deleting volumes of removed nodes"
    for n in $REMOVED_NODES; do
        for kind in data logs; do
            VOL_NAMES=$(docker volume ls --format '{{.Name}}' 2>/dev/null \
                | grep -E "(^|_)${n}_${kind}$" || true)
            for vol in $VOL_NAMES; do
                if docker volume rm "$vol" >/dev/null 2>&1; then
                    ok "deleted volume $vol"
                else
                    warn "could not delete volume $vol (still in use?) — remove manually later"
                fi
            done
        done
    done

    SCRIPT_PHASE="backup-cleanup"
    step "Cleaning Backup data for removed nodes"
    # capture first, then grep: under `pipefail`, `cmd | grep -q` can fail
    # via SIGPIPE when grep exits before the producer finishes writing
    RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    if echo "$RUNNING_CONTAINERS" | grep -q '^backup$'; then
        # shellcheck disable=SC2086
        docker exec backup sh -c "rm -rf$BARMAN_DIRS_TO_DELETE" && ok "Backup server data cleaned"
    else
        warn "backup container not running — clean manually: docker exec backup rm -rf$BARMAN_DIRS_TO_DELETE"
    fi
fi

# ----------------------------------------------------------------------------
# Wait for a healthy cluster
# ----------------------------------------------------------------------------
cluster_rows() {
    docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
        | grep -E '^\| +db[0-9]+' || true
}

healthy_members() {
    # prints "<healthy>/<listed> leaders:<n>" for the current cluster view
    local rows healthy=0 listed=0 leaders=0
    rows=$(cluster_rows)
    [ -z "$rows" ] && { echo "0/0 leaders:0"; return 0; }
    while IFS='|' read -r _ member host role state _rest; do
        listed=$((listed + 1))
        role=$(echo "$role" | xargs)
        state=$(echo "$state" | xargs)
        [ "$role" = "Leader" ] && leaders=$((leaders + 1))
        case "$state" in
            running|streaming) healthy=$((healthy + 1)) ;;
        esac
    done <<EOF
$rows
EOF
    echo "${healthy}/${listed} leaders:${leaders}"
}

wait_healthy() {
    local elapsed=0 snapshot
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        snapshot=$(healthy_members)
        if [ "$snapshot" = "${TARGET_NODES}/${TARGET_NODES} leaders:1" ]; then
            ok "All ${TARGET_NODES} members healthy, exactly one leader."
            return 0
        fi
        log "  [$((elapsed))s] members ${snapshot} — target ${TARGET_NODES}/${TARGET_NODES}"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    warn "Cluster not fully healthy after ${TIMEOUT}s (last: $(healthy_members))."
    warn "Continue monitoring with: make status"
    return 1
}

if [ "$SKIP_WAIT" != "1" ]; then
    SCRIPT_PHASE="wait-healthy"
    step "Waiting for cluster health (timeout ${TIMEOUT}s)"
    wait_healthy || true
fi

# ----------------------------------------------------------------------------
# Final status
# ----------------------------------------------------------------------------
step "Done"
echo -e "  New topology: ${BOLD}${TARGET_NODES} members (${TARGET_REPLICAS} replicas + 1 leader)${NC}\n" >&2
docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || true
echo "" >&2
echo "  Verify: make status · make check" >&2
if [ "$MODE" = "grow" ]; then
    echo "  New nodes stream from the leader; first Backup backup happens on schedule." >&2
fi
