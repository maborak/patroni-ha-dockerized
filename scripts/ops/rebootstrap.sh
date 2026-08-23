#!/bin/bash
# scripts/ops/rebootstrap.sh
# ============================================================================
# Dedicated version-switch process: destroy + fresh bootstrap on new
# PostgreSQL / etcd versions. Spawned by the setup wizard when the operator
# switches a bootstrap-bound component on an existing cluster, and usable
# directly:
#
#   make rebootstrap POSTGRES_VERSION=18 ETCD_VERSION=3.7.1 [YES=1] [DRY_RUN=1]
#   bash scripts/ops/rebootstrap.sh --postgres 18 --etcd v3.7.1 ...
#
# Why this exists: etcd cannot jump majors on old DCS data and PostgreSQL
# cannot open another major's data directory — switching either requires
# destroying every volume and bootstrapping from scratch. Doing that inline
# inside other commands hides a destructive operation where it doesn't belong;
# here it is the whole job, with explicit phases and confirmations.
#
# Phases:
#   1. preflight   — validate targets against the version registry, probe the
#                    currently deployed versions (running containers preferred,
#                    .env fallback), refuse no-op or unknown states
#   2. dump        — optional logical dumps via scripts/backup/dump_database.sh
#                    (--dump-db NAME, repeatable; recommended before wiping)
#   3. confirm     — type REBOOTSTRAP (skipped with --yes / --from-wizard)
#   4. destroy     — docker-compose down -v (ALL volumes: DBs, Barman, logs)
#   5. configure   — write target versions to .env (--from-wizard already did)
#   6. bootstrap   — generate configs, compose up, wait until healthy
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/versions.sh
source "$SCRIPT_DIR/../lib/versions.sh"

log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
fatal()  { echo -e "${RED}✗ FATAL:${NC} $*" >&2; exit 1; }
step()   { echo -e "\n${BOLD}${BLUE}════ $* ════${NC}\n" >&2; }

TARGET_PG="" TARGET_ETCD=""
FROM_WIZARD=0 YES=0 DRY_RUN=0 TIMEOUT="${REBOOTSTRAP_TIMEOUT:-600}"
DUMP_DBS=""

print_help() {
    cat <<EOF
Usage: $0 --postgres VERSION --etcd VERSION [options]

Destroy every volume and rebootstrap the cluster on new PostgreSQL/etcd
versions. ALL DATA IS LOST (databases, Barman backups, pgBadger history).

Options:
  --postgres VERSION   Target PostgreSQL major (required)
  --etcd VERSION       Target etcd version (required)
  --dump-db NAME       Logical-dump this DB before destroying (repeatable)
  --from-wizard        Invoked by the setup wizard (.env already carries the
                       targets; source versions are passed via --from-pg/--from-etcd)
  --from-pg VERSION    Currently deployed PG major (skips live probing)
  --from-etcd VERSION  Currently deployed etcd version (skips live probing)
  --yes                Skip confirmations (dumps still require explicit --dump-db)
  --dry-run            Print the plan without touching anything
  --timeout SECS       Health-wait budget after bootstrap (default: ${TIMEOUT})
  -h, --help           This help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --postgres)    TARGET_PG="${2:-}"; shift ;;
        --etcd)        TARGET_ETCD="${2:-}"; shift ;;
        --dump-db)     DUMP_DBS="$DUMP_DBS ${2:-}"; shift ;;
        --from-wizard) FROM_WIZARD=1 ;;
        --from-pg)     FROM_PG_EXPLICIT="${2:-}"; shift ;;
        --from-etcd)   FROM_ETCD_EXPLICIT="${2:-}"; shift ;;
        --yes)         YES=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --timeout)     TIMEOUT="${2:-}"; shift ;;
        -h|--help)     print_help; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; print_help; exit 1 ;;
    esac
    shift
done

PHASE="preflight"
on_exit() {
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo "" >&2
    echo -e "${RED}${BOLD}════ REBOOTSTRAP ABORTED at phase: $PHASE ════${NC}" >&2
    case "$PHASE" in
        preflight|dump|confirm)
            echo "Nothing was destroyed — the cluster is intact." >&2 ;;
        destroy)
            echo "Volumes may be partially removed. Check: docker volume ls | grep -E 'db[0-9]_|etcd'" >&2 ;;
        configure|bootstrap)
            echo ".env/configs hold the NEW versions. Resume with: make up" >&2
            echo "(the cluster will bootstrap fresh on them)" >&2 ;;
    esac
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# Phase 1 — preflight
# ----------------------------------------------------------------------------
# Wizard path: targets were already written into .env upstream
if [ "$FROM_WIZARD" = "1" ]; then
    [ -n "$TARGET_PG" ]   || TARGET_PG=$(grep -E '^POSTGRES_VERSION=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$TARGET_ETCD" ] || TARGET_ETCD=$(grep -E '^ETCD_VERSION=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
fi
[ -n "$TARGET_PG" ]  || fatal "--postgres is required"
[ -n "$TARGET_ETCD" ] || fatal "--etcd is required"
validate_version_or_die POSTGRES "$TARGET_PG";  TARGET_PG="$POSTGRES_VERSION"
validate_version_or_die ETCD "$TARGET_ETCD";    TARGET_ETCD="$ETCD_VERSION"

deployed_pg() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^db1$'; then
        local out
        out=$(docker exec db1 sh -c 'ls /var/lib/postgresql/ 2>/dev/null | grep -E "^[0-9]+$" | sort -n | tail -1' 2>/dev/null || true)
        [ -n "$out" ] && { echo "$out"; return 0; }
    fi
    echo "${FROM_PG_EXPLICIT:-$(grep -E '^POSTGRES_VERSION=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)}"
}
deployed_etcd() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^etcd1$'; then
        local out
        out=$(docker exec etcd1 etcd --version 2>/dev/null || true)
        out=$(printf '%s' "$out" | awk '/etcd Version/{print $3; exit}')
        [ -n "$out" ] && { echo "v${out#v}"; return 0; }
    fi
    echo "${FROM_ETCD_EXPLICIT:-$(grep -E '^ETCD_VERSION=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)}"
}

CURRENT_PG=$(deployed_pg); CURRENT_ETCD=$(deployed_etcd)
[ -n "$CURRENT_PG" ]   || fatal "could not determine deployed PostgreSQL version (stack never ran? use 'make wizard' instead)"
[ -n "$CURRENT_ETCD" ] || fatal "could not determine deployed etcd version"

step "Version-switch plan"
echo "  PostgreSQL:  ${CURRENT_PG}  →  ${BOLD}${TARGET_PG}${NC}" >&2
echo "  etcd:        ${CURRENT_ETCD}  →  ${BOLD}${TARGET_ETCD}${NC}" >&2
if [ "$CURRENT_PG" = "$TARGET_PG" ] && [ "$CURRENT_ETCD" = "$TARGET_ETCD" ]; then
    ok "Already running the requested versions — nothing to do."
    exit 0
fi
if [ "$DRY_RUN" = "1" ]; then
    echo "" >&2
    echo "  Dry-run — commands that would run:" >&2
    [ -n "$(echo $DUMP_DBS)" ] && echo "    dump-db:$DUMP_DBS" >&2
    echo "    docker-compose down -v" >&2
    echo "    write .env: POSTGRES_VERSION=$TARGET_PG ETCD_VERSION=$TARGET_ETCD" >&2
    echo "    make generate && docker-compose up -d && wait-healthy (${TIMEOUT}s)" >&2
    ok "Dry-run complete — nothing was touched."
    exit 0
fi

# ----------------------------------------------------------------------------
# Phase 2 — optional logical dumps
# ----------------------------------------------------------------------------
PHASE="dump"
for db in $DUMP_DBS; do
    log "Logical dump of '$db' (saved into ./backups)"
    bash "$SCRIPT_DIR/../backup/dump_database.sh" --db "$db" --yes >&2 \
        || fatal "dump of '$db' failed — refusing to destroy without a good copy."
done
if [ -z "$(echo $DUMP_DBS)" ] && [ "$YES" != "1" ] && [ "$FROM_WIZARD" != "1" ]; then
    warn "No --dump-db given: databases are NOT being copied before destruction."
fi

# ----------------------------------------------------------------------------
# Phase 3 — confirm
# ----------------------------------------------------------------------------
PHASE="confirm"
if [ "$YES" != "1" ] && [ "$FROM_WIZARD" != "1" ]; then
    echo "" >&2
    echo -e "${RED}${BOLD}This destroys ALL volumes (databases, Barman backups, pgBadger history)${NC}" >&2
    printf "%bType exactly 'REBOOTSTRAP' to continue:%b " "${YELLOW}${BOLD}" "${NC}" >&2
    read -r answer || answer=""
    [ "$answer" = "REBOOTSTRAP" ] || fatal "aborted by operator."
elif [ "$FROM_WIZARD" = "1" ]; then
    log "[wizard] confirmation already collected upstream"
else
    log "[--yes] skipping confirmation"
fi

# ----------------------------------------------------------------------------
# Phase 4 — destroy
# ----------------------------------------------------------------------------
PHASE="destroy"
step "Destroying volumes"
docker-compose down -v

# ----------------------------------------------------------------------------
# Phase 5 — configure (.env targets; wizard path already wrote them)
# ----------------------------------------------------------------------------
PHASE="configure"
if [ "$FROM_WIZARD" != "1" ]; then
    step "Writing target versions to .env"
    for kv in "POSTGRES_VERSION=$TARGET_PG" "ETCD_VERSION=$TARGET_ETCD"; do
        key="${kv%%=*}"
        if grep -qE "^${key}=" "$PROJECT_ROOT/.env"; then
            sed -i.bak -E "s|^${key}=.*|${kv}|" "$PROJECT_ROOT/.env" && rm -f "$PROJECT_ROOT/.env.bak"
        else
            printf '%s\n' "$kv" >> "$PROJECT_ROOT/.env"
        fi
        ok ".env: ${kv}"
    done
fi

# ----------------------------------------------------------------------------
# Phase 6 — bootstrap fresh
# ----------------------------------------------------------------------------
PHASE="bootstrap"
step "Bootstrapping on PostgreSQL ${TARGET_PG} / etcd ${TARGET_ETCD}"
bash "$SCRIPT_DIR/../generate_configs.sh" >&2
# --build is essential: compose does NOT rebuild images when build args
# (POSTGRES_VERSION etc.) change, and stale images are exactly what breaks
# a fresh bootstrap (PG15 binaries vs PG18 datadir paths).
docker-compose up -d --remove-orphans --build

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    list=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || true)
    if echo "$list" | grep -q "Leader.*running" \
        && [ "$(echo "$list" | grep -cE 'Replica.*(streaming|running)')" -ge "$PATRONI_REPLICAS" ]; then
        ok "Cluster healthy: leader + replicas streaming on the new versions."
        echo "" >&2
        echo "$list" >&2
        echo "" >&2
        echo "  Verify: make status · make check · psql 'SHOW server_version;'" >&2
        echo "  Reminder: first Barman backup happens on schedule — trigger early: make backup" >&2
        exit 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
done
warn "Not fully healthy after ${TIMEOUT}s — inspect with: make status · docker logs db1"
exit 1
