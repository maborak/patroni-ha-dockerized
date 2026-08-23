#!/bin/bash
# scripts/testing/smoke_test_deps.sh — sandboxed tests for the dependency
# preflight (scripts/utils/check_deps.sh, `make doctor`, wizard first step).
#
#   1. MISSING:  restricted PATH without docker/compose → exits 1 with a
#                clear message (regression for the bare "Error 1" a fresh
#                remote host used to produce)
#   2. PRESENT:  stubbed docker/compose → exits 0
#
# Usage: bash scripts/testing/smoke_test_deps.sh   (part of make smoke-test)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}"
FAILURES=0
SANDBOXES=""

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }
trap 'rm -rf $SANDBOXES' EXIT

make_env() { # $1 = mode; prints env dir
    local mode="$1" d t
    d="$(mktemp -d "${TMPDIR_BASE}/patroni_smoke_deps.XXXXXX")"
    SANDBOXES="$SANDBOXES $d"
    mkdir -p "$d/bin"
    # Core tools every mode needs (exclusive-PATH runs resolve through here)
    for t in python3 openssl make bash awk df grep dirname tail cut; do
        src=$(command -v "$t") && ln -s "$src" "$d/bin/$t"
    done
    case "$mode" in
        with-docker)
            printf '#!/bin/sh\nexit 0\n' > "$d/bin/docker"
            printf '#!/bin/sh\nexit 0\n' > "$d/bin/docker-compose"
            chmod +x "$d/bin/docker" "$d/bin/docker-compose" ;;
        with-podman|with-both)
            printf '#!/bin/sh\nexit 0\n' > "$d/bin/podman"
            chmod +x "$d/bin/podman"
            if [ "$mode" = "with-both" ]; then
                printf '#!/bin/sh\nexit 0\n' > "$d/bin/docker"
                chmod +x "$d/bin/docker"
            fi ;;
    esac
    echo "$d"
}

run_check() { # $1 = env dir → check_deps with EXCLUSIVE PATH from that dir
    local d="$1"
    PATH="$d/bin" /bin/bash "$ROOT/scripts/utils/check_deps.sh"
}

run_check() { # $1 = env dir → runs check_deps with that dir as ENTIRE PATH
    local d="$1"
    PATH="$d/bin" /usr/bin/env bash "$ROOT/scripts/utils/check_deps.sh"
}

echo ""
echo "── Scenario 1: missing docker → clear failure, exit 1 ──"
ENVDIR="$(make_env without-docker)"
set +e
run_check "$ENVDIR" > "$ENVDIR/out.log" 2>&1
RC=$?
set -e

[ "$RC" -eq 1 ] && pass "exited 1 on missing dependency" \
    || fail "expected exit 1, got $RC" "$(cat "$ENVDIR/out.log")"
grep -qE 'no usable container engine' "$ENVDIR/out.log" \
    && pass "names the missing binary" \
    || fail "'docker not found' message missing" "$(cat "$ENVDIR/out.log")"
grep -q "required dependenc" "$ENVDIR/out.log" \
    && pass "summary line present" \
    || fail "no summary line"
grep -q "get.docker.com" "$ENVDIR/out.log" \
    && pass "install hint shown" \
    || fail "no install hint"

echo ""
echo "── Scenario 2: all deps present → green, exit 0 ──"
ENVDIR="$(make_env with-docker)"
set +e
PATH="$ENVDIR/bin:$PATH" bash "$ROOT/scripts/utils/check_deps.sh" > "$ENVDIR/out.log" 2>&1
RC=$?
set -e

[ "$RC" -eq 0 ] && pass "exited 0" \
    || fail "expected exit 0, got $RC" "$(cat "$ENVDIR/out.log")"
grep -q "All dependencies satisfied." "$ENVDIR/out.log" \
    && pass "success banner" \
    || fail "no success banner" "$(cat "$ENVDIR/out.log")"

# ============================================================================
# Scenario 3 — podman-only host → actionable bridge guidance, exit 1
# ============================================================================
echo ""
echo "── Scenario 3: podman-only → bridge guidance ──"
ENVDIR="$(make_env with-podman)"
set +e
run_check "$ENVDIR" > "$ENVDIR/out.log" 2>&1
RC=$?
set -e

# With the project's own bin/ shims present (this checkout has them), a
# podman-only host is fully supported → exit 0 + routing confirmation.
[ "$RC" -eq 0 ] && pass "podman-only host passes via project shims" \
    || fail "expected exit 0, got $RC" "$(cat "$ENVDIR/out.log")"
grep -q "routing container calls via project shims" "$ENVDIR/out.log" \
    && pass "routing confirmation shown" \
    || fail "routing note missing" "$(cat "$ENVDIR/out.log")"

# engines subcommand reports availability per mode
E1=$(PATH="$ENVDIR/bin" bash "$ROOT/scripts/utils/check_deps.sh" engines)
[ "$E1" = "podman" ] && pass "engines → 'podman'" \
    || fail "engines printed '$E1', expected 'podman'"

echo ""
echo "── Scenario 4: both engines → detected together ──"
ENVDIR="$(make_env with-both)"
E2=$(PATH="$ENVDIR/bin" bash "$ROOT/scripts/utils/check_deps.sh" engines)
[ "$E2" = "docker podman" ] && pass "engines → 'docker podman'" \
    || fail "engines printed '$E2', expected 'docker podman'"
set +e
run_check "$ENVDIR" > "$ENVDIR/out.log" 2>&1
RC=$?
set -e
grep -q "both docker and podman detected" "$ENVDIR/out.log" \
    && pass "full check notes both engines (wizard will ask)" \
    || fail "'both detected' note missing" "$(cat "$ENVDIR/out.log")"
[ "$RC" -eq 0 ] && pass "check still passes with both present" \
    || fail "unexpected exit $RC" "$(tail -5 "$ENVDIR/out.log")"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Deps smoke test PASSED."
    exit 0
else
    echo "Deps smoke test FAILED: $FAILURES check(s) failed."
    exit 1
fi
