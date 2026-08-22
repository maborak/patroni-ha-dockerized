#!/bin/bash
# scripts/ops/lib/cross_cluster.sh — Shared helpers for cross-cluster switchover
#
# Source AFTER scripts/lib/common.sh. Provides:
#   * Mac-side (mac_*) and remote-side (remote_*) wrappers around psql/patronictl
#   * DCS get/set helpers (REST API + python3 for JSON mutation)
#   * Lag/health/identity preflight checks
#   * Atomic write-block / write-unblock (catalog-level, WAL-replicated)
#
# Conventions:
#   * Read-only functions print to stdout. Mutating functions print progress
#     to stderr and exit nonzero on failure.
#   * All remote commands go through SSH (REMOTE_SSH_HOST / REMOTE_SSH_USER)
#     to match the runbook pattern and avoid relying on the remote Patroni
#     REST API being reachable from the Mac.
#   * No `((var++))` standalone (set -e landmine). Use var=$((var + 1)).

# ============================================================================
# Required env vars (validated by require_cross_cluster_config)
# ============================================================================
# REMOTE_SSH_HOST, REMOTE_SSH_USER, REMOTE_PATRONI_CONFIG,
# REMOTE_PATRONI_SERVICE, REMOTE_PG_BIN, REMOTE_PG_PORT, REMOTE_PG_SOCKET_DIR,
# REMOTE_HAPROXY_HOST, REMOTE_HAPROXY_WRITE_PORT, REMOTE_HAPROXY_READ_PORT,
# MAC_VPN_HOST, HAPROXY_WRITE_PORT, POSTGRES_PASSWORD, REPLICATOR_PASSWORD,
# DEFAULT_DATABASE
# Optional: STANDBY_REMOTE_SLOT_NAME, MAC_STANDBY_SLOT_NAME, APP_ROLES

# Defaults
: "${STANDBY_REMOTE_SLOT_NAME:=standby_remote}"
: "${MAC_STANDBY_SLOT_NAME:=mac_standby}"
: "${APP_ROLES:=}"

# Normalize APP_ROLES: replace commas with spaces
APP_ROLES="${APP_ROLES//,/ }"
: "${SWITCHOVER_LAG_POLL_INTERVAL:=10}"   # seconds between lag checks
: "${SWITCHOVER_LAG_POLL_COUNT:=3}"        # consecutive zero readings required
: "${SWITCHOVER_PROMOTE_TIMEOUT:=120}"    # seconds to wait for role flip
: "${SWITCHOVER_STREAM_TIMEOUT:=300}"     # seconds to wait for streaming after resume
: "${REMOTE_HAPROXY_HOST:=192.0.2.10}"
: "${REMOTE_HAPROXY_WRITE_PORT:=5511}"
: "${REMOTE_HAPROXY_READ_PORT:=5521}"
: "${MAC_VPN_HOST:=198.51.100.5}"
: "${HAPROXY_WRITE_PORT:=5551}"

# ============================================================================
# Logging helpers
# ============================================================================
log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
fatal()  { echo -e "${RED}✗ FATAL:${NC} $*" >&2; exit 1; }
step()   { echo -e "\n${BOLD}${BLUE}════ $* ════${NC}\n" >&2; }
banner() { echo -e "\n${BOLD}${MAGENTA}$*${NC}\n" >&2; }

dry_run_echo() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2
        return 0
    fi
    return 1
}

# ============================================================================
# Config validation
# ============================================================================
require_cross_cluster_config() {
    local missing=()
    local var
    for var in REMOTE_SSH_HOST REMOTE_SSH_USER REMOTE_PATRONI_CONFIG \
               REMOTE_PATRONI_SERVICE REMOTE_PG_BIN REMOTE_PG_PORT \
               REMOTE_PG_SOCKET_DIR REMOTE_HAPROXY_HOST REMOTE_HAPROXY_WRITE_PORT \
               REMOTE_HAPROXY_READ_PORT MAC_VPN_HOST HAPROXY_WRITE_PORT \
               POSTGRES_PASSWORD REPLICATOR_PASSWORD DEFAULT_DATABASE; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        fatal "Missing required env vars: ${missing[*]}. Set in .env first."
    fi
}

# ============================================================================
# Confirmation helpers
# ============================================================================
# Usage: confirm "Proceed?" || exit 1
confirm() {
    local prompt="$1"
    if [ "${YES:-0}" = "1" ]; then
        log "[--yes] auto-confirming: $prompt"
        return 0
    fi
    local answer
    printf "%b%s%b (yes/no): " "${YELLOW}" "$prompt" "${NC}" >&2
    read -r answer
    if [ "$answer" = "yes" ]; then
        return 0
    fi
    return 1
}

# Type-to-confirm: requires the operator to type a specific word.
# Usage: confirm_typing "PROMOTE-REMOTE"
confirm_typing() {
    local required="$1"
    if [ "${YES:-0}" = "1" ]; then
        log "[--yes] auto-confirming type-to-confirm: '$required'"
        return 0
    fi
    local answer
    printf "%bType exactly '%s' to proceed:%b " "${YELLOW}${BOLD}" "$required" "${NC}" >&2
    read -r answer
    [ "$answer" = "$required" ]
}

# ============================================================================
# Mac-side wrappers
# ============================================================================

# Run psql on a Mac container as postgres. $1 = db (postgres/maborak/...), rest = psql args.
mac_psql() {
    local db="$1"; shift
    local node
    node=$(detect_leader_api 2>/dev/null) || node="db1"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        docker exec "$node" psql -U postgres -h localhost -p 5431 -d "$db" "$@" 2>/dev/null || return 0
    else
        docker exec "$node" psql -U postgres -h localhost -p 5431 -d "$db" "$@"
    fi
}

# Run a SQL string on Mac with --tuples-only --no-align
mac_psql_value() {
    local db="$1"; local sql="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        # Direct dry-run mocks to ensure full end-to-end dry-run verification
        if [[ "$sql" =~ "system_identifier" ]]; then
            echo "1234567890123456789"
            return 0
        elif [[ "$sql" =~ "server_version_num" ]]; then
            echo "160000"
            return 0
        elif [[ "$sql" =~ "synchronous_commit" ]]; then
            echo "on"
            return 0
        elif [[ "$sql" =~ "pg_is_in_recovery" ]]; then
            if [[ "$0" =~ "switchover_to_remote" ]]; then
                echo "f"
            else
                echo "t"
            fi
            return 0
        elif [[ "$sql" =~ "confirmed_flush_lsn" ]]; then
            echo "t|0"
            return 0
        elif [[ "$sql" =~ "pg_replication_slots" ]]; then
            echo "t"
            return 0
        elif [[ "$sql" =~ "replay_lsn" ]]; then
            echo "0"
            return 0
        fi
    fi
    local val
    val=$(mac_psql "$db" -t -A -c "$sql" 2>/dev/null)
    echo "$val"
}

mac_patronictl() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        docker exec db1 patronictl -c /etc/patroni/patroni.yml "$@" 2>/dev/null || return 0
    else
        docker exec db1 patronictl -c /etc/patroni/patroni.yml "$@"
    fi
}

# Get Mac DCS config as JSON
mac_dcs_get() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo '{"bootstrap":{"dcs":{}}}'
        return 0
    fi
    local val
    val=$(curl -sf "http://localhost:${PATRONI_DB1_API_PORT:-8001}/config" 2>/dev/null)
    echo "$val"
}

# PUT a JSON config back to Mac DCS. Reads from stdin.
mac_dcs_put() {
    local body
    body=$(cat)
    if dry_run_echo "PUT Mac DCS config: $body"; then return 0; fi
    curl -sf -X PUT -H 'Content-Type: application/json' \
         -d "$body" "http://localhost:${PATRONI_DB1_API_PORT:-8001}/config" \
         >/dev/null
}

# ============================================================================
# Remote-side wrappers
# ============================================================================

# Run an arbitrary command on the remote host
remote_run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[DRY-RUN-SSH] ssh $REMOTE_SSH_USER@$REMOTE_SSH_HOST $*"
        ssh -o BatchMode=yes -o ConnectTimeout=3 \
            "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" "$@" 2>/dev/null || return 0
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 \
            "${REMOTE_SSH_USER}@${REMOTE_SSH_HOST}" "$@"
    fi
}

# Run psql on remote as postgres via socket. $1 = db, rest = psql args.
remote_psql() {
    local db="$1"; shift
    local args=""
    local a
    for a in "$@"; do
        args+=" $(printf '%q' "$a")"
    done
    remote_run "sudo -u postgres ${REMOTE_PG_BIN}/psql \
        -h ${REMOTE_PG_SOCKET_DIR} -p ${REMOTE_PG_PORT} -d ${db}${args}"
}

# Run a SQL string on remote with --tuples-only --no-align
remote_psql_value() {
    local db="$1"; local sql="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        # Direct dry-run mocks to ensure full end-to-end dry-run verification
        if [[ "$sql" =~ "system_identifier" ]]; then
            echo "1234567890123456789"
            return 0
        elif [[ "$sql" =~ "server_version_num" ]]; then
            echo "160000"
            return 0
        elif [[ "$sql" =~ "synchronous_commit" ]]; then
            echo "on"
            return 0
        elif [[ "$sql" =~ "pg_is_in_recovery" ]]; then
            if [[ "$0" =~ "switchover_to_remote" ]]; then
                echo "t"
            else
                echo "f"
            fi
            return 0
        elif [[ "$sql" =~ "confirmed_flush_lsn" ]]; then
            echo "t|0"
            return 0
        elif [[ "$sql" =~ "pg_replication_slots" ]]; then
            echo "t"
            return 0
        elif [[ "$sql" =~ "replay_lsn" ]]; then
            echo "0"
            return 0
        fi
    fi
    local val
    val=$(remote_psql "$db" -t -A -c "$sql" 2>/dev/null)
    echo "$val"
}

remote_patronictl() {
    remote_run "patronictl -c ${REMOTE_PATRONI_CONFIG} $*"
}

# Get remote DCS config as JSON (via SSH because API may not be reachable from Mac)
remote_dcs_get() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo '{"bootstrap":{"dcs":{}}}'
        return 0
    fi
    local val
    val=$(remote_run "curl -sf http://localhost:8001/config" 2>/dev/null)
    echo "$val"
}

# PUT a JSON config back to remote DCS. Reads from stdin.
remote_dcs_put() {
    local body
    body=$(cat)
    if dry_run_echo "PUT Remote DCS config: $body"; then return 0; fi
    # Quote the JSON body once for the remote shell
    local quoted
    quoted=$(printf '%q' "$body")
    remote_run "curl -sf -X PUT -H 'Content-Type: application/json' \
        -d $quoted http://localhost:8001/config >/dev/null"
}

# ============================================================================
# JSON helpers (python3 — universally available, no jq dependency)
# ============================================================================

# Add or replace standby_cluster block in DCS JSON (stdin → stdout).
# Args: host port primary_slot_name
json_add_standby_cluster() {
    local host="$1" port="$2" slot="$3"
    python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['standby_cluster'] = {
    'host': sys.argv[1],
    'port': int(sys.argv[2]),
    'primary_slot_name': sys.argv[3],
    'create_replica_methods': ['basebackup'],
}
json.dump(cfg, sys.stdout)
" "$host" "$port" "$slot"
}

# Remove standby_cluster block from DCS JSON (stdin → stdout).
json_remove_standby_cluster() {
    python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg.pop('standby_cluster', None)
json.dump(cfg, sys.stdout)
"
}

# Check whether DCS JSON has standby_cluster set (stdin → exit 0/1)
json_has_standby_cluster() {
    python3 -c "
import json, sys
cfg = json.load(sys.stdin)
sys.exit(0 if cfg.get('standby_cluster') else 1)
"
}

# ============================================================================
# Identity / health preflights
# ============================================================================

# Verify both sides have the same PG cluster identity. Fail-fast on mismatch.
preflight_identity() {
    log "Comparing system_identifier across clusters..."
    local mac_id remote_id
    mac_id=$(mac_psql_value postgres "SELECT system_identifier FROM pg_control_system();" 2>/dev/null) \
        || fatal "Could not read system_identifier from Mac side."
    remote_id=$(remote_psql_value postgres "SELECT system_identifier FROM pg_control_system();" 2>/dev/null) \
        || fatal "Could not read system_identifier from remote side (check SSH + PG)."
    if [ "$mac_id" != "$remote_id" ]; then
        fatal "system_identifier MISMATCH: Mac=$mac_id Remote=$remote_id — clusters are NOT replicas of each other."
    fi
    ok "system_identifier match: $mac_id"
}

# Verify both sides run identical PG major version.
preflight_pg_version() {
    log "Comparing PG server_version_num..."
    local mac_v remote_v
    mac_v=$(mac_psql_value postgres "SHOW server_version_num;" 2>/dev/null)
    remote_v=$(remote_psql_value postgres "SHOW server_version_num;" 2>/dev/null)
    if [ -z "$mac_v" ] || [ -z "$remote_v" ]; then
        fatal "Could not read server_version_num from one or both sides."
    fi
    # Match on major (first 6 digits / 10000 trick → first 2 chars of the int are major)
    local mac_major="${mac_v:0:2}" remote_major="${remote_v:0:2}"
    if [ "$mac_major" != "$remote_major" ]; then
        fatal "PG major version MISMATCH: Mac=$mac_v Remote=$remote_v — replication will fail."
    fi
    ok "PG version compatible: Mac=$mac_v Remote=$remote_v"
}

# Verify synchronous_commit is 'on' on both sides — anything weaker makes lag=0 lie.
preflight_sync_commit() {
    log "Checking synchronous_commit on both sides..."
    local mac_sc remote_sc
    mac_sc=$(mac_psql_value postgres "SHOW synchronous_commit;" 2>/dev/null)
    remote_sc=$(remote_psql_value postgres "SHOW synchronous_commit;" 2>/dev/null)
    if [ "$mac_sc" != "on" ]; then
        fatal "Mac synchronous_commit = '$mac_sc' (must be 'on'). Fix via patronictl edit-config."
    fi
    if [ "$remote_sc" != "on" ]; then
        fatal "Remote synchronous_commit = '$remote_sc' (must be 'on')."
    fi
    ok "synchronous_commit = on on both sides"
}

# Verify the current primary is actually the side we expect.
# Args: $1 = expected primary side ("mac" or "remote")
preflight_current_primary() {
    local expected="$1"
    log "Verifying current primary is on '$expected' side..."
    local mac_inrec remote_inrec
    mac_inrec=$(mac_psql_value postgres "SELECT pg_is_in_recovery();" 2>/dev/null)
    remote_inrec=$(remote_psql_value postgres "SELECT pg_is_in_recovery();" 2>/dev/null)
    case "$expected" in
        mac)
            [ "$mac_inrec" = "f" ]   || fatal "Mac is NOT primary (pg_is_in_recovery=$mac_inrec). Refusing to run forward switchover."
            [ "$remote_inrec" = "t" ] || fatal "Remote is NOT a standby (pg_is_in_recovery=$remote_inrec). Refusing to run forward switchover."
            ok "State confirmed: Mac=primary, Remote=standby"
            ;;
        remote)
            [ "$remote_inrec" = "f" ] || fatal "Remote is NOT primary (pg_is_in_recovery=$remote_inrec). Refusing to run reverse switchover."
            [ "$mac_inrec" = "t" ]    || fatal "Mac is NOT a standby (pg_is_in_recovery=$mac_inrec). Refusing to run reverse switchover."
            ok "State confirmed: Remote=primary, Mac=standby"
            ;;
        *)  fatal "preflight_current_primary: unknown side '$expected'" ;;
    esac
}

# ============================================================================
# Lag-to-zero waiter (works on either side via supplied query function)
# ============================================================================
# Args:
#   $1 = side label ("mac"/"remote") — for logging only
#   $2 = function name that returns replay_lag_bytes as a single integer
#        (e.g. mac_replay_lag_bytes or remote_replay_lag_bytes)
wait_for_zero_lag() {
    local label="$1"
    local fn="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[DRY-RUN] Skipping lag drain wait for $label"
        return 0
    fi
    log "Polling replay_lag on $label until 0 (need $SWITCHOVER_LAG_POLL_COUNT consecutive)..."
    local consecutive_zero=0
    local total_attempts=0
    local max_attempts=30
    while [ "$consecutive_zero" -lt "$SWITCHOVER_LAG_POLL_COUNT" ]; do
        if [ "$total_attempts" -ge "$max_attempts" ]; then
            fatal "$label replay_lag did not reach 0 after $max_attempts attempts. Apps may still be writing — investigate."
        fi
        total_attempts=$((total_attempts + 1))
        local lag
        lag=$("$fn" 2>/dev/null || echo "ERR")
        if [ "$lag" = "0" ]; then
            consecutive_zero=$((consecutive_zero + 1))
            log "  attempt $total_attempts: lag=0 (consecutive=$consecutive_zero/$SWITCHOVER_LAG_POLL_COUNT)"
        elif [ "$lag" = "ERR" ] || [ -z "$lag" ]; then
            warn "  attempt $total_attempts: could not read lag — retrying"
            consecutive_zero=0
        else
            log "  attempt $total_attempts: lag=$lag bytes (resetting count)"
            consecutive_zero=0
        fi
        if [ "$consecutive_zero" -lt "$SWITCHOVER_LAG_POLL_COUNT" ]; then
            sleep "$SWITCHOVER_LAG_POLL_INTERVAL"
        fi
    done
    ok "$label replay_lag = 0 confirmed across $SWITCHOVER_LAG_POLL_COUNT polls"
}

mac_replay_lag_bytes() {
    mac_psql_value postgres "
        SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)
        FROM pg_stat_replication WHERE application_name='db1'
        LIMIT 1;" 2>/dev/null
}

remote_replay_lag_bytes() {
    remote_psql_value postgres "
        SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)
        FROM pg_stat_replication LIMIT 1;" 2>/dev/null
}

# ============================================================================
# Role-flip waiter — poll until expected role appears in patronictl output
# ============================================================================
# Args:
#   $1 = side ("mac" or "remote")
#   $2 = expected role ("Leader" / "Standby Leader" / "Replica")
#
# CRITICAL: uses column-aware regex so "Leader" does NOT match "Standby Leader".
wait_for_role() {
    local side="$1"
    local expected="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "[DRY-RUN] Skipping role wait for $side role '$expected'"
        return 0
    fi
    log "Waiting up to ${SWITCHOVER_PROMOTE_TIMEOUT}s for $side to show role '$expected'..."
    # patronictl list output columns are: | name | host | Role | State | TL | Lag |
    # The role is delimited by " | ... | " — use that as anchor so "Leader" doesn't
    # match "Standby Leader" (and vice versa).
    local pattern
    case "$expected" in
        "Leader")         pattern='\| +Leader +\|' ;;
        "Standby Leader") pattern='\| +Standby Leader +\|' ;;
        "Replica")        pattern='\| +Replica +\|' ;;
        *)                pattern="\\| +${expected} +\\|" ;;
    esac
    local elapsed=0
    while [ "$elapsed" -lt "$SWITCHOVER_PROMOTE_TIMEOUT" ]; do
        local list_out
        if [ "$side" = "mac" ]; then
            list_out=$(mac_patronictl list 2>/dev/null || true)
        else
            list_out=$(remote_patronictl list 2>/dev/null || true)
        fi
        if echo "$list_out" | grep -Eq "$pattern"; then
            ok "$side now shows role '$expected'"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fatal "$side did not reach role '$expected' within ${SWITCHOVER_PROMOTE_TIMEOUT}s. Check Patroni logs."
}

# ============================================================================
# Write-block / write-unblock (catalog-level, WAL-replicated)
# ============================================================================
# Applies to ALL non-template, non-postgres databases. We exclude the 'postgres'
# admin database so the script's own session (and emergency operator sessions)
# stay writable — important because RESET / GRANT are DDL operations that would
# fail under a read-only session.
#
# All operations are issued from the postgres admin database (-d postgres) so
# the operator session is never read-only.

# Returns space-separated list of user databases to protect (excludes templates
# and the postgres admin DB).
mac_user_databases() {
    mac_psql postgres -t -A -c \
        "SELECT datname FROM pg_database
         WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres'
         ORDER BY datname;" 2>/dev/null | tr '\n' ' '
}

remote_user_databases() {
    remote_psql postgres -t -A -c \
        "SELECT datname FROM pg_database
         WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres'
         ORDER BY datname;" 2>/dev/null | tr '\n' ' '
}

# Apply write-block on Mac (primary). Catalog-level, WAL-replicated.
mac_write_block() {
    local dbs
    dbs=$(mac_user_databases)
    [ -z "$dbs" ] && fatal "No user databases discovered on Mac — refusing to proceed."
    log "Mac: write-blocking databases: $dbs"

    local db
    for db in $dbs; do
        log "  - Mac: ALTER DATABASE $db SET default_transaction_read_only = on"
        if ! dry_run_echo "Mac ALTER DATABASE $db SET default_transaction_read_only = on"; then
            mac_psql postgres -c "ALTER DATABASE \"$db\" SET default_transaction_read_only = on;" >/dev/null
        fi
    done

    if [ -n "$APP_ROLES" ]; then
        log "Mac: revoking CONNECT from app roles: $APP_ROLES (for each db)"
        local role
        for db in $dbs; do
            for role in $APP_ROLES; do
                if ! dry_run_echo "Mac REVOKE CONNECT ON DATABASE $db FROM $role"; then
                    mac_psql postgres -c "REVOKE CONNECT ON DATABASE \"$db\" FROM \"$role\";" >/dev/null \
                        || warn "REVOKE CONNECT FROM $role on $db failed (role may not exist)"
                fi
            done
        done
    else
        warn "APP_ROLES is empty — skipping REVOKE step. Writes blocked by default_transaction_read_only only."
    fi

    log "Mac: terminating non-system sessions on user databases"
    if ! dry_run_echo "Mac pg_terminate_backend"; then
        mac_psql postgres -c "
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname IS NOT NULL
              AND datname <> 'postgres'
              AND usename NOT IN ('postgres','replicator')
              AND pid <> pg_backend_pid();" >/dev/null
    fi
    ok "Mac write-block applied across $(echo "$dbs" | wc -w | tr -d ' ') databases"
}

# Lift write-block on Mac.
mac_write_unblock() {
    local dbs
    dbs=$(mac_user_databases)
    [ -z "$dbs" ] && warn "No user databases discovered on Mac during unblock — unusual but continuing." && return 0
    log "Mac: unblocking databases: $dbs"

    local db role
    for db in $dbs; do
        log "  - Mac: ALTER DATABASE $db RESET default_transaction_read_only"
        if ! dry_run_echo "Mac ALTER DATABASE $db RESET default_transaction_read_only"; then
            mac_psql postgres -c "ALTER DATABASE \"$db\" RESET default_transaction_read_only;" >/dev/null
        fi
    done

    if [ -n "$APP_ROLES" ]; then
        log "Mac: granting CONNECT back to app roles: $APP_ROLES (for each db)"
        for db in $dbs; do
            for role in $APP_ROLES; do
                if ! dry_run_echo "Mac GRANT CONNECT ON DATABASE $db TO $role"; then
                    mac_psql postgres -c "GRANT CONNECT ON DATABASE \"$db\" TO \"$role\";" >/dev/null \
                        || warn "GRANT CONNECT TO $role on $db failed (role may not exist)"
                fi
            done
        done
    fi
    ok "Mac write-block lifted"
}

# Apply write-block on Remote (primary). Same logic mirrored.
remote_write_block() {
    local dbs
    dbs=$(remote_user_databases)
    [ -z "$dbs" ] && fatal "No user databases discovered on Remote — refusing to proceed."
    log "Remote: write-blocking databases: $dbs"

    local db role
    for db in $dbs; do
        log "  - Remote: ALTER DATABASE $db SET default_transaction_read_only = on"
        if ! dry_run_echo "Remote ALTER DATABASE $db SET default_transaction_read_only = on"; then
            remote_psql postgres -c "ALTER DATABASE \"$db\" SET default_transaction_read_only = on;" >/dev/null
        fi
    done

    if [ -n "$APP_ROLES" ]; then
        log "Remote: revoking CONNECT from app roles: $APP_ROLES (for each db)"
        for db in $dbs; do
            for role in $APP_ROLES; do
                if ! dry_run_echo "Remote REVOKE CONNECT ON DATABASE $db FROM $role"; then
                    remote_psql postgres -c "REVOKE CONNECT ON DATABASE \"$db\" FROM \"$role\";" >/dev/null \
                        || warn "REVOKE CONNECT FROM $role on $db failed on remote"
                fi
            done
        done
    else
        warn "APP_ROLES is empty — skipping REVOKE step."
    fi

    log "Remote: terminating non-system sessions on user databases"
    if ! dry_run_echo "Remote pg_terminate_backend"; then
        remote_psql postgres -c "
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname IS NOT NULL
              AND datname <> 'postgres'
              AND usename NOT IN ('postgres','replicator')
              AND pid <> pg_backend_pid();" >/dev/null
    fi
    ok "Remote write-block applied across $(echo "$dbs" | wc -w | tr -d ' ') databases"
}

# Lift write-block on Remote.
remote_write_unblock() {
    local dbs
    dbs=$(remote_user_databases)
    [ -z "$dbs" ] && warn "No user databases discovered on Remote during unblock." && return 0
    log "Remote: unblocking databases: $dbs"

    local db role
    for db in $dbs; do
        log "  - Remote: ALTER DATABASE $db RESET default_transaction_read_only"
        if ! dry_run_echo "Remote ALTER DATABASE $db RESET default_transaction_read_only"; then
            remote_psql postgres -c "ALTER DATABASE \"$db\" RESET default_transaction_read_only;" >/dev/null
        fi
    done

    if [ -n "$APP_ROLES" ]; then
        log "Remote: granting CONNECT back to app roles: $APP_ROLES (for each db)"
        for db in $dbs; do
            for role in $APP_ROLES; do
                if ! dry_run_echo "Remote GRANT CONNECT ON DATABASE $db TO $role"; then
                    remote_psql postgres -c "GRANT CONNECT ON DATABASE \"$db\" TO \"$role\";" >/dev/null \
                        || warn "GRANT CONNECT TO $role on $db failed on remote"
                fi
            done
        done
    fi
    ok "Remote write-block lifted"
}

# ============================================================================
# Force checkpoint + WAL switch (drives in-flight WAL to the standby)
# ============================================================================
mac_checkpoint_and_switch_wal() {
    log "Mac: CHECKPOINT + pg_switch_wal"
    if ! dry_run_echo "Mac CHECKPOINT + pg_switch_wal"; then
        mac_psql postgres -c "CHECKPOINT; SELECT pg_switch_wal();" >/dev/null
    fi
}

remote_checkpoint_and_switch_wal() {
    log "Remote: CHECKPOINT + pg_switch_wal"
    if ! dry_run_echo "Remote CHECKPOINT + pg_switch_wal"; then
        remote_psql postgres -c "CHECKPOINT; SELECT pg_switch_wal();" >/dev/null
    fi
}

# ============================================================================
# Slot management
# ============================================================================
mac_drop_slot() {
    local slot="$1"
    log "Mac: dropping replication slot '$slot'"
    if dry_run_echo "Mac DROP slot $slot"; then return 0; fi
    
    # 1. Terminate active backend if any
    mac_psql postgres -c "
        SELECT pg_terminate_backend(active_pid) 
        FROM pg_replication_slots 
        WHERE slot_name = '$slot' AND active;" >/dev/null 2>&1
    
    # 2. Wait up to 3 seconds for slot to become inactive
    local i
    for i in {1..3}; do
        local active
        active=$(mac_psql_value postgres "SELECT active::text FROM pg_replication_slots WHERE slot_name='$slot';" 2>/dev/null || echo "")
        if [ "$active" != "t" ]; then
            break
        fi
        sleep 1
    done

    # 3. Drop the replication slot
    mac_psql postgres -c "
        SELECT pg_drop_replication_slot('$slot')
        WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$slot');" >/dev/null
    ok "Mac slot '$slot' dropped (or did not exist)"
}

mac_create_slot() {
    local slot="$1"
    log "Mac: creating physical replication slot '$slot' (immediately_reserve=true)"
    if dry_run_echo "Mac CREATE slot $slot"; then return 0; fi
    mac_psql postgres -c "
        SELECT pg_create_physical_replication_slot('$slot', true)
        WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$slot');" >/dev/null
    ok "Mac slot '$slot' created (or already existed)"
}

remote_drop_slot() {
    local slot="$1"
    log "Remote: dropping replication slot '$slot'"
    if dry_run_echo "Remote DROP slot $slot"; then return 0; fi
    
    # 1. Terminate active backend if any
    remote_psql postgres -c "
        SELECT pg_terminate_backend(active_pid) 
        FROM pg_replication_slots 
        WHERE slot_name = '$slot' AND active;" >/dev/null 2>&1
    
    # 2. Wait up to 3 seconds for slot to become inactive
    local i
    for i in {1..3}; do
        local active
        active=$(remote_psql_value postgres "SELECT active::text FROM pg_replication_slots WHERE slot_name='$slot';" 2>/dev/null || echo "")
        if [ "$active" != "t" ]; then
            break
        fi
        sleep 1
    done

    # 3. Drop the replication slot
    remote_psql postgres -c "
        SELECT pg_drop_replication_slot('$slot')
        WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$slot');" >/dev/null
    ok "Remote slot '$slot' dropped (or did not exist)"
}

remote_create_slot() {
    local slot="$1"
    log "Remote: creating physical replication slot '$slot' (immediately_reserve=true)"
    if dry_run_echo "Remote CREATE slot $slot"; then return 0; fi
    remote_psql postgres -c "
        SELECT pg_create_physical_replication_slot('$slot', true)
        WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$slot');" >/dev/null
    ok "Remote slot '$slot' created (or already existed)"
}

# ============================================================================
# Endpoint reference card (printed at end of each script)
# ============================================================================
print_endpoint_card() {
    local primary_side="$1"
    cat >&2 <<EOF

${BOLD}=== ENDPOINT REFERENCE CARD ===${NC}
Primary side is now: ${BOLD}${primary_side}${NC}

EOF
    if [ "$primary_side" = "remote" ]; then
        cat >&2 <<EOF
  App writes   → ${REMOTE_HAPROXY_HOST}:${REMOTE_HAPROXY_WRITE_PORT}  (HAProxy)
  App reads    → ${REMOTE_HAPROXY_HOST}:${REMOTE_HAPROXY_READ_PORT}  (HAProxy)
  PgBouncer wr → ${REMOTE_PGBOUNCER_HOST:-$REMOTE_HAPROXY_HOST}:${PGBOUNCER_PORT:-6432}
  PgBouncer ro → ${REMOTE_PGBOUNCER_HOST:-$REMOTE_HAPROXY_HOST}:${PGBOUNCER_RO_PORT:-6433}

EOF
    else
        cat >&2 <<EOF
  App writes   → ${MAC_VPN_HOST}:${HAPROXY_WRITE_PORT}  (HAProxy)
  App reads    → ${MAC_VPN_HOST}:${HAPROXY_READ_PORT:-5552}  (HAProxy)
  PgBouncer wr → ${MAC_VPN_HOST}:6432
  PgBouncer ro → ${MAC_VPN_HOST}:6433

EOF
    fi
}
