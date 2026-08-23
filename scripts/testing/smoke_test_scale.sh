#!/bin/bash
# scripts/testing/smoke_test_scale.sh — sandboxed smoke test for `make scale`.
#
# Exercises scripts/ops/scale_cluster.sh end-to-end with stubbed docker /
# curl binaries (no Docker daemon, no running cluster):
#
#   1. grow   2 → 4 replicas (3 → 5 members): configs regenerate, compose up,
#             barman image rebuild recorded, no volume deletion.
#   2. shrink 4 → 1 replica  (5 → 2 members) with the leader (db5) among the
#             removed nodes: switchover to db1, orphaned containers pruned,
#             volumes + Barman data deleted, .env port entries cleaned.
#   3. no-op  scale to current count: exits 0 without touching compose.
#   4. dry-run: prints the plan, modifies nothing.
#
# Usage: bash scripts/testing/smoke_test_scale.sh   (part of `make smoke-test`)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}"
FAILURES=0
SANDBOXES=""

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }

trap 'rm -rf $SANDBOXES' EXIT

# ----------------------------------------------------------------------------
# Sandbox builder: copies scripts+templates, seeds .env, installs shims.
# NOTE: must not set/export globals — callers invoke it via command
# substitution $(make_sandbox …), which runs in a subshell.
# ----------------------------------------------------------------------------
# Args: $1 = initial PATRONI_REPLICAS, $2 = leader node shown by stubs (or "")
make_sandbox() {
    local seed_replicas="$1" leader="$2"
    local sb
    sb="$(mktemp -d "${TMPDIR_BASE}/patroni_smoke_scale.XXXXXX")"

    cp -R "$ROOT/scripts" "$sb/scripts"
    cp -R "$ROOT/templates" "$sb/templates"
    mkdir -p "$sb/configs" "$sb/barman" "$sb/bin" "$sb/state"

    # common.sh's _find_project_root needs a docker-compose.yml next to .env
    printf 'services: {}\n' > "$sb/docker-compose.yml"
    sed -E "s|^PATRONI_REPLICAS=.*|PATRONI_REPLICAS=${seed_replicas}|" "$ROOT/.env" > "$sb/.env"

    # Cluster tables served by the docker stub. "Before" shows all 5 members
    # with the scenario leader; "after" shows the post-shrink 2-member cluster.
    cat > "$sb/state/list_before" <<LIST
+ Cluster: patroni1 (7000000000000000001) ----+
| Member | Host     | Role    | State     |
+--------+----------+---------+-----------+
| db1    | db1:5431 | Replica | streaming |
| db2    | db2:5431 | Replica | streaming |
| db3    | db3:5431 | Replica | streaming |
| db4    | db4:5431 | Replica | streaming |
| ${leader}   | ${leader}:5431 | Leader  | running   |
+--------+----------+---------+-----------+
LIST
    cat > "$sb/state/list_after" <<'LIST'
+ Cluster: patroni1 (7000000000000000001) ----+
| Member | Host     | Role    | State     |
+--------+----------+---------+-----------+
| db1    | db1:5431 | Leader  | running   |
| db2    | db2:5431 | Replica | streaming |
+--------+----------+---------+-----------+
LIST

    # --- docker shim: compose v2 routing, ps/exec/volume -------------------
    # Config comes from env vars (SHIM_LOG / SHIM_STATE / SHIM_VOLUMES) that
    # the caller sets via activate_sandbox() in the PARENT shell.
    cat > "$sb/bin/docker" <<'EOF'
#!/bin/sh
LOG="${SHIM_LOG:?}"; STATE="${SHIM_STATE:?}"
RUNNING="${SHIM_RUNNING:-db1 db2 db3 db4 db5 barman haproxy pgbadger etcd1}"
note() { echo "$*" >> "$LOG"; }
if [ "$1" = "compose" ]; then
    shift
    case "$1" in
        version) exit 0 ;;
        build)   note "COMPOSE_BUILD $2"; exit 0 ;;
        up)
            case "$*" in
                *remove-orphans*) { echo "UP_CALL"; } >> "$LOG" ;;
                *)                note "COMPOSE_UP_SERVICE $*" ;;
            esac
            exit 0 ;;
        *) exit 0 ;;
    esac
fi
case "$1" in
    ps)
        for c in $RUNNING; do echo "$c"; done; exit 0 ;;
    volume)
        case "$2" in
            ls) for v in ${SHIM_VOLUMES:-}; do echo "$v"; done; exit 0 ;;
            rm) shift 2; note "VOLUME_RM $*"; exit 0 ;;
        esac ;;
    exec)
        ct="$2"; shift 2
        if [ "$ct" = "barman" ]; then
            note "BARMAN_EXEC $*"
            exit 0
        fi
        case "$1" in
            patronictl)
                case "$*" in
                    *switchover*) note "SWITCHOVER $ct"; touch "$STATE/switched"; exit 0 ;;
                    *list*)
                        if [ -f "$STATE/switched" ]; then
                            cat "$STATE/list_after"
                        else
                            cat "$STATE/list_before"
                        fi
                        exit 0 ;;
                esac ;;
        esac
        exit 0 ;;
esac
exit 0
EOF

    # --- curl shim: Patroni API role per node; /replica always healthy -----
    # Leader is db5 (API port 8005) so shrink scenarios must switchover first.
    cat > "$sb/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
    */replica*) echo "200" ;;
    *:8005/patroni*) echo '{"role":"master"}' ;;
    */patroni*) echo '{"role":"replica"}' ;;
    *) echo "000" ;;
esac
exit 0
EOF

    # --- docker-compose fallback stub (should not be used, but be safe) ----
    cat > "$sb/bin/docker-compose" <<'EOF'
#!/bin/sh
echo "$*" >> "${SHIM_LOG:?}"
exit 0
EOF

    chmod +x "$sb/bin/docker" "$sb/bin/curl" "$sb/bin/docker-compose"
    echo "$sb"
}

# Point the shims at a sandbox's log/state and start a fresh log.
# Must be called in the parent shell, right after SB="$(make_sandbox …)" —
# exporting inside make_sandbox would be lost: $( … ) runs in a subshell.
activate_sandbox() {
    export SHIM_LOG="$1/shim.log" SHIM_STATE="$1/state"
    : > "$SHIM_LOG"
}

run_scale() {
    local sb="$1"; shift
    PATH="$sb/bin:$PATH" bash "$sb/scripts/ops/scale_cluster.sh" "$@" > "$sb/out.log" 2>&1
}

db_services() { grep -cE '^  db[0-9]+:' "$1/docker-compose.yml" || true; }
haproxy_servers() { grep -cE '^    server db[0-9]+ ' "$1/configs/haproxy.cfg" || true; }

# ============================================================================
# Scenario 1 — GROW: 2 → 4 replicas (3 → 5 members)
# ============================================================================
echo ""
echo "── Scenario 1: grow 2 → 4 replicas ──"
SB="$(make_sandbox 2 db2)"
SANDBOXES="$SANDBOXES $SB"
activate_sandbox "$SB"
set +e
run_scale "$SB" --replicas 4 --yes --timeout 30
RC=$?
set -e
LOG="$SB/shim.log"

[ "$RC" -eq 0 ] && pass "scale exited 0" || fail "scale exited $RC" "$(tail -20 "$SB/out.log")"
grep -q '^PATRONI_REPLICAS=4$' "$SB/.env" \
    && pass ".env PATRONI_REPLICAS=4" \
    || fail ".env PATRONI_REPLICAS wrong" "$(grep '^PATRONI_REPLICAS=' "$SB/.env")"
grep -q '^PATRONI_DB5_PORT=15435$' "$SB/.env" \
    && pass ".env gained PATRONI_DB5_PORT=15435" \
    || fail ".env missing PATRONI_DB5_PORT"
[ "$(db_services "$SB")" = "5" ] \
    && pass "compose defines 5 db services" \
    || fail "compose defines $(db_services "$SB") db services, expected 5"
[ "$(haproxy_servers "$SB")" = "10" ] \
    && pass "haproxy.cfg has 10 server lines (5 write + 5 read)" \
    || fail "haproxy.cfg has $(haproxy_servers "$SB") server lines, expected 10"
grep -q '^\[db5\]' "$SB/configs/barman.conf" \
    && pass "barman.conf gained [db5] section" \
    || fail "barman.conf missing [db5]"
grep -q '^COMPOSE_BUILD barman$' "$LOG" \
    && pass "barman image rebuilt (backup loop covers new nodes)" \
    || fail "barman image not rebuilt" "$(cat "$LOG")"
grep -q '^UP_CALL$' "$LOG" && pass "compose up invoked" || fail "compose up never invoked"
grep -q 'VOLUME_RM' "$LOG" && fail "grow must not delete volumes" "$(grep VOLUME_RM "$LOG")" \
    || pass "no volumes deleted during grow"
grep -q 'All 5 members healthy' "$SB/out.log" \
    && pass "waited for 5/5 healthy members" \
    || fail "health wait did not pass" "$(tail -10 "$SB/out.log")"

# ============================================================================
# Scenario 2 — SHRINK: 4 → 1 replica (5 → 2 members), leader db5 is removed
# ============================================================================
echo ""
echo "── Scenario 2: shrink 4 → 1 replica (leader db5 removed, switchover) ──"
SB="$(make_sandbox 4 db5)"
SANDBOXES="$SANDBOXES $SB"
activate_sandbox "$SB"
set +e
SHIM_VOLUMES="smoketest_db3_data smoketest_db3_logs smoketest_db4_data smoketest_db4_logs smoketest_db5_data smoketest_db5_logs" \
    run_scale "$SB" --replicas 1 --yes --timeout 30
RC=$?
set -e
LOG="$SB/shim.log"

grep -q '^PATRONI_REPLICAS=1$' "$SB/.env" \
    && pass ".env PATRONI_REPLICAS=1" \
    || fail ".env PATRONI_REPLICAS wrong" "$(grep '^PATRONI_REPLICAS=' "$SB/.env")"
! grep -q '^PATRONI_DB3_PORT=' "$SB/.env" \
    && pass ".env cleaned of removed node ports" \
    || fail ".env still has PATRONI_DB3_PORT" "$(grep '^PATRONI_DB[0-9]*_PORT' "$SB/.env")"
[ "$(db_services "$SB")" = "2" ] \
    && pass "compose defines 2 db services" \
    || fail "compose defines $(db_services "$SB") db services, expected 2"
[ "$(haproxy_servers "$SB")" = "4" ] \
    && pass "haproxy.cfg has 4 server lines (2 write + 2 read)" \
    || fail "haproxy.cfg has $(haproxy_servers "$SB") server lines, expected 4"
! grep -q '^\[db5\]' "$SB/configs/barman.conf" \
    && pass "barman.conf no longer references db5" \
    || fail "barman.conf still has [db5]"
grep -q '^SWITCHOVER db1$' "$LOG" \
    && pass "switchover to surviving db1 performed" \
    || fail "expected switchover on db1" "$(cat "$LOG")"
VOL_RM_COUNT=$(grep -c '^VOLUME_RM ' "$LOG" || true)
[ "$VOL_RM_COUNT" = "6" ] \
    && pass "all 6 removed-node volumes deleted (db3-db5 data+logs)" \
    || fail "deleted $VOL_RM_COUNT volumes, expected 6" "$(grep VOLUME_RM "$LOG")"
grep -q 'smoketest_db5_data' "$LOG" \
    && pass "project-prefixed volume names matched" \
    || fail "volume name pattern missed prefixed names" "$(grep VOLUME_RM "$LOG")"
grep -q 'BARMAN_EXEC.*rm -rf.*db5' "$LOG" \
    && pass "Barman server data cleaned for removed nodes" \
    || fail "Barman cleanup missing" "$(grep BARMAN_EXEC "$LOG")"
grep -q '^UP_CALL$' "$LOG" && pass "compose up invoked (orphans pruned)" || fail "compose up never invoked"
grep -q 'All 2 members healthy' "$SB/out.log" \
    && pass "waited for 2/2 healthy members" \
    || fail "health wait did not pass" "$(tail -10 "$SB/out.log")"

# ============================================================================
# Scenario 3 — NO-OP: scale to current count
# ============================================================================
echo ""
echo "── Scenario 3: no-op (already at target) ──"
SB="$(make_sandbox 2 db2)"
SANDBOXES="$SANDBOXES $SB"
activate_sandbox "$SB"
set +e
run_scale "$SB" --replicas 2 --yes --timeout 30
RC=$?
set -e
LOG="$SB/shim.log"
[ "$RC" -eq 0 ] && pass "exited 0" || fail "exited $RC" "$(tail -10 "$SB/out.log")"
grep -q "nothing to do" "$SB/out.log" && pass "reported nothing to do" || fail "no 'nothing to do' message"
grep -q '^UP_CALL$' "$LOG" && fail "no-op must not run compose up" || pass "compose untouched"

# ============================================================================
# Scenario 4 — DRY-RUN: plan printed, nothing modified
# ============================================================================
echo ""
echo "── Scenario 4: dry-run grow ──"
SB="$(make_sandbox 2 db2)"
SANDBOXES="$SANDBOXES $SB"
activate_sandbox "$SB"
set +e
run_scale "$SB" --replicas 4 --dry-run --timeout 30
RC=$?
set -e
LOG="$SB/shim.log"
[ "$RC" -eq 0 ] && pass "exited 0" || fail "exited $RC" "$(tail -10 "$SB/out.log")"
grep -q 'Dry-run complete' "$SB/out.log" && pass "dry-run banner shown" || fail "no dry-run banner"
grep -q '^PATRONI_REPLICAS=2$' "$SB/.env" \
    && pass ".env untouched" \
    || fail ".env was modified" "$(grep '^PATRONI_REPLICAS=' "$SB/.env")"
grep -q '^services: {}$' "$SB/docker-compose.yml" \
    && pass "compose untouched (still the dummy stub file)" \
    || fail "compose was modified"
grep -q '^UP_CALL$' "$LOG" && fail "dry-run must not run compose up" || pass "no compose up"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Scale smoke test PASSED (all scenarios green)."
    exit 0
else
    echo "Scale smoke test FAILED: $FAILURES check(s) failed."
    exit 1
fi
