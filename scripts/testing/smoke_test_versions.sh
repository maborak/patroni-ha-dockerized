#!/bin/bash
# scripts/testing/smoke_test_versions.sh — sandboxed smoke tests for the
# supported-version registry (scripts/lib/versions.sh) and its enforcement in
# generate_configs.sh. No Docker daemon needed (stubbed docker binary).
#
# Scenarios:
#   1. REJECT:   unsupported ETCD_VERSION=1.2.3 aborts config generation
#   2. DEFAULTS: fresh stack (nothing running) gets registry defaults written
#                into .env and the resolved images into docker-compose.yml
#   3. DEPLOYED: existing PG15/etcd-3.5.17 stack keeps bootstrap-bound keys
#                aligned with what is deployed (no silent breaking bump)
#
# Usage: bash scripts/testing/smoke_test_versions.sh   (part of make smoke-test)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}"
FAILURES=0
SANDBOXES=""

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }
trap 'rm -rf $SANDBOXES' EXIT

# make_sandbox <seed-extra-env-lines> ; prints sandbox path. Must not export
# globals (command-substitution subshell).
make_sandbox() {
    local extra="$1"
    local sb
    sb="$(mktemp -d "${TMPDIR_BASE}/patroni_smoke_ver.XXXXXX")"
    cp -R "$ROOT/scripts" "$sb/scripts"
    cp -R "$ROOT/templates" "$sb/templates"
    mkdir -p "$sb/configs" "$sb/backup" "$sb/bin"
    printf 'services: {}\n' > "$sb/docker-compose.yml"
    # Seed from the real .env but strip every version key: the developer's
    # machine may carry them, and these scenarios must start without any.
    { sed -E "s|^PATRONI_REPLICAS=.*|PATRONI_REPLICAS=2|" "$ROOT/.env" \
        | grep -vE '^(POSTGRES|PATRONI|ETCD|HAPROXY|PGBOUNCER|PGBADGER)_VERSION='; \
      [ -n "$extra" ] && printf '%s\n' "$extra"; } > "$sb/.env"

    # docker stub: default = nothing running. Scenario 3 overrides via
    # SHIM_DEPLOYED=1 to simulate a live PG15 / etcd 3.5.17 stack.
    # The patronictl case keeps the wizard's wait_healthy() instant-passing.
    cat > "$sb/bin/docker" <<EOF
#!/bin/sh
if [ "\${SHIM_DEPLOYED:-0}" = "1" ]; then
    case "\$*" in
        *"ps --format"*) printf "db1\netcd1\nbarman\nhaproxy\npgbadger\npgbouncer\npgbouncer-ro\n"; exit 0 ;;
        *"/var/lib/postgresql/"*) echo "15"; exit 0 ;;
        *"etcd --version"*) echo "etcd Version: 3.5.17"; exit 0 ;;
    esac
fi
case "\$*" in
    *"patronictl"*" list"*)
        printf '+ Cluster: wiz (7000000000000000001) ----+\n'
        printf '| Member | Host     | Role    | State     |\n'
        printf '| db1    | db1:5431 | Leader  | running   |\n'
        printf '| db2    | db2:5431 | Replica | streaming |\n'
        printf '| db3    | db3:5431 | Replica | streaming |\n'
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$sb/bin/docker"

    # curl stub: Patroni API role per node (db5=8005 is Leader); /replica healthy
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

    # docker-compose fallback stub: silent no-op. Scenarios that need compose
    # behavior overwrite this file AFTER make_sandbox returns.
    printf '#!/bin/sh\nexit 0\n' > "$sb/bin/docker-compose"
    chmod +x "$sb/bin/docker" "$sb/bin/curl" "$sb/bin/docker-compose"

    # HARD GUARD: a missing stub means real docker would be invoked against
    # the developer's live stack. Never allow that — fail the sandbox build.
    local f
    for f in docker curl docker-compose; do
        if [ ! -x "$sb/bin/$f" ]; then
            echo "FATAL: sandbox stub bin/$f was not created — aborting test" >&2
            return 1
        fi
    done

    echo "$sb"
}

run_generate() {
    local sb="$1"
    PATH="$sb/bin:$PATH" bash "$sb/scripts/generate_configs.sh" > "$sb/out.log" 2>&1
}

envval() { grep -E "^$1=" "$2/.env" | tail -1 | cut -d= -f2-; }

# ============================================================================
# Scenario 1 — REJECT unsupported version
# ============================================================================
echo ""
echo "── Scenario 1: reject ETCD_VERSION=1.2.3 ──"
SB="$(make_sandbox "ETCD_VERSION=1.2.3")"
SANDBOXES="$SANDBOXES $SB"
set +e
run_generate "$SB"
RC=$?
set -e

[ "$RC" -ne 0 ] && pass "generate_configs refused to run (rc=$RC)" \
    || fail "generate_configs accepted an unsupported version!" "$(tail -5 "$SB/out.log")"
grep -q "unsupported ETCD version '1.2.3'" "$SB/out.log" \
    && pass "error names the component and offending value" \
    || fail "error message missing" "$(tail -8 "$SB/out.log")"
grep -qE "Supported ETCD versions: v3.7.1 v3.5.17" "$SB/out.log" \
    && pass "error lists supported versions" \
    || fail "supported list not shown" "$(tail -8 "$SB/out.log")"
grep -q 'versions.sh' "$SB/out.log" \
    && pass "error points at the registry file" \
    || fail "registry hint missing"
[ ! -f "$SB/configs/haproxy.cfg" ] && pass "no configs were generated" \
    || fail "configs were generated despite invalid input"

# ============================================================================
# Scenario 2 — DEFAULTS on a fresh host (nothing deployed)
# ============================================================================
echo ""
echo "── Scenario 2: fresh host → registry defaults ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
set +e
run_generate "$SB"
RC=$?
set -e

[ "$RC" -eq 0 ] && pass "generate_configs succeeded" \
    || fail "generate_configs failed" "$(tail -10 "$SB/out.log")"
for kv in "POSTGRES_VERSION=18" "PATRONI_VERSION=4.1.5" "ETCD_VERSION=v3.7.1" \
          "HAPROXY_VERSION=3.4" "PGBOUNCER_VERSION=v1.25.2-p0" "PGBADGER_VERSION=13.2"; do
    [ "$(envval "${kv%%=*}" "$SB")" = "${kv##*=}" ] \
        && pass ".env gained ${kv}" \
        || fail ".env ${kv%%=*} is '$(envval "${kv%%=*}" "$SB")', expected '${kv##*=}'"
done
grep -q 'image: quay.io/coreos/etcd:v3.7.1$' "$SB/docker-compose.yml" \
    && pass "compose pins etcd v3.7.1" \
    || fail "compose etcd image wrong" "$(grep -n 'coreos/etcd' "$SB/docker-compose.yml")"
grep -q 'image: docker.io/library/haproxy:3.4$' "$SB/docker-compose.yml" \
    && pass "compose pins haproxy 3.4" \
    || fail "compose haproxy image wrong"
grep -cq 'image: docker.io/edoburu/pgbouncer:v1.25.2-p0$' "$SB/docker-compose.yml" \
    && pass "compose pins pgbouncer v1.25.2-p0 (both services)" \
    || fail "compose pgbouncer image wrong"
grep -q 'POSTGRES_VERSION: "18"' "$SB/docker-compose.yml" \
    && grep -q 'PATRONI_VERSION: "4.1.5"' "$SB/docker-compose.yml" \
    && pass "patroni build args carry resolved versions" \
    || fail "patroni build args missing/wrong" "$(grep -n -A3 'context: ./patroni' "$SB/docker-compose.yml")"
grep -q 'PGBADGER_VERSION: "13.2"' "$SB/docker-compose.yml" \
    && pass "pgbadger build args carry resolved version" \
    || fail "pgbadger build args missing/wrong"

# ============================================================================
# Scenario 3 — DEPLOYED stack keeps PG/etcd aligned (no silent breakage)
# ============================================================================
echo ""
echo "── Scenario 3: deployed PG15/etcd-3.5.17 → keys match deployment ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
set +e
SHIM_DEPLOYED=1 run_generate "$SB"
RC=$?
set -e

[ "$RC" -eq 0 ] && pass "generate_configs succeeded" \
    || fail "generate_configs failed" "$(tail -10 "$SB/out.log")"
[ "$(envval POSTGRES_VERSION "$SB")" = "15" ] \
    && pass ".env aligned to deployed PostgreSQL 15 (not bumped to default)" \
    || fail ".env POSTGRES_VERSION is '$(envval POSTGRES_VERSION "$SB")', expected 15"
[ "$(envval ETCD_VERSION "$SB")" = "v3.5.17" ] \
    && pass ".env aligned to deployed etcd v3.5.17" \
    || fail ".env ETCD_VERSION is '$(envval ETCD_VERSION "$SB")', expected v3.5.17"
grep -q 'image: quay.io/coreos/etcd:v3.5.17$' "$SB/docker-compose.yml" \
    && pass "compose keeps the deployed etcd image" \
    || fail "compose etcd image was bumped despite deployed data"

# ============================================================================
# Scenario 4 — NORMALIZATION: loose spellings accepted, canonicalized
# ============================================================================
echo ""
echo "── Scenario 4: loose input (3.7.1, 1.25.2) → canonical tags ──"
SB="$(make_sandbox "ETCD_VERSION=3.7.1")"
SANDBOXES="$SANDBOXES $SB"
set +e
run_generate "$SB"
RC=$?
set -e

[ "$RC" -eq 0 ] && pass "generate_configs accepted loose '3.7.1'" \
    || fail "loose spelling was rejected" "$(tail -8 "$SB/out.log")"
grep -q 'image: quay.io/coreos/etcd:v3.7.1$' "$SB/docker-compose.yml" \
    && pass "compose uses canonical etcd tag" \
    || fail "compose etcd image not canonicalized"
[ "$(envval ETCD_VERSION "$SB")" = "v3.7.1" ] \
    && pass ".env rewritten to canonical v3.7.1" \
    || fail ".env still holds loose spelling: '$(envval ETCD_VERSION "$SB")'"
grep -q "Normalized ETCD_VERSION: 3.7.1 -> v3.7.1" "$SB/out.log" \
    && pass "normalization reported" \
    || fail "no normalization notice in output"

# unit-level: pgbouncer loose mapping + rejection of unknown patch spellings
if bash -c "source '$ROOT/scripts/lib/versions.sh'
    [ \"\$(canonical_version PGBOUNCER 1.25.2)\" = 'v1.25.2-p0' ] \
        && is_version_supported HAPROXY 3.4 \
        && ! is_version_supported POSTGRES 18.6"; then
    pass "registry units: 1.25.2→v1.25.2-p0 · haproxy branch ok · pg rejects minors"
else
    fail "registry unit checks failed"
fi

# ============================================================================
# Scenario 5 — WIZARD end-to-end: loose input accepted on fresh flow
# ============================================================================
# Runs the REAL wizard (piped) on a fresh sandbox and types the etcd version
# WITHOUT the "v" prefix — regression for the reported "3.7.1 is invalid" bug.
echo ""
echo "── Scenario 5: wizard accepts loose '3.7.1' (fresh flow) ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
cat > "$SB/bin/docker-compose" <<'EOF'
#!/bin/sh
case "$*" in *up*) echo "$*" >> "${SHIM_LOG:?}" ;; esac
exit 0
EOF
chmod +x "$SB/bin/docker-compose"
export SHIM_LOG="$SB/shim.log"; : > "$SHIM_LOG"

set +e
printf '%s\n' "wiz1" "2" "" "" "y" "" "17" "" "3.7.1" "" "" "" "y" \
    | WIZARD_ALLOW_PIPED=1 WIZARD_SKIP_SHIMS=1 PATH="$SB/bin:$PATH" \
      bash "$SB/scripts/utils/wizard.sh" > "$SB/wiz.log" 2>&1
WRC=$?
set -e

[ "$WRC" -eq 0 ] && pass "wizard completed" \
    || fail "wizard exited $WRC" "$(tail -12 "$SB/wiz.log")"
grep -q "Invalid value: 3.7.1" "$SB/wiz.log" \
    && fail "wizard rejected loose etcd input (bug is back)" \
    || pass "wizard accepted '3.7.1' without re-prompt"
[ "$(envval ETCD_VERSION "$SB")" = "v3.7.1" ] \
    && pass ".env stores canonical v3.7.1" \
    || fail ".env ETCD_VERSION is '$(envval ETCD_VERSION "$SB")'"
[ "$(envval POSTGRES_VERSION "$SB")" = "17" ] \
    && pass ".env stores chosen PG 17" \
    || fail ".env POSTGRES_VERSION is '$(envval POSTGRES_VERSION "$SB")'"

# ============================================================================
# Scenario 6 — WIZARD guard: version switch on existing stack needs REBUILD
# ============================================================================
run_wizard_switch() {
    # $1 = sandbox, $2 = answer to the REBUILD guard ("REBUILD" or junk)
    # Prompts on the stopped-with-data 'c' path (cluster/admin/db are FIXED):
    # menu, replicas, ports-y, versions x6, REBUILD-guard, apply.
    local sb="$1" guard="$2"
    printf '%s\n' "c" "" "y" "" "17" "" "" "" "" "" "$guard" "y" \
        | WIZARD_ALLOW_PIPED=1 WIZARD_SKIP_SHIMS=1 PATH="$sb/bin:$PATH" \
          bash "$sb/scripts/utils/wizard.sh" > "$sb/wiz.log" 2>&1
}

echo ""
echo "── Scenario 6a: guard accepted (REBUILD) → down -v + fresh versions ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
# stopped-with-data stack: volumes exist, nothing running; deployed = PG15/etcd3.5.17
cat > "$SB/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
    *"volume ls"*) echo "patroni-ha-dockerized_db1_data"; exit 0 ;;
    *"ps --format"*) printf "db1\netcd1\n"; exit 0 ;;
    *"patronictl"*" list"*)
        printf '+ Cluster: wiz (7000000000000000001) ----+\n'
        printf '| Member | Host     | Role    | State     |\n'
        printf '| db1    | db1:5431 | Leader  | running   |\n'
        printf '| db2    | db2:5431 | Replica | streaming |\n'
        printf '| db3    | db3:5431 | Replica | streaming |\n'
        exit 0 ;;
    *"/var/lib/postgresql/"*) echo "15"; exit 0 ;;
    *"etcd --version"*) echo "etcd Version: 3.5.17"; exit 0 ;;
esac
exit 0
EOF
cat > "$SB/bin/docker-compose" <<'EOF'
#!/bin/sh
case "$*" in
    *"-v"*) echo "DOWN_V" >> "${SHIM_LOG:?}" ;;
    *up*)   echo "UP"    >> "${SHIM_LOG:?}" ;;
esac
exit 0
EOF
chmod +x "$SB/bin/docker" "$SB/bin/docker-compose"
export SHIM_LOG="$SB/shim.log"; : > "$SHIM_LOG"

set +e
run_wizard_switch "$SB" "REBUILD"
WRC=$?
set -e

grep -q "VERSION SWITCH REQUIRES DESTROYING" "$SB/wiz.log" \
    && pass "destructive warning shown" \
    || fail "warning missing" "$(tail -12 "$SB/wiz.log")"
grep -q "Version-switch plan" "$SB/wiz.log" \
    && pass "wizard delegated to scripts/ops/rebootstrap.sh" \
    || fail "no handoff to rebootstrap process" "$(tail -15 "$SB/wiz.log")"
grep -q '^DOWN_V$' "$SHIM_LOG" \
    && pass "volumes destroyed before rebootstrap (down -v recorded)" \
    || fail "down -v never ran" "$(cat "$SB/shim.log" 2>/dev/null)"
[ "$(envval POSTGRES_VERSION "$SB")" = "17" ] \
    && pass ".env switched to PG 17" \
    || fail ".env POSTGRES_VERSION is '$(envval POSTGRES_VERSION "$SB")'"

echo ""
echo "── Scenario 6b: guard refused (junk) → keeps deployed versions ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
cat > "$SB/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
    *"volume ls"*) echo "patroni-ha-dockerized_db1_data"; exit 0 ;;
    *"ps --format"*) printf "db1\netcd1\n"; exit 0 ;;
    *"patronictl"*" list"*)
        printf '+ Cluster: wiz (7000000000000000001) ----+\n'
        printf '| Member | Host     | Role    | State     |\n'
        printf '| db1    | db1:5431 | Leader  | running   |\n'
        printf '| db2    | db2:5431 | Replica | streaming |\n'
        printf '| db3    | db3:5431 | Replica | streaming |\n'
        exit 0 ;;
    *"/var/lib/postgresql/"*) echo "15"; exit 0 ;;
    *"etcd --version"*) echo "etcd Version: 3.5.17"; exit 0 ;;
esac
exit 0
EOF
cat > "$SB/bin/docker-compose" <<'EOF'
#!/bin/sh
case "$*" in
    *"-v"*) echo "DOWN_V" >> "${SHIM_LOG:?}" ;;
    *up*)   echo "UP"    >> "${SHIM_LOG:?}" ;;
esac
exit 0
EOF
chmod +x "$SB/bin/docker" "$SB/bin/docker-compose"
export SHIM_LOG="$SB/shim.log"; : > "$SHIM_LOG"

set +e
run_wizard_switch "$SB" "no-wait"
WRC=$?
set -e

grep -q "Kept current PostgreSQL/etcd" "$SB/wiz.log" \
    && pass "kept deployed versions after wrong confirmation" \
    || fail "revert notice missing" "$(tail -12 "$SB/wiz.log")"
[ "$(envval POSTGRES_VERSION "$SB")" = "15" ] \
    && pass ".env still PG 15 (deployed)" \
    || fail ".env POSTGRES_VERSION is '$(envval POSTGRES_VERSION "$SB")', expected 15"
grep -q '^DOWN_V$' "$SHIM_LOG" \
    && fail "down -v ran despite refused confirmation!" \
    || pass "no destroy happened"

# ============================================================================
# Scenario 7 — REBOOTSTRAP process invoked directly
# ============================================================================
echo ""
echo "── Scenario 7: make-rebootstrap equivalent (--postgres 18 --etcd 3.7.1) ──"
SB="$(make_sandbox "")"
SANDBOXES="$SANDBOXES $SB"
export SHIM_DEPLOYED=1   # deployed probe: PG15 / etcd 3.5.17 via the default stub
export SHIM_LOG="$SB/shim.log"; : > "$SHIM_LOG"
set +e
PATH="$SB/bin:$PATH" bash "$SB/scripts/ops/rebootstrap.sh" \
    --postgres 18 --etcd 3.7.1 --dry-run > "$SB/rb_dry.log" 2>&1
DRY_RC=$?
PATH="$SB/bin:$PATH" bash "$SB/scripts/ops/rebootstrap.sh" \
    --postgres 18 --etcd 3.7.1 --yes --timeout 20 > "$SB/rb.log" 2>&1
RC=$?
set -e
unset SHIM_DEPLOYED

[ "$DRY_RC" -eq 0 ] && grep -q "Dry-run complete" "$SB/rb_dry.log" \
    && pass "dry-run prints plan and exits clean" \
    || fail "dry-run failed" "$(tail -8 "$SB/rb_dry.log")"
[ "$RC" -eq 0 ] && pass "rebootstrap completed" \
    || fail "rebootstrap exited $RC" "$(tail -12 "$SB/rb.log")"
grep -q "PostgreSQL:  15.*→.*18" "$SB/rb.log" \
    && pass "plan shows 15 → 18 transition" \
    || fail "plan missing transition" "$(grep -A2 'Version-switch plan' "$SB/rb.log")"
[ "$(envval POSTGRES_VERSION "$SB")" = "18" ] \
    && [ "$(envval ETCD_VERSION "$SB")" = "v3.7.1" ] \
    && pass ".env carries both canonical targets" \
    || fail ".env versions wrong: PG=$(envval POSTGRES_VERSION "$SB") ETCD=$(envval ETCD_VERSION "$SB")"
grep -q "Cluster healthy: leader + replicas streaming on the new versions." "$SB/rb.log" \
    && pass "waited for fresh cluster health" \
    || fail "health wait did not pass" "$(tail -10 "$SB/rb.log")"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Versions smoke test PASSED (all scenarios green)."
    exit 0
else
    echo "Versions smoke test FAILED: $FAILURES check(s) failed."
    exit 1
fi
