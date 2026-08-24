#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pgBackRest Point-In-Time Recovery for the Patroni stack.
#
# Restores a stanza from a pgBackRest backup set and replays WAL up to a
# chosen target (time by default), entirely through pgBackRest itself:
#
#   pgbackrest --stanza=<s> --set=<backup> --type=time --target='<ts>' \
#              --target-action=promote restore
#
# ⚠  SEMANTICS — read before running:
#   A PITR restore forks PostgreSQL history at the target instant. If the rest
#   of the cluster kept running past that point, the restored node cannot
#   simply rejoin: take the cluster down first (full DR), or salvage data from
#   an isolated node. This tool refuses nothing blindly — it warns loudly.
#
# Usage:
#   pgbackrest_pitr.sh                       # interactive wizard
#   pgbackrest_pitr.sh --server db1 --backup-id 20260824-144511F \
#        --target-time '2026-08-24 12:00:00' [--target-node db2] \
#        [--target-type time|name|xid|immediate] [--target-xid N]
#        [--target-action promote|pause] [--yes] [--dry-run]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
msg()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Load .env (BACKUP_TOOL sanity) ──
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a
BACKUP_TOOL="${BACKUP_TOOL:-barman}"
[ "$BACKUP_TOOL" = "pgbackrest" ] || die "This wizard drives BACKUP_TOOL=pgbackrest (found: $BACKUP_TOOL)"

# ── Defaults ──
SERVER=""          # stanza/source node holding the backup
BACKUP_ID=""       # backup label (empty = latest)
TARGET_NODE=""     # node receiving the restore (default = SERVER)
TARGET_TIME=""
TARGET_XID=""
TARGET_TYPE="time"
TARGET_ACTION="promote"
ASSUME_YES=0
DRY_RUN=0
RECOVERY_TIMEOUT=${RECOVERY_TIMEOUT:-600}

usage() { grep '^#' "$0" | sed -n '3,25p' | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --server)        SERVER="$2"; shift 2;;
        --backup-id)     BACKUP_ID="$2"; shift 2;;
        --target-node)   TARGET_NODE="$2"; shift 2;;
        --target-time)   TARGET_TIME="$2"; TARGET_TYPE="time"; shift 2;;
        --target-xid)    TARGET_XID="$2"; TARGET_TYPE="xid"; shift 2;;
        --target-name)   TARGET_NAME="$2"; TARGET_TYPE="name"; shift 2;;
        --target-type)   TARGET_TYPE="$2"; shift 2;;
        --target-action) TARGET_ACTION="$2"; shift 2;;
        --yes)           ASSUME_YES=1; shift;;
        --dry-run)       DRY_RUN=1; shift;;
        -h|--help)       usage;;
        *) die "Unknown argument: $1 (see --help)";;
    esac
done

# ── Node inventory (leader first) ──
NODES=($(podman ps --format '{{.Names}}' | grep -E '^db[0-9]+$' | sort))
[ ${#NODES[@]} -ge 1 ] || die "No running db nodes found"

current_leader() {
    timeout 10 podman exec "${NODES[0]}" patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
        | awk '$4=="Leader"||$4=="primary"{print $2}' | head -1
}

# ── Interactive selection when unspecified ──
if [ -z "$SERVER" ]; then
    msg "${CYAN}Stanzas / available backups:${NC}"
    for n in "${NODES[@]}"; do
        cnt=$(timeout 20 podman exec -u backup backup sh -c \
            "pgbackrest --stanza=$n --output=json info 2>/dev/null" \
            | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d[0].get("backup",[])))' 2>/dev/null || echo 0)
        msg "  $n  (${cnt} backup(s))"
    done
    read -rp "Source stanza/server [default: $(current_leader || echo ${NODES[0]})]: " SERVER
    SERVER="${SERVER:-$(current_leader || echo ${NODES[0]})}"
fi

case " ${NODES[*]} " in *" $SERVER "*) ;; *) die "$SERVER is not a running node";; esac

# ── Resolve backup id ──
list_backups() {
    local json
    json=$(timeout 30 podman exec -u backup backup sh -c \
        "pgbackrest --stanza=$1 --output=json info" 2>/dev/null) || return 0
    [ -n "$json" ] || return 0
    printf '%s' "$json" | python3 -c '
import json, sys, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for b in d[0].get("backup", []):
    ts = b.get("timestamp", {}).get("stop")
    if isinstance(ts, list):
        ts = ts[0]
    human = datetime.datetime.fromtimestamp(
        int(ts), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S") if ts else "?"
    print("%-32s %-6s end=%s" % (b["label"], b["type"], human))
'
}

if [ -z "$BACKUP_ID" ]; then
    mapfile -t BL < <(list_backups "$SERVER")
    [ ${#BL[@]} -gt 0 ] || die "No backups found for stanza $SERVER — run make backup first"
    msg "${CYAN}Backups for $SERVER:${NC}"
    i=1
    for l in "${BL[@]}"; do msg "  $i) $l"; i=$((i+1)); done
    msg "  ${i}) latest"
    read -rp "Backup # [default: latest]: " PICK
    if [ -z "$PICK" ] || [ "$PICK" = "$i" ]; then
        BACKUP_ID=$(echo "${BL[-1]}" | awk '{print $1}')
    else
        [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le ${#BL[@]} ] \
            || die "invalid selection"
        BACKUP_ID=$(echo "${BL[$((PICK-1))]}" | awk '{print $1}')
    fi
fi

# Validate label exists
timeout 20 podman exec -u backup backup sh -c "pgbackrest --stanza=$SERVER info" 2>/dev/null \
    | grep -q "$BACKUP_ID" || die "Backup $BACKUP_ID not found in stanza $SERVER"

TARGET_NODE="${TARGET_NODE:-$SERVER}"
case " ${NODES[*]} " in *" $TARGET_NODE "*) ;; *) die "$TARGET_NODE is not a running node";; esac

# ── Target spec ──
TARGET_ARGS=(--set="$BACKUP_ID" "--target-action=$TARGET_ACTION")
case "$TARGET_TYPE" in
    time)      [ -n "$TARGET_TIME" ] || { read -rp "Target time ('YYYY-MM-DD HH:MM:SS', UTC): " TARGET_TIME; }
               [ -n "$TARGET_TIME" ] || die "target time required"
               TARGET_ARGS+=(--type=time "--target=$TARGET_TIME");;
    xid)       [ -n "$TARGET_XID" ] || die "--target-xid required"
               TARGET_ARGS+=(--type=xid "--xid=$TARGET_XID");;
    name)      [ -n "${TARGET_NAME:-}" ] || die "--target-name required"
               TARGET_ARGS+=(--type=name "--target=$TARGET_NAME");;
    immediate) TARGET_ARGS+=(--type=immediate);;
    *)         die "bad --target-type";;
esac

LEADER_NOW="$(current_leader || true)"
DATA_DIR=$(timeout 10 podman exec "$TARGET_NODE" \
    sed -n "/^\[$SERVER\]/,/^\[/p" /etc/pgbackrest/pgbackrest.conf 2>/dev/null \
    | grep '^pg1-path' | head -1 | awk '{print $2}')
DATA_DIR="${DATA_DIR:-/var/lib/postgresql/18/maborak}"

# ── Plan ──
msg ""
msg "${CYAN}══════════ PITR PLAN ══════════${NC}"
msg "  Source stanza   : $SERVER (backup $BACKUP_ID)"
msg "  Target node     : $TARGET_NODE"
msg "  Data directory  : $DATA_DIR"
msg "  Target          : type=$TARGET_TYPE ${TARGET_TIME:+time=$TARGET_TIME}${TARGET_XID:+xid=$TARGET_XID}${TARGET_NAME:+name=$TARGET_NAME}"
msg "  On completion   : $TARGET_ACTION"
[ "$TARGET_NODE" = "$LEADER_NOW" ] && warn "$TARGET_NODE is the CURRENT LEADER — expect a failover during restore!"
warn "The restored instance forks history at the target instant. If other nodes kept advancing past it, do NOT let them follow this node without a deliberate plan."
msg ""

[ "$ASSUME_YES" = 1 ] || { read -rp "Proceed? Type 'yes' to continue: " R; [ "$R" = "yes" ] || die "aborted by user"; }

if [ "$DRY_RUN" = 1 ]; then
    msg "${CYAN}Dry run — would execute:${NC}"
    msg "  podman exec $TARGET_NODE supervisorctl stop patroni"
    msg "  podman exec $TARGET_NODE mv $DATA_DIR ${DATA_DIR}.pre-pitr.\$(date +%s)"
    msg "  podman exec -u postgres $TARGET_NODE pgbackrest --stanza=$SERVER \\"
    msg "      ${TARGET_ARGS[*]} restore"
    msg "  podman exec $TARGET_NODE supervisorctl start patroni"
    exit 0
fi

# ── Execute ──
msg "${CYAN}[1/5] Stopping Patroni on $TARGET_NODE${NC}"
podman exec "$TARGET_NODE" supervisorctl stop patroni >/dev/null 2>&1 \
    && ok "Patroni stopped" || warn "Patroni already stopped"
sleep 3

msg "${CYAN}[2/5] Preserving current data directory${NC}"
STAMP=$(date +%Y%m%dT%H%M%S)
timeout 60 podman exec "$TARGET_NODE" sh -c \
    "mv $DATA_DIR ${DATA_DIR}.pre-pitr.$STAMP && mkdir -p $DATA_DIR && chmod 700 $DATA_DIR && chown postgres:postgres $DATA_DIR" \
    && ok "Old data moved to ${DATA_DIR}.pre-pitr.$STAMP" \
    || die "could not relocate $DATA_DIR"

msg "${CYAN}[3/5] Running pgBackRest restore${NC}"
RESTORE_ARGS_Q=$(printf '%q ' "${TARGET_ARGS[@]}")
if podman exec -u postgres "$TARGET_NODE" sh -c \
    "pgbackrest --stanza=$SERVER --log-level-console=info $RESTORE_ARGS_Q restore" \
    > /dev/null 2>&1;
then
    ok "Restore completed"
else
    die "pgbackrest restore failed — check /var/log/pgbackrest/ inside $TARGET_NODE and repo-side logs on 'backup'"
fi

msg "${CYAN}[4/5] Starting Patroni${NC}"
podman exec "$TARGET_NODE" supervisorctl start patroni >/dev/null 2>&1 \
    && ok "Patroni started" || die "failed to start Patroni"

msg "${CYAN}[5/5] Waiting for replay to reach target (max ${RECOVERY_TIMEOUT}s)${NC}"
ELAPSED=0
while [ $ELAPSED -lt $RECOVERY_TIMEOUT ]; do
    STATE=$(timeout 8 podman exec "$TARGET_NODE" psql -U postgres -h 127.0.0.1 -p 5431 -tAc \
        "select case when pg_is_in_recovery() then 'recovery:'||coalesce(pg_last_wal_replay_lsn()::text,'?') else 'promoted' end" 2>/dev/null || echo "starting")
    msg "  [$ELAPSED s] $STATE"
    [ "$STATE" = "promoted" ] && break
    sleep 15; ELAPSED=$((ELAPSED+15))
done

if [ "$STATE" = "promoted" ]; then
    ok "PITR complete: $TARGET_NODE recovered to the requested target and promoted"
else
    warn "Target not confirmed within ${RECOVERY_TIMEOUT}s (last state: $STATE). Check: podman logs $TARGET_NODE / patronictl list"
fi

msg ""
msg "${CYAN}Post-recovery checklist:${NC}"
msg "  • Old data preserved at: ${DATA_DIR}.pre-pitr.$STAMP (delete when satisfied)"
msg "  • If this was full-cluster DR: re-bootstrap or pgbackrest-restore remaining nodes from the same backup set."
msg "  • If salvaging: extract needed rows now — the fork point makes future rejoins non-trivial."
