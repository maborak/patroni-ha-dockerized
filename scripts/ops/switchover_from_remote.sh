#!/bin/bash
# scripts/ops/switchover_from_remote.sh
# ============================================================================
# Cross-cluster switchover: Remote (primary) → Mac (new primary)
#
# Automates the manual procedure in docs/switchover.md Section B. After
# successful run, Remote is a standby of Mac.
#
# Usage:
#   bash scripts/ops/switchover_from_remote.sh [--yes] [--dry-run] [--skip-backup]
#   make switchover-from-remote [YES=1] [DRY_RUN=1] [SKIP_BACKUP=1]
#
# Required env vars (in .env): see switchover_to_remote.sh.
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

Cross-cluster switchover: Remote (current primary) → Mac (new primary).
Implements docs/switchover.md Section B end-to-end.

Options:
  --yes          Skip all interactive confirmations
  --dry-run      Print every mutating command without executing it
  --skip-backup  Skip the pre-switch Barman backup recommendation
  -h, --help     Show this help

After successful run, repoint apps from Remote back to:
  ${MAC_VPN_HOST:-?}:${HAPROXY_WRITE_PORT:-?}  (writes)
EOF
}

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
                echo "Cluster is INTACT. To unwind: resume Remote Patroni and lift write-block:" >&2
                echo "  ssh root@$REMOTE_SSH_HOST 'patronictl -c $REMOTE_PATRONI_CONFIG resume $REMOTE_PATRONI_SERVICE'" >&2
                echo "  ssh root@$REMOTE_SSH_HOST 'sudo -u postgres $REMOTE_PG_BIN/psql -h $REMOTE_PG_SOCKET_DIR -p $REMOTE_PG_PORT -d $DEFAULT_DATABASE -c \"ALTER DATABASE $DEFAULT_DATABASE RESET default_transaction_read_only;\"'" >&2
                if [ -n "${APP_ROLES:-}" ]; then
                    echo "  + GRANT CONNECT back to: $APP_ROLES" >&2
                fi
                ;;
            promote_mac|grant_mac|drop_slot|create_slot|edit_remote_dcs|resume_remote)
                echo "Cluster is in a TRANSITIONAL state — see docs/switchover.md §C." >&2
                echo "Check both sides:" >&2
                echo "  docker exec db1 patronictl -c /etc/patroni/patroni.yml list" >&2
                echo "  ssh root@$REMOTE_SSH_HOST 'patronictl -c $REMOTE_PATRONI_CONFIG list'" >&2
                echo "" >&2
                echo "DO NOT manually wipe data dirs. Use 'patronictl reinit' if needed." >&2
                ;;
        esac
    fi
}
trap on_exit EXIT

# ============================================================================
banner "Cross-Cluster Switchover: Remote → Mac (reverse)"
log "Settings: DRY_RUN=$DRY_RUN  YES=$YES  SKIP_BACKUP=$SKIP_BACKUP"
log "App roles to manage: '${APP_ROLES:-<none>}'"
log "Database: $DEFAULT_DATABASE"

# ============================================================================
# Phase 0 — Preflight
# ============================================================================
SCRIPT_PHASE="preflight"
step "Phase 0 — Preflight"

require_cross_cluster_config
preflight_current_primary remote
preflight_identity
preflight_pg_version
preflight_sync_commit

log "Checking that '$MAC_STANDBY_SLOT_NAME' slot on Remote is healthy..."
SLOT_INFO=$(remote_psql_value postgres "
    SELECT active::text || '|' || COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn), 0)
    FROM pg_replication_slots WHERE slot_name='$MAC_STANDBY_SLOT_NAME';" 2>/dev/null || echo "")
if [ -z "$SLOT_INFO" ]; then
    fatal "Slot '$MAC_STANDBY_SLOT_NAME' does not exist on Remote. Mac may not be streaming from remote."
fi
SLOT_ACTIVE="${SLOT_INFO%%|*}"
if [ "$SLOT_ACTIVE" != "t" ] && [ "$SLOT_ACTIVE" != "true" ]; then
    fatal "Slot '$MAC_STANDBY_SLOT_NAME' is INACTIVE — Mac is not streaming. Refusing to switch."
fi
ok "Preflight passed"

# ============================================================================
# Phase 1 — Backup recommendation
# ============================================================================
if [ "$SKIP_BACKUP" -ne 1 ]; then
    step "Phase 1 — Pre-switch backup (recommended)"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[DRY-RUN] Would prompt for fresh backup of remote"
    else
        warn "Strongly recommended: take a fresh backup before switching."
        warn "Remote-side backups are not managed by this stack's barman."
        warn "Use whatever backup mechanism is configured on remote (pg_basebackup, separate barman, etc.)"
        if ! confirm "Have you taken a fresh backup (or accept the risk of skipping)?"; then
            fatal "Aborted by operator. Re-run with --skip-backup to skip this gate."
        fi
    fi
fi

# ============================================================================
# Phase 2 — App quiescence
# ============================================================================
SCRIPT_PHASE="preflight"
step "Phase 2 — App quiescence"
warn "Stop all writing applications NOW (or repoint them)."
warn "Section B.1.5 will hard-block writes too, but applications should be stopped."
if ! confirm "Are applications stopped or repointed?"; then
    fatal "Aborted by operator. Stop apps before retrying."
fi

# ============================================================================
# Phase 3 — Pause Remote Patroni
# ============================================================================
SCRIPT_PHASE="paused"
step "Phase 3 — Pause Remote Patroni"
log "Running: patronictl pause $REMOTE_PATRONI_SERVICE on remote"
if ! dry_run_echo "Remote patronictl pause $REMOTE_PATRONI_SERVICE"; then
    remote_patronictl pause "$REMOTE_PATRONI_SERVICE" >/dev/null
fi
ok "Remote Patroni paused"

# ============================================================================
# Phase 4 — Hard write-block (catalog-level, replicates to Mac)
# ============================================================================
SCRIPT_PHASE="writeblock"
step "Phase 4 — Write-block Remote (catalog-level, WAL-replicated to Mac)"
remote_write_block

if [ "${DRY_RUN:-0}" != "1" ]; then
    USER_DBS=$(remote_user_databases)
    log "Verifying writes are blocked on each user db: $USER_DBS"
    for db in $USER_DBS; do
        if remote_psql "$db" -c "CREATE TABLE _switchover_writeblock_test (x int);" 2>&1 | grep -q "read-only"; then
            ok "  $db: writes blocked"
        else
            remote_psql "$db" -c "DROP TABLE IF EXISTS _switchover_writeblock_test;" >/dev/null 2>&1 || true
            fatal "Write-block VERIFICATION FAILED on $db on Remote."
        fi
    done
fi

# ============================================================================
# Phase 5 — Drive WAL to zero
# ============================================================================
SCRIPT_PHASE="lagdrain"
step "Phase 5 — Drive WAL to zero lag"
remote_checkpoint_and_switch_wal
wait_for_zero_lag "Remote→Mac" remote_replay_lag_bytes

# ============================================================================
# Phase 6 — POINT OF NO RETURN — promote Mac
# ============================================================================
SCRIPT_PHASE="promote_mac"
step "Phase 6 — Promote Mac (POINT OF NO RETURN)"
warn "Next step removes standby_cluster: from Mac DCS. Mac becomes a writeable primary."
warn "After this, only switchover_to_remote.sh returns Remote to primary."
if ! confirm_typing "PROMOTE-MAC"; then
    fatal "Aborted by operator at the point-of-no-return gate."
fi

log "Fetching Mac DCS config..."
MAC_CONFIG=$(mac_dcs_get)
if echo "$MAC_CONFIG" | json_has_standby_cluster; then
    log "Mac DCS has standby_cluster — removing it"
    NEW_MAC_CONFIG=$(echo "$MAC_CONFIG" | json_remove_standby_cluster)
    echo "$NEW_MAC_CONFIG" | mac_dcs_put
    ok "Mac DCS updated (standby_cluster removed)"
else
    warn "Mac DCS already lacks standby_cluster — already promoted? Continuing."
fi

wait_for_role mac "Leader"

if [ "${DRY_RUN:-0}" != "1" ]; then
    MAC_INREC=$(mac_psql_value postgres "SELECT pg_is_in_recovery();" 2>/dev/null)
    [ "$MAC_INREC" = "f" ] || fatal "Mac pg_is_in_recovery=$MAC_INREC after promote — expected 'f'."
    ok "Mac is now writeable primary (pg_is_in_recovery=f)"
fi

# ============================================================================
# Phase 7 — Restore app access on new primary (Mac)
# ============================================================================
SCRIPT_PHASE="grant_mac"
step "Phase 7 — Lift write-block on Mac (new primary)"
mac_write_unblock

if [ "${DRY_RUN:-0}" != "1" ]; then
    USER_DBS=$(mac_user_databases)
    log "Verifying writes succeed on each user db: $USER_DBS"
    for db in $USER_DBS; do
        if mac_psql "$db" -c "CREATE TABLE _switchover_writeunblock_test (x int); DROP TABLE _switchover_writeunblock_test;" >/dev/null 2>&1; then
            ok "  $db: writes succeed"
        else
            fatal "Write verification FAILED on $db. Apps cannot use the new primary."
        fi
    done
fi

# ============================================================================
# Phase 8 — Slot dance
# ============================================================================
SCRIPT_PHASE="drop_slot"
step "Phase 8 — Manage replication slots"
remote_drop_slot "$MAC_STANDBY_SLOT_NAME"

SCRIPT_PHASE="create_slot"
mac_create_slot "$STANDBY_REMOTE_SLOT_NAME"

# ============================================================================
# Phase 9 — Add standby_cluster to Remote DCS
# ============================================================================
SCRIPT_PHASE="edit_remote_dcs"
step "Phase 9 — Configure Remote as standby of Mac"
log "Fetching Remote DCS config..."
REMOTE_CONFIG=$(remote_dcs_get)
log "Adding standby_cluster: host=$MAC_VPN_HOST port=$HAPROXY_WRITE_PORT slot=$STANDBY_REMOTE_SLOT_NAME"
NEW_REMOTE_CONFIG=$(echo "$REMOTE_CONFIG" | json_add_standby_cluster \
    "$MAC_VPN_HOST" "$HAPROXY_WRITE_PORT" "$STANDBY_REMOTE_SLOT_NAME")
echo "$NEW_REMOTE_CONFIG" | remote_dcs_put
ok "Remote DCS updated"

# ============================================================================
# Phase 10 — Resume Remote Patroni
# ============================================================================
SCRIPT_PHASE="resume_remote"
step "Phase 10 — Resume Remote Patroni"
if ! dry_run_echo "Remote patronictl resume $REMOTE_PATRONI_SERVICE"; then
    remote_patronictl resume "$REMOTE_PATRONI_SERVICE" >/dev/null
fi
ok "Remote Patroni resumed"

log "Waiting for Remote to elect a Standby Leader..."
wait_for_role remote "Standby Leader"

# ============================================================================
# Phase 11 — Verify streaming
# ============================================================================
step "Phase 11 — Verify streaming from Mac → Remote"
log "Polling Mac for active $STANDBY_REMOTE_SLOT_NAME slot (up to ${SWITCHOVER_STREAM_TIMEOUT}s)..."
elapsed=0
ACTIVE=""
while [ "$elapsed" -lt "$SWITCHOVER_STREAM_TIMEOUT" ]; do
    ACTIVE=$(mac_psql_value postgres "
        SELECT active FROM pg_replication_slots WHERE slot_name='$STANDBY_REMOTE_SLOT_NAME';" 2>/dev/null || echo "")
    if [ "$ACTIVE" = "t" ]; then
        ok "Mac sees Remote's slot '$STANDBY_REMOTE_SLOT_NAME' as active"
        break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
done
if [ "$ACTIVE" != "t" ]; then
    warn "Stream not yet established within ${SWITCHOVER_STREAM_TIMEOUT}s. pg_rewind/basebackup may be running on remote."
    warn "Monitor: ssh root@$REMOTE_SSH_HOST 'journalctl -u $REMOTE_PATRONI_SERVICE -n 200 --no-pager'"
fi

# ============================================================================
# Done
# ============================================================================
SCRIPT_PHASE="done"
banner "SWITCHOVER COMPLETE — Mac is now PRIMARY"
log "Update apps to use the Mac endpoints:"
print_endpoint_card mac
log "Update docs/switchover.md §F validation log."
