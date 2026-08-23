#!/bin/bash
# scripts/ops/switchover_to_remote.sh
# ============================================================================
# Cross-cluster switchover: Mac (primary) → Remote (new primary)
#
# Automates the manual procedure in docs/switchover.md Section A. After
# successful run, Mac is a standby of Remote.
#
# Usage:
#   bash scripts/ops/switchover_to_remote.sh [--yes] [--dry-run] [--skip-backup]
#   make switchover-to-remote [YES=1] [DRY_RUN=1] [SKIP_BACKUP=1]
#
# Required env vars (in .env):
#   REMOTE_SSH_HOST, REMOTE_SSH_USER, REMOTE_PATRONI_CONFIG,
#   REMOTE_PATRONI_SERVICE, REMOTE_PG_BIN, REMOTE_PG_PORT, REMOTE_PG_SOCKET_DIR,
#   REMOTE_HAPROXY_HOST, REMOTE_HAPROXY_WRITE_PORT, REMOTE_HAPROXY_READ_PORT
#
# Optional env vars (in .env):
#   APP_ROLES="role1 role2"  (space-separated; REVOKE+GRANT will operate on these)
#   STANDBY_REMOTE_SLOT_NAME (default: standby_remote)
#   MAC_STANDBY_SLOT_NAME    (default: mac_standby)
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=./lib/cross_cluster.sh
source "$SCRIPT_DIR/lib/cross_cluster.sh"

DRY_RUN=0
YES=0
SKIP_BACKUP=0

print_help() {
    cat <<EOF
Usage: $0 [options]

Cross-cluster switchover: Mac (current primary) → Remote (new primary).
Implements docs/switchover.md Section A end-to-end.

Options:
  --yes          Skip all interactive confirmations (still respects --dry-run)
  --dry-run      Print every mutating command without executing it
  --skip-backup  Skip the pre-switch Backup backup recommendation
  -h, --help     Show this help

Env (override via .env):
  REMOTE_SSH_HOST              Remote primary host  (current: ${REMOTE_SSH_HOST:-UNSET})
  REMOTE_HAPROXY_HOST          Remote HAProxy host  (current: ${REMOTE_HAPROXY_HOST:-UNSET})
  REMOTE_HAPROXY_WRITE_PORT    Remote write port    (current: ${REMOTE_HAPROXY_WRITE_PORT:-UNSET})
  APP_ROLES                    App roles to REVOKE  (current: '${APP_ROLES:-}')

After successful run, repoint apps from Mac endpoints to:
  ${REMOTE_HAPROXY_HOST:-?}:${REMOTE_HAPROXY_WRITE_PORT:-?}  (writes)
  ${REMOTE_HAPROXY_HOST:-?}:${REMOTE_HAPROXY_READ_PORT:-?}  (reads)
EOF
}

# ---------- Parse args ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --yes)         YES=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --skip-backup) SKIP_BACKUP=1 ;;
        -h|--help)     print_help; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; print_help; exit 1 ;;
    esac
    shift
done

export YES DRY_RUN

# ---------- Cleanup hook ----------
# We DON'T auto-rollback DCS edits — they're load-bearing and partial rollback
# could land us in a worse state. We just print a clear status if we exit early.
SCRIPT_PHASE="init"
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "" >&2
        echo -e "${RED}${BOLD}════ SWITCHOVER ABORTED at phase: $SCRIPT_PHASE ════${NC}" >&2
        echo -e "${RED}Exit code: $rc${NC}" >&2
        echo "" >&2
        case "$SCRIPT_PHASE" in
            preflight|paused|writeblock|lagdrain)
                echo "Cluster is INTACT. To unwind: resume Mac Patroni and lift write-block:" >&2
                echo "  docker exec db1 patronictl -c /etc/patroni/patroni.yml resume patroni1" >&2
                echo "  docker exec db1 psql -U postgres -d $DEFAULT_DATABASE -c \"ALTER DATABASE $DEFAULT_DATABASE RESET default_transaction_read_only;\"" >&2
                if [ -n "${APP_ROLES:-}" ]; then
                    echo "  + GRANT CONNECT back to: $APP_ROLES" >&2
                fi
                ;;
            promote_remote|grant_remote|drop_slot|create_slot|edit_mac_dcs|resume_mac)
                echo "Cluster is in a TRANSITIONAL state — see docs/switchover.md §C." >&2
                echo "Current likely state:" >&2
                echo "  - Remote may already be the new primary (check: ssh root@$REMOTE_SSH_HOST 'patronictl -c $REMOTE_PATRONI_CONFIG list')" >&2
                echo "  - Mac may be paused, not-yet-reconfigured, or partially streaming" >&2
                echo "  - Apps will fail to write to Mac" >&2
                echo "" >&2
                echo "DO NOT manually wipe data dirs. Use 'patronictl reinit' if a node needs rebuild." >&2
                ;;
        esac
    fi
}
trap on_exit EXIT

# ============================================================================
# Banner
# ============================================================================
banner "Cross-Cluster Switchover: Mac → Remote (forward)"
log "Settings: DRY_RUN=$DRY_RUN  YES=$YES  SKIP_BACKUP=$SKIP_BACKUP"
log "App roles to manage: '${APP_ROLES:-<none>}'"
log "Database: $DEFAULT_DATABASE"

# ============================================================================
# Phase 0 — Preflight
# ============================================================================
SCRIPT_PHASE="preflight"
step "Phase 0 — Preflight"

require_cross_cluster_config
preflight_current_primary mac
preflight_identity
preflight_pg_version
preflight_sync_commit

# Verify the standby_remote slot exists and is active
log "Checking that '$STANDBY_REMOTE_SLOT_NAME' slot on Mac is healthy..."
SLOT_INFO=$(mac_psql_value postgres "
    SELECT active::text || '|' || COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn), 0)
    FROM pg_replication_slots WHERE slot_name='$STANDBY_REMOTE_SLOT_NAME';" 2>/dev/null || echo "")
if [ -z "$SLOT_INFO" ]; then
    fatal "Slot '$STANDBY_REMOTE_SLOT_NAME' does not exist on Mac. Remote may not be streaming from us."
fi
SLOT_ACTIVE="${SLOT_INFO%%|*}"
SLOT_UNCONFIRMED="${SLOT_INFO##*|}"
if [ "$SLOT_ACTIVE" != "t" ] && [ "$SLOT_ACTIVE" != "true" ]; then
    fatal "Slot '$STANDBY_REMOTE_SLOT_NAME' exists but is INACTIVE — remote is not streaming. Refusing to switch."
fi
log "Slot active, unconfirmed bytes: $SLOT_UNCONFIRMED"
ok "Preflight passed"

# ============================================================================
# Phase 1 — Backup recommendation
# ============================================================================
if [ "$SKIP_BACKUP" -ne 1 ]; then
    step "Phase 1 — Pre-switch Backup backup (recommended)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[DRY-RUN] Would prompt to run 'make backup SERVER=db1'"
    else
        warn "Strongly recommended: take a fresh backup before switching."
        warn "Run in another shell:  ${BOLD}make backup SERVER=db1${NC}"
        if ! confirm "Have you taken a fresh backup (or accept the risk of skipping)?"; then
            fatal "Aborted by operator. Re-run with --skip-backup to skip this gate."
        fi
    fi
fi

# ============================================================================
# Phase 2 — Apps must be stopped/repointed-pending
# ============================================================================
SCRIPT_PHASE="preflight"
step "Phase 2 — App quiescence"
warn "Stop all writing applications NOW (or repoint them to a maintenance page)."
warn "Section A.1.5 will hard-block writes too, but applications should be stopped."
if ! confirm "Are applications stopped or repointed?"; then
    fatal "Aborted by operator. Stop apps before retrying."
fi

# ============================================================================
# Phase 3 — Pause Mac Patroni (no failover races)
# ============================================================================
SCRIPT_PHASE="paused"
step "Phase 3 — Pause Mac Patroni"
log "Running: patronictl pause patroni1 on Mac"
if ! dry_run_echo "patronictl pause patroni1"; then
    mac_patronictl pause patroni1 >/dev/null
fi
ok "Mac Patroni paused (auto-failover disabled)"

# ============================================================================
# Phase 4 — Hard write-block (CATALOG-LEVEL, replicates to remote)
# ============================================================================
SCRIPT_PHASE="writeblock"
step "Phase 4 — Write-block Mac (catalog-level, WAL-replicated to remote)"
mac_write_block

# Verify writes are blocked on every protected database
if [ "${DRY_RUN:-0}" != "1" ]; then
    USER_DBS=$(mac_user_databases)
    log "Verifying writes are blocked on each user db: $USER_DBS"
    for db in $USER_DBS; do
        if mac_psql "$db" -c "CREATE TABLE _switchover_writeblock_test (x int);" 2>&1 | grep -q "read-only"; then
            ok "  $db: writes blocked"
        else
            mac_psql "$db" -c "DROP TABLE IF EXISTS _switchover_writeblock_test;" >/dev/null 2>&1 || true
            fatal "Write-block VERIFICATION FAILED on $db: CREATE TABLE did not error with read-only."
        fi
    done
fi

# ============================================================================
# Phase 5 — Force WAL flush + wait lag to zero
# ============================================================================
SCRIPT_PHASE="lagdrain"
step "Phase 5 — Drive WAL to zero lag"
mac_checkpoint_and_switch_wal
wait_for_zero_lag "Mac→Remote" mac_replay_lag_bytes

# ============================================================================
# Phase 6 — POINT OF NO RETURN — promote remote
# ============================================================================
SCRIPT_PHASE="promote_remote"
step "Phase 6 — Promote Remote (POINT OF NO RETURN)"
warn "Next step removes standby_cluster: from remote DCS. Remote will become a writeable primary."
warn "After this, only the reverse switchover (switchover_from_remote.sh) returns Mac to primary."
if ! confirm_typing "PROMOTE-REMOTE"; then
    fatal "Aborted by operator at the point-of-no-return gate."
fi

log "Fetching remote DCS config..."
REMOTE_CONFIG=$(remote_dcs_get)
if echo "$REMOTE_CONFIG" | json_has_standby_cluster; then
    log "Remote DCS has standby_cluster — removing it"
    NEW_REMOTE_CONFIG=$(echo "$REMOTE_CONFIG" | json_remove_standby_cluster)
    echo "$NEW_REMOTE_CONFIG" | remote_dcs_put
    ok "Remote DCS updated (standby_cluster removed)"
else
    warn "Remote DCS already lacks standby_cluster — already promoted? Continuing."
fi

wait_for_role remote "Leader"

# Verify pg_is_in_recovery=f on remote
if [ "${DRY_RUN:-0}" != "1" ]; then
    REMOTE_INREC=$(remote_psql_value postgres "SELECT pg_is_in_recovery();" 2>/dev/null)
    [ "$REMOTE_INREC" = "f" ] || fatal "Remote pg_is_in_recovery=$REMOTE_INREC after promote — expected 'f'."
    ok "Remote is now writeable primary (pg_is_in_recovery=f)"
fi

# ============================================================================
# Phase 7 — Restore app access on the new primary (remote)
# ============================================================================
SCRIPT_PHASE="grant_remote"
step "Phase 7 — Lift write-block on Remote (new primary)"
remote_write_unblock

# Verify writes work on every user database
if [ "${DRY_RUN:-0}" != "1" ]; then
    USER_DBS=$(remote_user_databases)
    log "Verifying writes succeed on each user db: $USER_DBS"
    for db in $USER_DBS; do
        if remote_psql "$db" -c "CREATE TABLE _switchover_writeunblock_test (x int); DROP TABLE _switchover_writeunblock_test;" >/dev/null 2>&1; then
            ok "  $db: writes succeed"
        else
            fatal "Write verification FAILED on $db. Apps cannot use the new primary. Investigate."
        fi
    done
fi

# ============================================================================
# Phase 8 — Slot dance
# ============================================================================
SCRIPT_PHASE="drop_slot"
step "Phase 8 — Manage replication slots"
mac_drop_slot "$STANDBY_REMOTE_SLOT_NAME"

SCRIPT_PHASE="create_slot"
remote_create_slot "$MAC_STANDBY_SLOT_NAME"

# ============================================================================
# Phase 9 — Add standby_cluster to Mac DCS
# ============================================================================
SCRIPT_PHASE="edit_mac_dcs"
step "Phase 9 — Configure Mac as standby of Remote"
log "Fetching Mac DCS config..."
MAC_CONFIG=$(mac_dcs_get)
log "Adding standby_cluster: host=$REMOTE_HAPROXY_HOST port=$REMOTE_HAPROXY_WRITE_PORT slot=$MAC_STANDBY_SLOT_NAME"
NEW_MAC_CONFIG=$(echo "$MAC_CONFIG" | json_add_standby_cluster \
    "$REMOTE_HAPROXY_HOST" "$REMOTE_HAPROXY_WRITE_PORT" "$MAC_STANDBY_SLOT_NAME")
echo "$NEW_MAC_CONFIG" | mac_dcs_put
ok "Mac DCS updated"

# ============================================================================
# Phase 10 — Resume Mac Patroni
# ============================================================================
SCRIPT_PHASE="resume_mac"
step "Phase 10 — Resume Mac Patroni"
if ! dry_run_echo "patronictl resume patroni1 on Mac"; then
    mac_patronictl resume patroni1 >/dev/null
fi
ok "Mac Patroni resumed"

log "Waiting for Mac to elect a Standby Leader..."
wait_for_role mac "Standby Leader"

log "Mac is now following Remote. Patroni may run pg_rewind on the new Standby Leader."
log "Watch progress: docker logs db1 2>&1 | tail -100 | grep -E 'rewind|standby|primary_conninfo|streaming'"

# ============================================================================
# Phase 11 — Confirm replication established
# ============================================================================
step "Phase 11 — Verify streaming from Remote → Mac"
log "Polling remote for active mac_standby slot (up to ${SWITCHOVER_STREAM_TIMEOUT}s)..."
elapsed=0
while [ "$elapsed" -lt "$SWITCHOVER_STREAM_TIMEOUT" ]; do
    ACTIVE=$(remote_psql_value postgres "
        SELECT active FROM pg_replication_slots WHERE slot_name='$MAC_STANDBY_SLOT_NAME';" 2>/dev/null || echo "")
    if [ "$ACTIVE" = "t" ]; then
        ok "Remote sees Mac's slot '$MAC_STANDBY_SLOT_NAME' as active"
        break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
done
if [ "$ACTIVE" != "t" ]; then
    warn "Stream not yet established within ${SWITCHOVER_STREAM_TIMEOUT}s. This is common during pg_rewind."
    warn "Monitor: docker logs db1 2>&1 | tail -200"
    warn "Cluster IS in correct config — pg_rewind/basebackup may just be slow."
fi

# ============================================================================
# Done
# ============================================================================
SCRIPT_PHASE="done"
banner "SWITCHOVER COMPLETE — Remote is now PRIMARY"
log "Update apps to use the Remote endpoints:"
print_endpoint_card remote

log "Update docs/switchover.md §F validation log with date / wall-clock time / notes."
