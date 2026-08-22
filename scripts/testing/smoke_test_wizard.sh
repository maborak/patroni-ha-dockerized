#!/bin/bash
# scripts/testing/smoke_test_wizard.sh — end-to-end smoke test for the setup wizard.
#
# Regression test for the stale-environment bug where the wizard exported the
# OLD .env values (via common.sh), wrote NEW values to .env, and then:
#   - generate_configs.sh treated the stale exported PATRONI_REPLICAS as an
#     override and clobbered .env back to the old replica count
#   - docker compose interpolation (shell env beats .env file) bootstrapped
#     the OLD cluster name
#
# The test runs the REAL wizard in a sandbox copy of the project with stubbed
# docker/docker-compose binaries (no Docker daemon needed), changing the
# cluster name and scaling replicas up — then asserts .env, the generated
# configs, and the environment compose received all reflect the NEW values.
#
# Usage: make smoke-test   (or: bash scripts/testing/smoke_test_wizard.sh)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/patroni_smoke.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILURES=0
NEW_CLUSTER=wilmer
NEW_REPLICAS=4   # 4 replicas + 1 leader = 5 nodes

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for ctx in "$@"; do echo "$ctx" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }

# ============================================================================
# 1. Build the sandbox: copy scripts + templates, stub compose, seed OLD .env
# ============================================================================
cp -R "$ROOT/scripts" "$SANDBOX/scripts"
cp -R "$ROOT/templates" "$SANDBOX/templates"
mkdir -p "$SANDBOX/configs" "$SANDBOX/barman" "$SANDBOX/bin"

# common.sh's _find_project_root needs a docker-compose.yml next to .env
printf 'services: {}\n' > "$SANDBOX/docker-compose.yml"

# Seed .env with the OLD values (the pre-change state that triggered the bug).
# Real passwords are kept so the wizard takes the "(unchanged)" password path.
if [ ! -f "$ROOT/.env" ]; then
    echo "No $ROOT/.env found — copy .env.example first." >&2
    exit 1
fi
sed -E \
    -e "s|^PATRONI_CLUSTER_NAME=.*|PATRONI_CLUSTER_NAME=patroni1|" \
    -e "s|^PATRONI_REPLICAS=.*|PATRONI_REPLICAS=2|" \
    "$ROOT/.env" > "$SANDBOX/.env"

# --- Stub: docker-compose (records the env it sees on 'up') -------------
SHIM_LOG="$SANDBOX/compose_env.log"
export SHIM_LOG
cat > "$SANDBOX/bin/docker-compose" <<'EOF'
#!/bin/sh
# Test stub: no-op compose. Records cluster env on 'up' invocations.
for arg in "$@"; do
    case "$arg" in
        up)
            {
                echo "UP_CALL"
                echo "PATRONI_CLUSTER_NAME=${PATRONI_CLUSTER_NAME:-<unset>}"
                echo "PATRONI_REPLICAS=${PATRONI_REPLICAS:-<unset>}"
            } >> "${SHIM_LOG:?}"
            ;;
    esac
done
exit 0
EOF

# --- Stub: docker (fresh stack state + fake healthy cluster listing) ----
cat > "$SANDBOX/bin/docker" <<'EOF'
#!/bin/sh
# Test stub: 'volume ls' empty (fresh state), 'exec ... patronictl list'
# returns a healthy 5-node cluster so wait_healthy passes immediately.
case "$*" in
    *"volume ls"*)
        exit 0
        ;;
    *"patronictl"*" list"*)
        cat <<'LIST'
+ Cluster: wilmer (7000000000000000001) ----+
| Member | Host     | Role    | State     |
+--------+----------+---------+-----------+
| db1    | db1:5431 | Replica | streaming |
| db2    | db2:5431 | Leader  | running   |
| db3    | db3:5431 | Replica | streaming |
| db4    | db4:5431 | Replica | streaming |
| db5    | db5:5431 | Replica | streaming |
+--------+----------+---------+-----------+
LIST
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/bin/docker" "$SANDBOX/bin/docker-compose"

# ============================================================================
# 2. Run the real wizard: rename cluster + scale 2 -> 4 replicas
# ============================================================================
echo ""
echo "Running wizard in sandbox (cluster: patroni1->$NEW_CLUSTER, replicas: 2->$NEW_REPLICAS)..."
WIZARD_LOG="$SANDBOX/wizard_output.log"
# Answers: cluster name, replica count, admin user (default), database
# (default), default ports (y), apply (y). Passwords are auto-skipped.
set +e
printf '%s\n%s\n\n\n\n\n\n\n' "$NEW_CLUSTER" "$NEW_REPLICAS" \
    | WIZARD_ALLOW_PIPED=1 PATH="$SANDBOX/bin:$PATH" \
      bash "$SANDBOX/scripts/utils/wizard.sh" > "$WIZARD_LOG" 2>&1
WIZARD_RC=$?
set -e

echo ""
if [ "$WIZARD_RC" -ne 0 ]; then
    fail "wizard exited with code $WIZARD_RC" "$(tail -20 "$WIZARD_LOG")"
else
    pass "wizard completed successfully (exit 0)"
fi

envval() { grep -E "^$1=" "$SANDBOX/.env" | tail -1 | cut -d= -f2-; }

# ============================================================================
# 3. Assertions — .env survived config generation with the NEW values
# ============================================================================
[ "$(envval PATRONI_REPLICAS)" = "$NEW_REPLICAS" ] \
    && pass ".env PATRONI_REPLICAS=$NEW_REPLICAS (not clobbered back to 2)" \
    || fail ".env PATRONI_REPLICAS is '$(envval PATRONI_REPLICAS)', expected $NEW_REPLICAS" \
        "$(grep -n '^PATRONI_REPLICAS=' "$SANDBOX/.env")"

[ "$(envval PATRONI_CLUSTER_NAME)" = "$NEW_CLUSTER" ] \
    && pass ".env PATRONI_CLUSTER_NAME=$NEW_CLUSTER" \
    || fail ".env PATRONI_CLUSTER_NAME is '$(envval PATRONI_CLUSTER_NAME)', expected $NEW_CLUSTER"

grep -q "^PATRONI_DB5_PORT=15435$" "$SANDBOX/.env" \
    && pass ".env has PATRONI_DB5_PORT=15435" \
    || fail ".env missing PATRONI_DB5_PORT=15435" "$(grep -n '^PATRONI_DB[0-9]*_PORT' "$SANDBOX/.env")"

grep -q "^PATRONI_DB5_API_PORT=8005$" "$SANDBOX/.env" \
    && pass ".env has PATRONI_DB5_API_PORT=8005" \
    || fail ".env missing PATRONI_DB5_API_PORT=8005"

# ============================================================================
# 4. Assertions — generated configs reflect 5 nodes
# ============================================================================
DB_SERVICES=$(grep -cE '^  db[0-9]+:' "$SANDBOX/docker-compose.yml" || true)
[ "$DB_SERVICES" = "5" ] \
    && pass "docker-compose.yml defines 5 db services" \
    || fail "docker-compose.yml defines $DB_SERVICES db services, expected 5" \
        "$(grep -nE '^  [a-z0-9]+:' "$SANDBOX/docker-compose.yml")"

grep -q '^  db5_data:' "$SANDBOX/docker-compose.yml" \
    && pass "docker-compose.yml declares db5_data volume" \
    || fail "docker-compose.yml missing db5_data volume"

HAPROXY_SERVERS=$(grep -cE '^    server db[0-9]+ ' "$SANDBOX/configs/haproxy.cfg" || true)
[ "$HAPROXY_SERVERS" = "10" ] \
    && pass "haproxy.cfg has 5 servers in each backend (10 total)" \
    || fail "haproxy.cfg has $HAPROXY_SERVERS server lines, expected 10 (5 write + 5 read)" \
        "$(grep -nE '^    server db' "$SANDBOX/configs/haproxy.cfg")"

grep -q '^\[db5\]' "$SANDBOX/configs/barman.conf" \
    && pass "barman.conf has [db5] section" \
    || fail "barman.conf missing [db5] section" \
        "$(grep -n '^\[db' "$SANDBOX/configs/barman.conf")"

grep -q '^PATRONI_DB5_PORT=15435$' "$SANDBOX/.env.example" \
    && pass ".env.example regenerated with PATRONI_DB5_PORT" \
    || fail ".env.example missing PATRONI_DB5_PORT"

# ============================================================================
# 4b. Assertions — pgbadger service wired to every node's log volume
# ============================================================================
grep -q '^  pgbadger:' "$SANDBOX/docker-compose.yml" \
    && pass "docker-compose.yml defines pgbadger service" \
    || fail "docker-compose.yml missing pgbadger service"

PGBADGER_MOUNTS=$(grep -cE '^      - db[0-9]+_logs:/logs/db[0-9]+$' "$SANDBOX/docker-compose.yml" || true)
[ "$PGBADGER_MOUNTS" = "5" ] \
    && pass "pgbadger mounts all 5 node log volumes" \
    || fail "pgbadger mounts $PGBADGER_MOUNTS log volumes, expected 5" \
        "$(grep -nE '_logs:' "$SANDBOX/docker-compose.yml")"

NODE_LOG_MOUNTS=$(grep -cE '^      - db[0-9]+_logs:/var/log/postgresql$' "$SANDBOX/docker-compose.yml" || true)
[ "$NODE_LOG_MOUNTS" = "5" ] \
    && pass "all 5 db services mount their log volume" \
    || fail "$NODE_LOG_MOUNTS db services mount log volumes, expected 5"

grep -q '^  db5_logs:' "$SANDBOX/docker-compose.yml" \
    && pass "docker-compose.yml declares db5_logs volume" \
    || fail "docker-compose.yml missing db5_logs volume"

grep -q '^PGBADGER_CRON_EXPRESSION=' "$SANDBOX/.env.example" \
    && grep -q '^PGBADGER_PORT=8080$' "$SANDBOX/.env.example" \
    && pass ".env.example carries PGBADGER_* settings" \
    || fail ".env.example missing PGBADGER_* settings" \
        "$(grep -n 'PGBADGER' "$SANDBOX/.env.example")"

# ============================================================================
# 5. Core regression assertion — the env docker compose 'up' received
# ============================================================================
if [ -f "$SHIM_LOG" ]; then
    LAST_UP_ENV=$(awk '/^UP_CALL$/{block=""} {block=block $0 "\n"} END{printf "%s", block}' "$SHIM_LOG")
    UP_CLUSTER=$(echo "$LAST_UP_ENV" | grep '^PATRONI_CLUSTER_NAME=' | cut -d= -f2-)
    UP_REPLICAS=$(echo "$LAST_UP_ENV" | grep '^PATRONI_REPLICAS=' | cut -d= -f2-)
    [ "$UP_CLUSTER" = "$NEW_CLUSTER" ] && [ "$UP_REPLICAS" = "$NEW_REPLICAS" ] \
        && pass "compose 'up' received NEW values (cluster=$UP_CLUSTER, replicas=$UP_REPLICAS)" \
        || fail "compose 'up' received STALE values: cluster=$UP_CLUSTER replicas=$UP_REPLICAS \
(expected $NEW_CLUSTER/$NEW_REPLICAS) — the wizard re-sync bug is back" \
            "$(cat "$SHIM_LOG")"
else
    fail "compose 'up' was never invoked (shim log missing)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Smoke test PASSED (all checks green)."
    exit 0
else
    echo "Smoke test FAILED: $FAILURES check(s) failed."
    echo "Full wizard output: $WIZARD_LOG"
    exit 1
fi
