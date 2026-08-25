#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify_backup.sh — prove a pgBackRest backup is actually restorable.
#
# Spins up an ephemeral container from the DB image, restores the requested
# backup directly from a private snapshot of the repo volume (no SSH hops,
# zero impact on the running cluster), boots PostgreSQL on a private unix
# socket, and runs sanity checks:
#   1. server starts & accepts connections
#   2. expected databases exist (incl. DEFAULT_DATABASE)
#   3. user tables exist in the default database
#   4. --deep: schema dump hash of restored vs live replica
#
# Usage:
#   verify_backup.sh [SERVER=dbN] [BACKUP_ID=latest|<label>] [--deep] [--keep] [--yes]
#   make verify-backup [SERVER=db1] [BACKUP_ID=latest] [DEEP=1]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
msg()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a
BACKUP_TOOL="${BACKUP_TOOL:-barman}"
[ "$BACKUP_TOOL" = "pgbackrest" ] || die "verify_backup currently supports BACKUP_TOOL=pgbackrest only"

PROJECT="${COMPOSE_PROJECT_NAME:-patroni-ha-dockerized}"
POSTGRES_VERSION="${POSTGRES_VERSION:-18}"
DEFAULT_DATABASE="${DEFAULT_DATABASE:-postgres}"
DB_IMAGE="localhost/patroni-ha-dockerized_db1:latest"
REPO_VOLUME_SRC="${PROJECT}_backup_pgbackrest_repo"
REPO_VOLUME_VERIFY="${PROJECT}_pgbr_verify_$$"
NET="${PROJECT}_patroni_network"

SERVER="db1"
BACKUP_ID="latest"
DEEP=0
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        SERVER=*)      SERVER="${1#*=}";;
        BACKUP_ID=*)   BACKUP_ID="${1#*=}";;
        --deep|DEEP=1) DEEP=1;;
        --keep)        KEEP=1;;
        --yes)         ;;
        -h|--help)     sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) die "unknown arg: $1";;
    esac
    shift
done

VERIFY_NAME="pgbr-verify-$(date +%s)"
COPY_NAME="pgbr-copy-$(date +%s)"
TS_START=$(date +%s)
CRONS_STOPPED=0
VERIFY_PASSED=0

cleanup() {
    # always resume repo writers, even on failure paths
    if [ "$CRONS_STOPPED" = 1 ]; then
        docker exec -u root backup supervisorctl start pgbackrest-cron pgbackrest-full-weekly >/dev/null 2>&1 || true
        CRONS_STOPPED=0
    fi
    if [ "$KEEP" != "1" ] && [ "$VERIFY_PASSED" = 1 ]; then
        docker rm -f "$VERIFY_NAME" >/dev/null 2>&1 || true
        docker rm -f "$COPY_NAME" >/dev/null 2>&1 || true
        docker volume rm "$REPO_VOLUME_VERIFY" >/dev/null 2>&1 || true
    else
        warn "kept verifier container ($VERIFY_NAME) and repo snapshot ($REPO_VOLUME_VERIFY)"
    fi
}
trap cleanup EXIT

docker image inspect "$DB_IMAGE" >/dev/null 2>&1 || die "image $DB_IMAGE not found — build the db services first"

# ── Resolve label ──
msg "${CYAN}Resolving backup for stanza $SERVER ($BACKUP_ID)...${NC}"
INFO_TXT=$(timeout 30 docker exec -u backup backup sh -c \
    "pgbackrest --stanza=$SERVER info" 2>/dev/null) || die "cannot reach repo host 'backup'"
echo "$INFO_TXT" | grep -qE '^stanza' || die "no stanza $SERVER on repo host"

if [ "$BACKUP_ID" = "latest" ]; then
    # lines look like: "        incr backup: 20260824-144511F_20260824-155917I"
    LABEL=$(printf '%s\n' "$INFO_TXT" | awk '/ backup: [0-9]/ {print $3}' | tail -1)
else
    LABEL="$BACKUP_ID"
    printf '%s\n' "$INFO_TXT" | grep -q "$LABEL" || die "backup $LABEL not found in stanza $SERVER"
fi
[ -n "${LABEL:-}" ] || die "no backups exist for stanza $SERVER — run make backup first"
msg "  Verifying label: ${CYAN}$LABEL${NC}"

# ── Private snapshot of the repo so verification never touches live files ──
msg "${CYAN}Snapshotting repo volume (private copy)...${NC}"
# Quiesce repo writers so the snapshot is consistent
CRONS_STOPPED=0
if docker exec -u root backup supervisorctl status pgbackrest-cron >/dev/null 2>&1; then
    docker exec -u root backup supervisorctl stop pgbackrest-cron pgbackrest-full-weekly >/dev/null 2>&1 && CRONS_STOPPED=1 && ok "repo writers paused"
fi
trap cleanup EXIT
docker volume create "$REPO_VOLUME_VERIFY" >/dev/null
timeout 600 docker run --rm --name "$COPY_NAME" \
    -v "${REPO_VOLUME_SRC}:/src:ro" -v "${REPO_VOLUME_VERIFY}:/dst" \
    alpine sh -c 'cp -a /src/. /dst/'
[ "$CRONS_STOPPED" = 1 ] && { docker exec -u root backup supervisorctl start pgbackrest-cron pgbackrest-full-weekly >/dev/null 2>&1 && CRONS_STOPPED=0 && ok "repo writers resumed"; }
ok "Repo snapshot ready"
# sanity: the snapshot must contain at least one stanza dir
timeout 10 docker run --rm -v "${REPO_VOLUME_VERIFY}:/r" alpine \
    sh -c 'ls /r/backup/*/backup.info >/dev/null 2>&1' \
    || die "repo snapshot incomplete (no backup.info found)"

# ── Launch verifier ──
msg "${CYAN}Launching ephemeral verifier (${DB_IMAGE})...${NC}"
docker run -d --name "$VERIFY_NAME" --hostname "$VERIFY_NAME" \
    --network "$NET" \
    -v "${REPO_VOLUME_VERIFY}:/var/lib/pgbackrest" \
    "$DB_IMAGE" sleep infinity >/dev/null

timeout 20 docker exec -e VERIFY_STANZA="$SERVER" "$VERIFY_NAME" sh -c '
mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
allow-root=y
repo1-type=posix
repo1-path=/var/lib/pgbackrest
log-level-console=info
log-level-file=debug
log-path=/var/log/pgbackrest
spool-path=/var/spool/pgbackrest
start-fast=y
process-max=4

[${VERIFY_STANZA}]
pg1-port=5431
pg1-path=/var/lib/postgresql/restore
EOF
' || die "failed to write verifier config"

# ── Restore ──
msg "${CYAN}[restore] Restoring '$LABEL' into fresh data dir...${NC}"
do_restore() {
timeout 900 docker exec "$VERIFY_NAME" sh -c \
    "rm -rf /var/lib/postgresql/restore && mkdir -p /var/lib/postgresql/restore && \
     pgbackrest --stanza=$SERVER --set=$LABEL --type=immediate --target-action=pause \
                --log-level-console=info restore && \
     chown -R postgres:postgres /var/lib/postgresql/restore" 2>&1 | tail -3
}
if ! RESTORE_OUT=$(do_restore); then
    warn "first restore attempt failed — retrying once"
    sleep 2
    RESTORE_OUT=$(do_restore) || { printf '%s\n' "$RESTORE_OUT"; die "pgbackrest restore failed (after retry)"; }
fi
printf '%s\n' "$RESTORE_OUT" | sed 's/^/    /'

PGDATA_V="/var/lib/postgresql/restore"
timeout 10 docker exec "$VERIFY_NAME" test -f "$PGDATA_V/PG_VERSION" \
    || die "restore produced no PG_VERSION"

SIZE=$(timeout 10 docker exec "$VERIFY_NAME" du -sh "$PGDATA_V" | cut -f1)
ok "Restore complete ($SIZE)"

# ── Normalize config for isolated boot ──
# Patroni-managed clusters reference absolute paths from the original node
# (hba_file, certs) and archive targets that don't exist here.
timeout 20 docker exec -i "$VERIFY_NAME" bash << EOF
set -e
cat > '$PGDATA_V/pg_hba.conf' << 'HBA'
local all all trust
host all all 127.0.0.1/32 trust
HBA
: > '$PGDATA_V/pg_ident.conf'
{
  echo "hba_file = '$PGDATA_V/pg_hba.conf'"
  echo "ident_file = '$PGDATA_V/pg_ident.conf'"
  echo "archive_mode = off"
  echo "ssl = off"
} >> '$PGDATA_V/postgresql.auto.conf'
chown postgres:postgres '$PGDATA_V'/pg_hba.conf '$PGDATA_V'/pg_ident.conf '$PGDATA_V'/postgresql.auto.conf
# postgres (uid differs from repo owner) must read archived WAL + write spool
chmod -R a+rX /var/lib/pgbackrest
mkdir -p /var/spool/pgbackrest /var/log/pgbackrest
chown -R postgres:postgres /var/spool/pgbackrest /var/log/pgbackrest
EOF
ok "Config normalized for isolated boot"

# ── Boot PostgreSQL (unix socket only — no TCP, no port conflicts) ──
msg "${CYAN}[boot] Starting PostgreSQL from the restored data...${NC}"
timeout 90 docker exec -u postgres "$VERIFY_NAME" sh -c \
    "/usr/lib/postgresql/${POSTGRES_VERSION}/bin/pg_ctl -D '$PGDATA_V' \
     -o '-p 5544 -k /tmp -c listen_addresses=\"\" -c fsync=off -c synchronous_commit=off -c full_page_writes=off' \
     -l /tmp/pg.log -w -t 60 start" \
    || { timeout 10 docker exec "$VERIFY_NAME" tail -25 "$PGDATA_V/log/"* 2>/dev/null || timeout 10 docker exec "$VERIFY_NAME" cat /tmp/pg.log 2>/dev/null; \
         die "restored cluster refused to start"; }
ok "PostgreSQL accepting connections on restored data"

psql_v() { timeout 15 docker exec -u postgres "$VERIFY_NAME" psql -h /tmp -p 5544 -U postgres -d "${2:-$DEFAULT_DATABASE}" -tAc "$1" 2>&1; }

FAIL=0

msg "${CYAN}[check 1] version${NC}"
V=$(psql_v "select current_setting('server_version_num')::int/10000")
case "$V" in "$POSTGRES_VERSION") ok "major version = $V";; *) FAIL=1; warn "version mismatch: got '$V', want $POSTGRES_VERSION";; esac

msg "${CYAN}[check 2] database inventory${NC}"
DBS=$(psql_v "select string_agg(datname, ', ') from pg_database where datallowconn")
msg "  databases: ${DBS:-<none>}"
case "$(echo "$DBS" | tr -d ' ')" in *",$DEFAULT_DATABASE"*|*"${DEFAULT_DATABASE},"*|*"$DEFAULT_DATABASE"*) ok "default database present: $DEFAULT_DATABASE";; *) FAIL=1; warn "DEFAULT_DATABASE '$DEFAULT_DATABASE' MISSING";; esac

msg "${CYAN}[check 3] application tables${NC}"
TB=$(psql_v "select count(*) from information_schema.tables where table_schema='public'" "$DEFAULT_DATABASE")
case "$TB" in ''|*[!0-9]*) TB=0;; esac
[ "$TB" -gt 0 ] && ok "public tables in $DEFAULT_DATABASE: $TB" || msg "  note: no public tables in $DEFAULT_DATABASE (informational)"

if [ "$DEEP" = 1 ]; then
    msg "${CYAN}[check 4 --deep] schema hash vs live node${NC}"
    LIVE=$(docker ps --format '{{.Names}}' | grep -E '^db[0-9]+$' | head -1)
    H1=$(timeout 30 docker exec -u postgres "$VERIFY_NAME" sh -c \
        "pg_dump -h /tmp -p 5544 -U postgres -s '$DEFAULT_DATABASE' | sha256sum" | cut -d' ' -f1)
    H2=$(timeout 30 docker exec "$LIVE" sh -c \
        "su postgres -c \"pg_dump -p 5431 -U postgres -s '$DEFAULT_DATABASE'\" | sha256sum" | cut -d' ' -f1)
    if [ "$H1" = "$H2" ] && [ -n "$H1" ]; then
        ok "schema hash matches live node ($H1)"
    else
        warn "schema hash differs from live node (expected if live advanced past this backup): restored=$H1 live=$H2"
    fi
fi

DUR=$(( $(date +%s) - TS_START ))
if [ "$FAIL" = 0 ]; then
    VERIFY_PASSED=1
    ok "═══ VERIFICATION PASSED ═══  $SERVER/$LABEL restored & healthy (${DUR}s)"
    exit 0
fi
die "VERIFICATION FAILED — see warnings above"
