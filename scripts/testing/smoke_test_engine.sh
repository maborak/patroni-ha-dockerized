#!/bin/bash
# scripts/testing/smoke_test_engine.sh — verifies CONTAINER_ENGINE drives the
# whole project through transparent bin/ shims:
#
#   1. podman selected  → bin/docker routes to podman; compose → podman-compose
#   2. docker selected  → shim execs the recorded docker binary path
#   3. sourcing common.sh prepends project bin/ to PATH (standalone runs)
#
# Usage: bash scripts/testing/smoke_test_engine.sh   (part of make smoke-test)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}"
FAILURES=0
SANDBOXES=""

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }
trap 'rm -rf $SANDBOXES' EXIT

init_engine_logs() { # $1 = sandbox dir; runs in PARENT shell and EXPORTS log paths
    export SHIM_PODMAN_LOG="$1/podman.log"             SHIM_DOCKER_LOG="$1/docker.log" \
           SHIM_PODMAN_COMPOSE_LOG="$1/pmcompose.log"  SHIM_DOCKER_COMPOSE_LOG="$1/dcompose.log"
    : > "$SHIM_PODMAN_LOG"; : > "$SHIM_DOCKER_LOG"; : > "$SHIM_PODMAN_COMPOSE_LOG"; : > "$SHIM_DOCKER_COMPOSE_LOG"
}

build_sandbox() { # $1 = dir, $2 = podman|docker ; stubs embed the exported log paths
    local d="$1" engine="$2"
    mkdir -p "$d/bin" "$d/realbin"
    cp -R "$ROOT/scripts" "$d/scripts"

    printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$SHIM_PODMAN_LOG"         > "$d/bin/podman"
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$SHIM_PODMAN_COMPOSE_LOG" > "$d/bin/podman-compose"
    # "system" binaries live OUTSIDE bin/ so shims can't self-resolve
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$SHIM_DOCKER_LOG"         > "$d/realbin/docker"
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$SHIM_DOCKER_COMPOSE_LOG" > "$d/realbin/docker-compose"
    chmod +x "$d/bin/"* "$d/realbin/"*
    printf 'CONTAINER_ENGINE=%s\n' "$engine" > "$d/.env"
}

new_scenario() { # $1 = engine ; sets SB + logs
    SB="$(mktemp -d "${TMPDIR_BASE}/patroni_smoke_eng.XXXXXX")"
    SB="$(cd "$SB" && pwd)"   # normalize (TMPDIR may carry a trailing slash)
    SANDBOXES="$SANDBOXES $SB"
    init_engine_logs "$SB"
    build_sandbox "$SB" "$1"
}

gen_shims() { # $1 = sandbox — generate shims using the SANDBOX's own copy
    ( cd "$1" && PATH="$1/realbin:$PATH" bash "$1/scripts/utils/setup_engine_shims.sh" ) >/dev/null 2>&1
}

echo ""
echo "── Scenario 1: CONTAINER_ENGINE=podman routes docker→podman ──"
new_scenario podman
gen_shims "$SB"

grep -q "podman" "$SB/bin/docker" && pass "shim targets podman" \
    || fail "shim does not reference podman" "$(cat "$SB/bin/docker")"

PATH="$SB/bin:$PATH" "$SB/bin/docker" ps -a --filter x 2>/dev/null || true
grep -q "^ps -a --filter x$" "$SHIM_PODMAN_LOG" \
    && pass "docker ps routed to podman, args intact" \
    || fail "podman not invoked correctly" "$(cat "$SHIM_PODMAN_LOG" 2>/dev/null)"

PATH="$SB/bin:$PATH" "$SB/bin/docker" compose up -d 2>/dev/null || true
grep -q "^up -d$" "$SHIM_PODMAN_COMPOSE_LOG" \
    && pass "compose translated to podman-compose" \
    || fail "compose translation failed" "$(cat "$SHIM_PODMAN_COMPOSE_LOG" 2>/dev/null; echo ---; cat "$SHIM_PODMAN_LOG")"

echo ""
echo "── Scenario 2: CONTAINER_ENGINE=docker records real binary path ──"
new_scenario docker
gen_shims "$SB"

grep -qE '^exec .*/realbin/docker "\$@"$' "$SB/bin/docker" \
    && pass "shim execs the recorded absolute docker path" \
    || fail "unexpected docker shim" "$(cat "$SB/bin/docker")"
grep -qE 'exec .*/realbin/docker(-compose| compose)?' "$SB/bin/docker-compose" \
    && pass "docker-compose shim wired (binary or plugin fallback)" \
    || fail "unexpected docker-compose shim" "$(cat "$SB/bin/docker-compose")"
PATH="$SB/bin:$SB/realbin:$PATH" "$SB/bin/docker" info 2>/dev/null || true
grep -q "^info$" "$SHIM_DOCKER_LOG" \
    && pass "calls resolve to the recorded docker binary (no recursion)" \
    || fail "recorded binary not reached" "$(cat "$SHIM_DOCKER_LOG" 2>/dev/null)"

echo ""
echo "── Scenario 3: common.sh prepends project bin/ to PATH ──"
new_scenario podman
gen_shims "$SB"
RESOLVED=$(cd "$SB" && bash -c 'source scripts/lib/common.sh >/dev/null 2>&1; command -v docker')
case "$RESOLVED" in
    *"$SB/bin/docker") pass "standalone script runs resolve engine shim first" ;;
    *) fail "common.sh did not prepend bin/ (resolved: ${RESOLVED:-none})" ;;
esac

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Engine smoke test PASSED."
    exit 0
else
    echo "Engine smoke test FAILED: $FAILURES check(s) failed."
    exit 1
fi
