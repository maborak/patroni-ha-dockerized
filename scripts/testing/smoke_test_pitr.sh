#!/bin/bash
# scripts/testing/smoke_test_pitr.sh — smoke test for 'make pitr' routing and
# the PITR interactive wizard.
#
# Covers three paths:
#   1. 'make pitr' with no args      → launches the interactive wizard
#      (backup selection → target node → WAL method → target time → summary
#      → confirm), driven with piped answers, declining at the final confirm.
#   2. 'make pitr BACKUP_ID=x'       → usage error, exit 1 (no silent partial run)
#   3. 'make pitr BACKUP_ID=x T=...' → perform_pitr.sh invoked with exact args
#
# Runs in a sandbox with stubbed docker (fake 'barman list-backup' output);
# no Docker daemon and no real recovery are performed.
#
# Usage: bash scripts/testing/smoke_test_pitr.sh   (or: make smoke-test)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pitr_smoke.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }

# ============================================================================
# 1. Build the sandbox: project copy + stubbed docker
# ============================================================================
cp -R "$ROOT/scripts" "$ROOT/Makefile" "$SANDBOX/"
printf 'services: {}\n' > "$SANDBOX/docker-compose.yml"
[ -f "$ROOT/.env" ] || { echo "No $ROOT/.env found — copy .env.example first." >&2; exit 1; }
cp "$ROOT/.env" "$SANDBOX/.env"

mkdir -p "$SANDBOX/bin"
export SANDBOX
cat > "$SANDBOX/bin/docker" <<'EOF'
#!/bin/sh
# Test stub: fake barman backup listing; everything else no-ops.
case "$*" in
    *"barman list-backup"*)
        # last argument is the server name (dbN)
        eval "server=\${$#}"
        cat <<LIST
${server} 20260821T120000 - Fri Aug 21 12:00:00 2026 - Size: 1.0 GiB - WAL Size: 20 MiB
${server} 20260820T120000 - Thu Aug 20 12:00:00 2026 - Size: 1.0 GiB - WAL Size: 15 MiB
LIST
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/bin/docker"

echo ""
echo "Case 1: 'make pitr' (no args) launches the interactive wizard..."

PITR_LOG="$SANDBOX/pitr_wizard.log"
# Answers: 1=first backup, 2=db2 target, Enter=default WAL method,
# custom timestamp, n=decline final confirm.
set +e
printf '1\n2\n\n2026-01-23 12:30:00\nn\n' \
    | PATH="$SANDBOX/bin:$PATH" PITR_ALLOW_PIPED=1 make -C "$SANDBOX" pitr > "$PITR_LOG" 2>&1
RC=$?
set -e

grep -q "Point-In-Time Recovery (PITR)" "$PITR_LOG" \
    && pass "wizard banner shown" \
    || fail "wizard banner not shown" "$(tail -20 "$PITR_LOG")"

grep -q "Found .* backup(s)" "$PITR_LOG" \
    && pass "backups listed from barman stub" \
    || fail "no backups found" "$(tail -20 "$PITR_LOG")"

grep -q "PITR Configuration Summary" "$PITR_LOG" \
    && pass "configuration summary reached" \
    || fail "configuration summary never shown" "$(tail -20 "$PITR_LOG")"

SUMMARY_BLOCK=$(sed -n '/PITR Configuration Summary/,/Start PITR/p' "$PITR_LOG" | sed $'s/\x1b\[[0-9;]*m//g')
echo "$SUMMARY_BLOCK" | grep -q "Backup ID:     20260821T120000" \
    && pass "summary shows selected backup id" \
    || fail "summary backup id wrong" "$SUMMARY_BLOCK"
echo "$SUMMARY_BLOCK" | grep -q "Target Node:   db2" \
    && pass "summary shows selected target node" \
    || fail "summary target node wrong" "$SUMMARY_BLOCK"
echo "$SUMMARY_BLOCK" | grep -q "Target Time:   2026-01-23 12:30:00" \
    && pass "summary shows custom target time" \
    || fail "summary target time wrong" "$SUMMARY_BLOCK"

grep -q "Cancelled" "$PITR_LOG" && [ "$RC" = "0" ] \
    && pass "declining confirm cancels cleanly (exit 0)" \
    || fail "cancel path broken (exit $RC)" "$(tail -5 "$PITR_LOG")"

# ============================================================================
# 2. Partial args → usage error
# ============================================================================
USAGE_LOG="$SANDBOX/pitr_usage.log"
set +e
PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" pitr BACKUP_ID=20260123T120000 > "$USAGE_LOG" 2>&1
RC=$?
set -e
# make exits 2 when a recipe line fails (script's exit 1 → make's 2)
[ "$RC" = "1" ] || [ "$RC" = "2" ] ; RC_IS_FAIL=$?
[ "$RC_IS_FAIL" = "0" ] && grep -q "^Usage: make pitr" "$USAGE_LOG" \
    && pass "partial args → usage + non-zero exit" \
    || fail "partial args should print usage and exit non-zero (got exit $RC)" "$(cat "$USAGE_LOG")"

# ============================================================================
# 3. Full args → perform_pitr.sh receives exact arguments
# ============================================================================
cat > "$SANDBOX/scripts/pitr/perform_pitr.sh" <<'EOF'
#!/bin/sh
# Invocation stub: record args and exit.
printf '%s\n' "$@" > "${SANDBOX:?}/pitr_invocation.args"
exit 0
EOF
chmod +x "$SANDBOX/scripts/pitr/perform_pitr.sh"

PATH="$SANDBOX/bin:$PATH" make -C "$SANDBOX" pitr \
    BACKUP_ID=20260821T120000 TARGET_TIME="2026-01-23 12:30:00" \
    SERVER=db2 TARGET=db1 RESTORE=1 AUTO_START=1 WAL_METHOD=barman-get-wal \
    > /dev/null 2>&1

EXPECTED_ARGS='20260821T120000
2026-01-23 12:30:00
--server
db2
--target
db1
--restore
--auto-start
--wal-method
barman-get-wal'
ACTUAL_ARGS="$(cat "$SANDBOX/pitr_invocation.args")"
[ "$ACTUAL_ARGS" = "$EXPECTED_ARGS" ] \
    && pass "full args forwarded to perform_pitr.sh verbatim" \
    || fail "perform_pitr.sh received wrong args" "expected: $(echo "$EXPECTED_ARGS" | tr '\n' ' ')" "actual:   $(echo "$ACTUAL_ARGS" | tr '\n' ' ')"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "PITR smoke test PASSED (all checks green)."
    exit 0
else
    echo "PITR smoke test FAILED: $FAILURES check(s) failed."
    echo "Wizard output: $PITR_LOG"
    exit 1
fi
