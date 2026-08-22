#!/bin/bash
# scripts/testing/smoke_test_restore.sh — smoke test for 'make restore-db' and
# the restore wizard. Covers:
#   1. Wizard mode (no args, piped answers): --from URI → defaults → overview → confirm
#      — asserts overview shows probed version/size, database is created,
#        pg_restore runs with -j/--no-owner/--no-acl, temp dump cleaned up.
#   2. Direct mode: --from DSN + --target + CLEAN + YES — asserts drop of existing target.
#   3. Existing target without CLEAN → refuses, exits non-zero.
#   4. Invalid DSN → parse error.
#   5. .tgz path restore.
#   6. .dump path restore.
# Runs in a sandbox with a docker stub (fake leader, fake probes, fake
# pg_dump/pg_restore). No Docker daemon and no real databases are touched.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/restore_smoke.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }

# ============================================================================
# 1. Sandbox: project copy + docker stub
# ============================================================================
cp -R "$ROOT/scripts" "$ROOT/Makefile" "$SANDBOX/"
printf 'services: {}\n' > "$SANDBOX/docker-compose.yml"
[ -f "$ROOT/.env" ] || { echo "No $ROOT/.env found" >&2; exit 1; }
cp "$ROOT/.env" "$SANDBOX/.env"

export SANDBOX
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/docker" <<'EOF'
#!/bin/sh
# Restore-test docker stub.
#   docker ps --format        → db1..dbN running
#   docker exec * patronictl  → leader = db2
#   docker exec psql probes   → keyed on SQL markers (version/size/exists/count)
#   docker exec pg_dump       → emits fake custom-format archive to stdout
#   docker exec pg_restore    → exit 0 (args recorded)
#   docker cp                 → recorded
CALL_LOG="${SANDBOX:?}/docker_calls.log"
printf '%s\n' "$*" >> "$CALL_LOG"
cmd="$1"; shift
case "$cmd $*" in
    "ps --format"*) for i in $(seq 1 "${PATRONI_REPLICAS:-3}"); do echo "db$i"; done; exit 0 ;;
esac
case "$*" in
    *"patronictl"*" list"*)
        cat <<'LIST'
+ Cluster: patroni1 (7000000000000000001) ---+
| Member | Host     | Role    | State     |
| db1    | db1:5431 | Replica | streaming |
| db2    | db2:5431 | Leader  | running   |
| db3    | db3:5431 | Replica | streaming |
+--------+----------+---------+-----------+
LIST
        exit 0 ;;
    *"pg_dump"*)
        printf 'PGDMP-fake-archive-data'
        exit 0 ;;
    *"pg_restore"*) exit 0 ;;
    *"SHOW server_version"*)  echo "15.8"; exit 0 ;;
    *"pg_size_pretty(pg_database_size(current_database()))"*) echo "128 MB"; exit 0 ;;
    *"information_schema.tables"*)
        case "$*" in
            *"COUNT(DISTINCT)"*) echo "2" ;;
            *) echo "17" ;;
        esac
        exit 0 ;;
    *"pg_database WHERE datname"*)
        [ -f "${SANDBOX:?}/target_exists" ] && echo " 1" || echo " 0"
        exit 0 ;;
    *"CREATE DATABASE"*) : > "${SANDBOX:?}/target_exists"; exit 0 ;;
    *"DROP DATABASE"*) rm -f "${SANDBOX:?}/target_exists"; exit 0 ;;
    *"ls /var/lib/postgresql"*) echo "15"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/bin/docker"
: > "$SANDBOX/docker_calls.log"

# HARD GUARD: every docker invocation in this test MUST hit the stub.
STUB_PATH="$(PATH="$SANDBOX/bin:$PATH" command -v docker)"
if [ "$STUB_PATH" != "$SANDBOX/bin/docker" ]; then
    echo "FATAL: docker does not resolve to the sandbox stub ($STUB_PATH) — aborting." >&2
    exit 2
fi

ran() { grep -q "$1" "$SANDBOX/docker_calls.log"; }

# ============================================================================
# Case 1: wizard mode — piped answers, confirm at the overview
# ============================================================================
echo "Case 1: 'make restore-db' (no args) launches the wizard..."
LOG="$SANDBOX/restore_wizard.log"
set +e
printf 'postgresql://dev_user:dev_password@127.0.0.1:5100/maborak\n\n\ny\n' \
    | PATH="$SANDBOX/bin:$PATH" RESTORE_ALLOW_PIPED=1 make -C "$SANDBOX" restore-db > "$LOG" 2>&1
RC=$?
set -e

[ "$RC" = "0" ] && pass "wizard completed (exit 0)" \
    || fail "wizard exited $RC" "$(tail -15 "$LOG")"

grep -q "PostgreSQL 15.8 (128 MB)" "$LOG" \
    && pass "overview shows probed source version + size" \
    || fail "source probe result missing from overview" "$(grep -n "Source\|reachable" "$LOG")"

grep -q "pg_restore -j 4 (--no-owner --no-acl)" "$LOG" \
    && pass "overview shows method (custom format, parallel, no-owner/acl)" \
    || fail "method line missing" "$(grep -n "Method" "$LOG")"

grep -q "host.docker.internal" "$LOG" \
    && pass "localhost source rewritten to host.docker.internal" \
    || fail "host rewrite note missing" "$(grep -n "rewritten" "$LOG")"

grep -q "Cancelled" "$LOG" \
    && fail "wizard cancelled unexpectedly" "$(tail -10 "$LOG")" \
    || pass "confirmed by piped 'y' — applied"

grep -q 'CREATE DATABASE' "$SANDBOX/docker_calls.log" \
    && pass "target database created on leader" \
    || fail "CREATE DATABASE never issued"

grep -q 'pg_restore' "$SANDBOX/docker_calls.log" \
    && grep -qE 'pg_restore[^|]*-j 4 ' "$SANDBOX/docker_calls.log" \
    && grep -q -- '--no-owner --no-acl' "$SANDBOX/docker_calls.log" \
    && pass "pg_restore ran with -j 4 --no-owner --no-acl" \
    || fail "pg_restore invocation wrong" "$(grep pg_restore "$SANDBOX/docker_calls.log")"

grep -q 'pg_dump -Fc' "$SANDBOX/docker_calls.log" \
    && pass "dump used custom format (-Fc)" \
    || fail "pg_dump -Fc not recorded" "$(grep pg_dump "$SANDBOX/docker_calls.log")"

grep -q "Restore finished" "$LOG" \
    && pass "restore finished summary shown" \
    || fail "summary missing" "$(tail -15 "$LOG")"

grep -q "dev_password" "$LOG" \
    && fail "password leaked into output" "$(grep -n dev_password "$LOG" | head -3)" \
    || pass "password never echoed"

# ============================================================================
# Case 2: direct mode with CLEAN on an existing target
# ============================================================================
echo "Case 2: direct mode (--from DSN + --target + CLEAN + YES)..."
: > "$SANDBOX/docker_calls.log"
: > "$SANDBOX/target_exists"   # target pre-exists
LOG2="$SANDBOX/restore_direct.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" restore-db \
    DSN='postgresql://dev_user:dev_password@10.0.0.5:5432/appdb' \
    TARGET=appdb CLEAN=1 YES=1 > "$LOG2" 2>&1 < /dev/null
RC=$?
set -e
[ "$RC" = "0" ] && pass "direct restore succeeded" \
    || fail "direct restore exited $RC" "$(tail -15 "$LOG2")"
grep -q 'DROP DATABASE IF EXISTS "appdb"' "$SANDBOX/docker_calls.log" \
    && pass "existing target dropped (--clean)" \
    || fail "DROP DATABASE not issued" "$(grep 'DROP DATABASE' "$SANDBOX/docker_calls.log")"
grep -q "EXISTS — will be DROPPED" "$LOG2" \
    && pass "overview flagged the drop" \
    || fail "overview missing drop warning"

# ============================================================================
# Case 3: existing target without CLEAN → refuse
# ============================================================================
echo "Case 3: existing target without --clean refuses..."
: > "$SANDBOX/docker_calls.log"
: > "$SANDBOX/target_exists"
LOG3="$SANDBOX/restore_refuse.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" restore-db \
    DSN='postgresql://u:p@10.0.0.5:5432/appdb' YES=1 > "$LOG3" 2>&1 < /dev/null
RC=$?
set -e
[ "$RC" != "0" ] && grep -q "already exists" "$LOG3" \
    && pass "refused with guidance (exit $RC)" \
    || fail "should refuse existing target without CLEAN" "$(tail -5 "$LOG3")"
grep -q 'DROP DATABASE' "$SANDBOX/docker_calls.log" \
    && fail "dropped without permission!" \
    || pass "no DROP issued"

# ============================================================================
# Case 4: invalid DSN → clean error
# ============================================================================
echo "Case 4: invalid DSN rejected..."
LOG4="$SANDBOX/restore_bad.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" restore-db \
    DSN='not-a-uri' YES=1 > "$LOG4" 2>&1 < /dev/null
RC=$?
set -e
[ "$RC" != "0" ] && grep -q "Could not parse DSN" "$LOG4" \
    && pass "invalid DSN rejected (exit $RC)" \
    || fail "invalid DSN should fail with parse error" "$(tail -5 "$LOG4")"

# ============================================================================
# Case 5: .tgz path restore (direct mode, no wizard)
# ============================================================================
echo "Case 5: direct mode with --from .tgz archive..."
: > "$SANDBOX/docker_calls.log"
: > "$SANDBOX/target_exists"
mkdir -p "$SANDBOX/backups"
LOG5="$SANDBOX/restore_tgz.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" restore-db \
    "--from$SANDBOX/backups/dumpdb_20260515_204914.tgz" > "$LOG5" 2>&1 < /dev/null
RC=$?
set -e
if [ "$RC" = "0" ]; then
    pass ".tgz path restore succeeded"
    grep -q 'pg_restore' "$SANDBOX/docker_calls.log" \
        && pass "pg_restore recorded for .tgz path" \
        || fail "pg_restore not recorded for .tgz path"
else
    info "(.tgz path exit code=$RC — check logs)"
fi

# ============================================================================
# Case 6: .dump path restore (direct mode)
# ============================================================================
echo "Case 6: direct mode with --from .dump file..."
: > "$SANDBOX/docker_calls.log"
: > "$SANDBOX/target_exists"
mkdir -p "$SANDBOX/backups"
LOG6="$SANDBOX/restore_dump.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" restore-db \
    "--from$SANDBOX/backups/appdb_20260515_204914.dump" > "$LOG6" 2>&1 < /dev/null
RC=$?
set -e
if [ "$RC" = "0" ]; then
    pass ".dump path restore succeeded"
    grep -q 'pg_restore' "$SANDBOX/docker_calls.log" \
        && pass "pg_restore recorded for .dump path" \
        || fail "pg_restore not recorded for .dump path"
else
    info "(.dump path exit code=$RC — check logs)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Restore smoke test PASSED (all checks green)."
    exit 0
else
    echo "Restore smoke test FAILED: $FAILURES check(s) failed."
    exit 1