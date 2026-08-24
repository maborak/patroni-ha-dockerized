#!/bin/bash
# scripts/utils/wizard.sh — Step-by-step setup wizard for the Patroni HA stack.
#
# A linear, one-question-at-a-time flow:
#   1. Detect stack state (fresh / stopped-with-data / running)
#   2. Ask for settings (cluster, nodes, credentials, database, ports)
#   3. Show a full review and ask for confirmation
#   4. Apply: back up .env, write settings, generate configs, start, wait healthy
#   5. Final summary (leader, endpoints, next steps)
#
# Nothing is written until the review is confirmed. Aborting at any step
# leaves .env and the stack untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/versions.sh"

PROJECT=${COMPOSE_PROJECT_NAME:-patroni-ha-dockerized}
ENVF="$PROJECT_ROOT/.env"
TOTAL_STEPS=8
STEP=0

if [ ! -t 0 ] && [ "${WIZARD_ALLOW_PIPED:-0}" != "1" ]; then
    echo "The wizard is interactive — run it directly: make wizard" >&2
    exit 1
fi

trap 'echo ""; echo -e "${YELLOW}Wizard aborted. Nothing was changed (unless you confirmed the review).${NC}"; exit 130' INT

# ============================================================================
# UI helpers
# ============================================================================
title() { echo ""; echo -e "${BOLD}${BLUE}══════ $* ══════${NC}"; }
step()  { STEP=$((STEP + 1)); echo ""; echo -e "${BOLD}${BLUE}── Step $STEP/$TOTAL_STEPS: $* ──${NC}"; }

ask() {  # ask "prompt" "default" -> $ANSWER ; EOF aborts
    local prompt="$1" def="${2:-}" ans
    if [ -n "$def" ]; then printf "%s [%s]: " "$prompt" "$def"
    else printf "%s: " "$prompt"; fi
    if ! read -r ans; then
        echo ""; echo -e "${YELLOW}Input closed — aborting. Nothing was changed.${NC}"; exit 0
    fi
    ANSWER="${ans:-$def}"
}

ask_yes() {  # ask_yes "prompt" "y" -> rc 0 = yes
    ask "$1 [y/n]" "${2:-y}"
    case "$ANSWER" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

fail_input() { echo -e "${RED}Invalid value: $1${NC}"; }

# ============================================================================
# .env helpers
# ============================================================================
env_get() { grep -E "^$1=" "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
env_has_real() { local v; v="$(env_get "$1")"; [ -n "$v" ] && [ "$v" != "CHANGE_ME_BEFORE_FIRST_USE" ]; }
env_set() {
    if grep -qE "^$1=" "$ENVF"; then
        sed -i.bak -E "s|^$1=.*|$1=$2|" "$ENVF" && rm -f "${ENVF}.bak"
    else
        printf '%s=%s\n' "$1" "$2" >> "$ENVF"
    fi
}

gen_password() { openssl rand -hex 12; }

# ============================================================================
# Container engine selection (docker vs podman) + dependency preflight
# ============================================================================
ENGINE_LIST=$(bash "$SCRIPT_DIR/../utils/check_deps.sh" engines 2>/dev/null || true)
has_engine() { echo " $ENGINE_LIST " | grep -q " $1 "; }

if [ ! -f "$ENVF" ] || ! grep -qE '^CONTAINER_ENGINE=' "$ENVF" 2>/dev/null; then
    if has_engine docker && has_engine podman; then
        title "Container engine"
        echo "Both docker and podman are available on this host."
        while :; do
            ask "Engine to drive the stack with (stored in .env as CONTAINER_ENGINE)" "docker"
            case "$ANSWER" in
                docker|podman) env_set CONTAINER_ENGINE "$ANSWER"; break ;;
                *) fail_input "$ANSWER (docker or podman)" ;;
            esac
        done
    elif [ -n "$ENGINE_LIST" ] && [ "$ENGINE_LIST" != "none" ]; then
        env_set CONTAINER_ENGINE "$ENGINE_LIST"
        echo "Container engine auto-selected: $ENGINE_LIST"
    fi
fi

# Generate bin/ shims so every subsequent step (and the whole project) routes
# through the selected engine.
if [ "${WIZARD_SKIP_SHIMS:-0}" != "1" ]; then
    bash "$SCRIPT_DIR/../utils/setup_engine_shims.sh"
fi

# Dependency preflight BEFORE anything else: a fresh host without a usable
# engine used to die here with a bare "command not found / Error 1".
if ! bash "$SCRIPT_DIR/../utils/check_deps.sh"; then
    echo "" >&2
    echo -e "${YELLOW}Wizard aborted — fix the dependencies above first ('make doctor' to re-check).${NC}" >&2
    exit 1
fi

# ============================================================================
# State helpers
# ============================================================================
stack_state() {
    if [ -n "$(docker-compose ps -q --status running 2>/dev/null)" ]; then echo "running"
    elif docker volume ls -q 2>/dev/null | grep -q "^${PROJECT}_db1_data$"; then echo "stopped-with-data"
    else echo "fresh"; fi
}

current_leader() {
    docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
        | grep Leader | awk '{print $2}' || true
}

# The RUNNING cluster name (from patronictl header: "+ Cluster: patroni1 (...)").
# This is the truth — .env can drift from it (e.g. after a hand-edit).
running_cluster_name() {
    docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
        | grep -oE 'Cluster: [a-zA-Z0-9_-]+' | awk '{print $2}' || true
}

# Bootstrap-bound versions as actually DEPLOYED (containers' data), falling
# back to .env, then to the registry default. Used by the versions step so
# "keep current" means the running stack's versions, not just .env's.
deployed_pg_version() {
    local out
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^db1$'; then
        out=$(docker exec db1 sh -c 'ls /var/lib/postgresql/ 2>/dev/null | grep -E "^[0-9]+$" | sort -n | tail -1' 2>/dev/null || true)
        [ -n "$out" ] && { echo "$out"; return 0; }
    fi
    env_get POSTGRES_VERSION
}

deployed_etcd_version() {
    local out
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^etcd1$'; then
        out=$(docker exec etcd1 etcd --version 2>/dev/null || true)
        out=$(printf '%s' "$out" | awk '/etcd Version/{print $3; exit}')
        [ -n "$out" ] && { echo "v${out#v}"; return 0; }
    fi
    env_get ETCD_VERSION
}

wait_healthy() {
    local timeout=180 elapsed=0 list replicas want
    want=$(env_get PATRONI_REPLICAS); want=${want:-3}
    echo "Waiting for the Patroni cluster to become healthy (timeout ${timeout}s)..."
    while [ "$elapsed" -lt "$timeout" ]; do
        list=$(docker exec db1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null || true)
        if echo "$list" | grep -q "Leader.*running"; then
            replicas=$(echo "$list" | grep -cE "Replica.*(streaming|running)" || true)
            if [ "${replicas:-0}" -ge "$want" ]; then
                echo -e "${GREEN}Cluster healthy: leader + ${replicas} replica(s) running.${NC}"
                return 0
            fi
        fi
        printf "  [%3ds/%ss] still starting...\r" "$elapsed" "$timeout"
        sleep 5; elapsed=$((elapsed + 5))
    done
    echo -e "\n${YELLOW}Not fully healthy after ${timeout}s — it may still be bootstrapping.${NC}"
    echo "Check progress with: make status"
    return 0
}

final_summary() {
    local leader
    leader=$(current_leader)
    title "Setup complete"
    if [ -n "$leader" ]; then echo -e "Leader: ${GREEN}${leader}${NC}   (cluster: $W_CLUSTER)"
    else echo -e "Leader: ${YELLOW}not elected yet${NC} — try 'make status' in a moment"; fi
    echo ""
    echo "Endpoints:"
    echo "  Write:    make psql       (localhost:${W_WRITE_PORT})"
    echo "  Read:     make psql-read  (localhost:${W_READ_PORT})"
    echo "  Pooled:   localhost:${W_PGBOUNCER_PORT} (rw) / localhost:${W_PGBOUNCER_RO_PORT} (ro)"
    echo ""
    if [ "$PASS_SHOWN" = "1" ]; then
        echo -e "${YELLOW}Passwords (also stored in .env): postgres=${W_PASS} replicator=${W_RPASS}${NC}"
    fi
    echo "Next steps:"
    [ "${IS_FRESH:-0}" = "1" ] && echo "  - make backup   # first Backup backup"
    echo "  - make check    # full health check"
    echo "  - make status   # all endpoints + backups"
}

# ============================================================================
# Settings steps (fills W_* variables)
# ============================================================================
gather_settings() {
    IS_FRESH=$1   # 1 = no existing data, 0 = reconfiguring an existing stack
    PASS_SHOWN=0

    local def_cluster def_replicas def_user def_db def_write def_read def_pb def_pbro def_base
    def_cluster=$(env_get PATRONI_CLUSTER_NAME);  def_cluster=${def_cluster:-patroni1}
    def_replicas=$(env_get PATRONI_REPLICAS);     def_replicas=${def_replicas:-2}
    def_user=$(env_get POSTGRES_USER);            def_user=${def_user:-postgres}
    def_db=$(env_get DEFAULT_DATABASE);           def_db=${def_db:-maborak}
    def_write=$(env_get HAPROXY_WRITE_PORT);      def_write=${def_write:-5551}
    def_read=$(env_get HAPROXY_READ_PORT);        def_read=${def_read:-5552}
    def_pb=$(env_get PGBOUNCER_PORT);             def_pb=${def_pb:-6432}
    def_pbro=$(env_get PGBOUNCER_RO_PORT);        def_pbro=${def_pbro:-6433}
    def_base=$(env_get PATRONI_BASE_PORT);        def_base=${def_base:-15431}

    step "Cluster identity"
    if [ "$IS_FRESH" = "0" ]; then
        local running
        running=$(running_cluster_name)
        if [ -n "$running" ] && [ "$running" != "$def_cluster" ]; then
            echo -e "${YELLOW}.env says '$def_cluster' but the running cluster is '$running'.${NC}"
            echo "Renaming an existing cluster is not supported — syncing .env to the running name."
            env_set PATRONI_CLUSTER_NAME "$running"
            def_cluster="$running"
        fi
        W_CLUSTER="$def_cluster"
        echo "Cluster name: $W_CLUSTER (fixed — a rename requires destroy + fresh bootstrap)"
    else
        while :; do
            ask "Cluster name" "$def_cluster"
            [[ "$ANSWER" =~ ^[a-zA-Z0-9_-]+$ ]] && { W_CLUSTER="$ANSWER"; break; }
            fail_input "$ANSWER (use letters, digits, - or _)"
        done
    fi

    step "Database nodes"
    while :; do
        ask "Replica count → $(( ${def_replicas:-2} + 1 )) total nodes (db1..db$(( ${def_replicas:-2} + 1 )))" "$def_replicas"
        [[ "$ANSWER" =~ ^[1-9]$ ]] && { W_REPLICAS="$ANSWER"; break; }
        fail_input "$ANSWER (1-9)"
    done
    echo "→ $((W_REPLICAS + 1)) total nodes: db1..db$((W_REPLICAS + 1)) (1 leader + $W_REPLICAS replicas)"
    [ "$W_REPLICAS" -lt 2 ] && echo -e "${YELLOW}Note: 1 replica = no HA redundancy (a leader crash loses writes until restart).${NC}"
    if [ "$IS_FRESH" = "0" ] && [ "$W_REPLICAS" != "$def_replicas" ]; then
        echo -e "${YELLOW}Scaling an existing cluster: new nodes join as replicas and sync automatically; removed nodes' data is deleted.${NC}"
    fi

    step "Administrator"
    if [ "$IS_FRESH" = "0" ]; then
        W_USER="$def_user"
        echo "Admin user: $W_USER (fixed — bootstrap-only setting on an existing cluster)"
    else
        while :; do
            ask "Admin user" "$def_user"
            [[ "$ANSWER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && { W_USER="$ANSWER"; break; }
            fail_input "$ANSWER"
        done
    fi
    if env_has_real POSTGRES_PASSWORD && env_has_real REPLICATOR_PASSWORD; then
        W_PASS="(unchanged)"; W_RPASS="(unchanged)"; W_PASS_CHANGED=0
        echo "Passwords: (keep current — from .env)"
        [ "$IS_FRESH" = "0" ] && echo -e "${YELLOW}Note: the DB role password only changes on fresh bootstrap; the replicator password applies via regenerated configs.${NC}"
    else
        W_PASS_CHANGED=1
        W_PASS="$(gen_password)"; W_RPASS="$(gen_password)"
        env_has_real POSTGRES_PASSWORD || echo -e "${YELLOW}POSTGRES_PASSWORD missing/placeholder in .env — will be set.${NC}"
        env_has_real REPLICATOR_PASSWORD || echo -e "${YELLOW}REPLICATOR_PASSWORD missing/placeholder in .env — will be set.${NC}"
        [ "$IS_FRESH" = "0" ] && echo -e "${YELLOW}Note: postgres keeps its existing DB password; the replicator password is refreshed in regenerated configs.${NC}"
        if ask_yes "Use generated passwords?" "y"; then :; else
            local spec label var
            for spec in "postgres password:W_PASS" "replicator password:W_RPASS"; do
                label="${spec%%:*}"; var="${spec##*:}"
                while :; do
                    ask "$label (blank = regenerate)" ""
                    if [ -z "$ANSWER" ]; then eval "$var=\"\$(gen_password)\""; echo "Generated $label: $(eval "echo \$$var")"; break; fi
                    [[ "$ANSWER" =~ ^[A-Za-z0-9_@#%^+=:.-]+$ ]] && { eval "$var=\"\$ANSWER\""; break; }
                    fail_input "$label (avoid spaces/quotes/pipe)"
                done
            done
        fi
    fi

    step "Default database"
    if [ "$IS_FRESH" = "0" ]; then
        W_DB="$def_db"
        echo "Database: $W_DB (fixed — bootstrap-only setting on an existing cluster)"
    else
        while :; do
            ask "Database name" "$def_db"
            [[ "$ANSWER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && { W_DB="$ANSWER"; break; }
            fail_input "$ANSWER"
        done
    fi

    step "Ports"
    W_WRITE_PORT=$def_write; W_READ_PORT=$def_read; W_PGBOUNCER_PORT=$def_pb
    W_PGBOUNCER_RO_PORT=$def_pbro; W_BASE_PORT=$def_base
    if ask_yes "Use default ports? (HAProxy ${def_write}/${def_read}, PgBouncer ${def_pb}/${def_pbro}, nodes ${def_base}+)" "y"; then :; else
        local vars=("HAProxy write port:W_WRITE_PORT" "HAProxy read port:W_READ_PORT" "PgBouncer port:W_PGBOUNCER_PORT" "PgBouncer read-only port:W_PGBOUNCER_RO_PORT" "First PostgreSQL port (nodes use N, N+1, ...):W_BASE_PORT")
        local defaults=("$def_write" "$def_read" "$def_pb" "$def_pbro" "$def_base")
        local i spec label var d
        for i in 1 2 3 4 5; do
            spec="${vars[$((i-1))]}"
            label="${spec%%:*}"
            var="${spec##*:}"
            d="${defaults[$((i-1))]}"
            while :; do
                ask "$label" "$d"
                [[ "$ANSWER" =~ ^[0-9]+$ ]] && [ "$ANSWER" -ge 1 ] && [ "$ANSWER" -le 65535 ] \
                    && { eval "$var=$ANSWER"; break; }
                fail_input "$ANSWER (1-65535)"
            done
        done
    fi

    step "Backup tooling"
    local def_tool
    def_tool=$(env_get BACKUP_TOOL); def_tool=${def_tool:-pgbackrest}
    while :; do
        ask "Backup tool (barman | pgbackrest — recommended for new setups)" "$def_tool"
        case "$ANSWER" in
            barman|pgbackrest) W_BACKUP_TOOL="$ANSWER"; break ;;
            *) fail_input "$ANSWER (barman or pgbackrest)" ;;
        esac
    done
    [ "$W_BACKUP_TOOL" != "$def_tool" ] && [ "$IS_FRESH" = "0" ] && \
        echo -e "${YELLOW}Note: switching tools on an existing stack orphans previous backups.${NC}"

    step "Software versions"
    # Bootstrap-bound components: changing PostgreSQL or etcd on an existing
    # stack means destroying every volume and bootstrapping from scratch —
    # data dirs and DCS state are version-specific (no in-place switching).
    W_DESTROY_FIRST=0
    local def_pg def_patroni def_etcd def_haproxy def_pgb def_pgbadger
    if [ "$IS_FRESH" = "0" ]; then
        # Ground truth = what the volumes/DCS actually hold
        def_pg=$(deployed_pg_version);    def_pg=${def_pg:-$(default_version POSTGRES)}
        def_etcd=$(deployed_etcd_version); def_etcd=${def_etcd:-$(default_version ETCD)}
    else
        def_pg=$(env_get POSTGRES_VERSION);   def_pg=${def_pg:-$(default_version POSTGRES)}
        def_etcd=$(env_get ETCD_VERSION);     def_etcd=${def_etcd:-$(default_version ETCD)}
    fi
    def_patroni=$(env_get PATRONI_VERSION);    def_patroni=${def_patroni:-$(default_version PATRONI)}
    def_haproxy=$(env_get HAPROXY_VERSION);    def_haproxy=${def_haproxy:-$(default_version HAPROXY)}
    def_pgb=$(env_get PGBOUNCER_VERSION);      def_pgb=${def_pgb:-$(default_version PGBOUNCER)}
    def_pgbadger=$(env_get PGBADGER_VERSION);  def_pgbadger=${def_pgbadger:-$(default_version PGBADGER)}

    if [ "$IS_FRESH" = "0" ]; then
        echo "PostgreSQL / etcd: switching versions requires a FULL REBUILD (all volumes"
        echo "are destroyed, cluster bootstraps fresh). Other components rebuild in place."
    fi

    local vspec vlabel vvar vcomp vdef
    for vspec in \
        "PostgreSQL major:W_POSTGRES_VERSION:POSTGRES:$def_pg" \
        "Patroni release:W_PATRONI_VERSION:PATRONI:$def_patroni" \
        "etcd version:W_ETCD_VERSION:ETCD:$def_etcd" \
        "HAProxy version:W_HAPROXY_VERSION:HAPROXY:$def_haproxy" \
        "PgBouncer version:W_PGBOUNCER_VERSION:PGBOUNCER:$def_pgb" \
        "pgBadger version:W_PGBADGER_VERSION:PGBADGER:$def_pgbadger"; do
        vlabel="${vspec%%:*}";     vspec="${vspec#*:}"
        vvar="${vspec%%:*}";       vspec="${vspec#*:}"
        vcomp="${vspec%%:*}";      vdef="${vspec##*:}"
        while :; do
            ask "$vlabel (supported: $(supported_versions "$vcomp"))" "$vdef"
            if canon=$(canonical_version "$vcomp" "$ANSWER"); then
                eval "$vvar=\$canon"
                break
            fi
            fail_input "$ANSWER — supported ${vcomp} versions: $(supported_versions "$vcomp")"
        done
    done

    # Guard: bootstrap-bound version switch on an existing stack ⇒ full rebuild
    if [ "$IS_FRESH" = "0" ] && { [ "$W_POSTGRES_VERSION" != "$def_pg" ] || [ "$W_ETCD_VERSION" != "$def_etcd" ]; }; then
        echo ""
        echo -e "${RED}${BOLD}⚠  VERSION SWITCH REQUIRES DESTROYING ALL DATA${NC}"
        echo "   PostgreSQL $def_pg → $W_POSTGRES_VERSION / etcd $def_etcd → $W_ETCD_VERSION"
        echo "   Every volume goes away: ALL databases, Backup backups, pgBadger history."
        echo "   The cluster is then bootstrapped FRESH on the new versions."
        echo "   (Tip: 'make dump-db DB=<name>' first if you need a logical copy.)"
        local answer
        printf "%bType exactly 'REBUILD' to destroy + rebootstrap, anything else keeps %s / %s:%b " \
            "${YELLOW}${BOLD}" "$def_pg" "$def_etcd" "${NC}"
        read -r answer || answer=""
        if [ "$answer" = "REBUILD" ]; then
            W_DESTROY_FIRST=1
            W_ORIG_PG="$def_pg"
            W_ORIG_ETCD="$def_etcd"
        else
            W_POSTGRES_VERSION="$def_pg"
            W_ETCD_VERSION="$def_etcd"
            echo -e "${YELLOW}Kept current PostgreSQL/etcd — no rebuild will happen.${NC}"
        fi
    fi

    step "Review"
    echo "  Cluster name:        $W_CLUSTER"
    echo "  Nodes:               $((W_REPLICAS + 1)) (1 leader + $W_REPLICAS replicas)"
    echo "  Admin user:          $W_USER"
    echo "  Postgres password:   $( [ "$W_PASS_CHANGED" = "1" ] && echo "$W_PASS" || echo "(unchanged)" )"
    echo "  Replicator password: $( [ "$W_PASS_CHANGED" = "1" ] && echo "$W_RPASS" || echo "(unchanged)" )"
    echo "  Default database:    $W_DB"
    echo "  HAProxy:             write :${W_WRITE_PORT}  read :${W_READ_PORT}"
    echo "  PgBouncer:           rw :${W_PGBOUNCER_PORT}  ro :${W_PGBOUNCER_RO_PORT}"
    echo "  PostgreSQL nodes:    :${W_BASE_PORT}..$((W_BASE_PORT + W_REPLICAS))"
    echo "  PostgreSQL:          ${W_POSTGRES_VERSION}  ·  Patroni: ${W_PATRONI_VERSION}  ·  etcd: ${W_ETCD_VERSION}"
    echo "  HAProxy/PgBouncer:   ${W_HAPROXY_VERSION} / ${W_PGBOUNCER_VERSION}  ·  pgBadger: ${W_PGBADGER_VERSION}"
    echo ""
    echo "  This will:"
    echo "    - Back up .env and write these settings"
    echo "    - Generate SSH keys + configs"
    if [ "${W_DESTROY_FIRST:-0}" = "1" ]; then
        echo -e "    - ${RED}DESTROY all volumes, then bootstrap FRESH on PG $W_POSTGRES_VERSION / etcd $W_ETCD_VERSION${NC}"
    else
        echo "    - $([ "$IS_FRESH" = "1" ] && echo "Bootstrap a NEW cluster (leader election, ~1-2 min)" || echo "Restart the existing cluster from its data volumes")"
    fi
    echo "    - Start 3 etcd, $((W_REPLICAS + 1)) PostgreSQL, HAProxy, 2 PgBouncer, Backup"
}

apply_settings() {
    title "Applying"

    [ -f "$ENVF" ] || cp "$PROJECT_ROOT/.env.example" "$ENVF"
    local ts; ts=$(date +%Y%m%dT%H%M%S)
    cp "$ENVF" "${ENVF}.backup.${ts}"
    echo "Saved .env backup: .env.backup.${ts}"

    env_set PATRONI_CLUSTER_NAME "$W_CLUSTER"
    env_set PATRONI_REPLICAS "$W_REPLICAS"
    env_set POSTGRES_USER "$W_USER"
    env_set DEFAULT_DATABASE "$W_DB"
    if [ "$W_PASS_CHANGED" = "1" ]; then
        env_set POSTGRES_PASSWORD "$W_PASS"
        env_set REPLICATOR_PASSWORD "$W_RPASS"
        PASS_SHOWN=1
    fi
    env_set HAPROXY_WRITE_PORT "$W_WRITE_PORT"
    env_set HAPROXY_READ_PORT "$W_READ_PORT"
    env_set PGBOUNCER_PORT "$W_PGBOUNCER_PORT"
    env_set PGBOUNCER_RO_PORT "$W_PGBOUNCER_RO_PORT"
    env_set PATRONI_BASE_PORT "$W_BASE_PORT"
    env_set BACKUP_TOOL "$W_BACKUP_TOOL"
    env_set POSTGRES_VERSION "$W_POSTGRES_VERSION"
    env_set PATRONI_VERSION "$W_PATRONI_VERSION"
    env_set ETCD_VERSION "$W_ETCD_VERSION"
    env_set HAPROXY_VERSION "$W_HAPROXY_VERSION"
    env_set PGBOUNCER_VERSION "$W_PGBOUNCER_VERSION"
    env_set PGBADGER_VERSION "$W_PGBADGER_VERSION"

    if ask_yes "Enable monitoring stack (Prometheus + Grafana + alerts)?"; then
        env_set ENABLE_MONITORING 1
        [ "$(env_get GRAFANA_ADMIN_PASSWORD)" = "CHANGE_ME_BEFORE_FIRST_USE" ] || [ -z "$(env_get GRAFANA_ADMIN_PASSWORD)" ] &&             env_set GRAFANA_ADMIN_PASSWORD "$(gen_password)" && W_GRAF_PASS_SET=1
    else
        env_set ENABLE_MONITORING 0
    fi

    # Re-sync the shell environment to the new .env. common.sh exported the OLD
    # values at wizard startup; without this, generate_configs.sh treats the
    # stale exported PATRONI_REPLICAS as an override, and docker compose
    # interpolation (shell env wins over .env) bootstraps the old cluster name.
    set -a; source "$ENVF"; set +a

    # Version switch on an existing stack: hand the whole destructive migration
    # to its dedicated process (preflight → dump → destroy → bootstrap → wait).
    if [ "${W_DESTROY_FIRST:-0}" = "1" ]; then
        echo ""
        echo "Version switch requested — handing off to scripts/ops/rebootstrap.sh ..."
        exec bash "$PROJECT_ROOT/scripts/ops/rebootstrap.sh" \
            --from-wizard --yes \
            --from-pg "$W_ORIG_PG" --from-etcd "$W_ORIG_ETCD"
    fi

    echo "Generating configs..."
    bash "$PROJECT_ROOT/scripts/generate_configs.sh"
    echo "Starting containers..."
    docker-compose up -d --remove-orphans
    wait_healthy
}

resume_as_is() {
    title "Resuming existing stack"
    echo "Starting with current .env settings..."
    if ask_yes "Enable monitoring stack (Prometheus + Grafana + alerts)?"; then
        env_set ENABLE_MONITORING 1
        if [ "$(env_get GRAFANA_ADMIN_PASSWORD)" = "CHANGE_ME_BEFORE_FIRST_USE" ] || [ -z "$(env_get GRAFANA_ADMIN_PASSWORD)" ]; then
            env_set GRAFANA_ADMIN_PASSWORD "$(gen_password)"
            echo "(Grafana admin password generated — see .env)"
        fi
    else
        env_set ENABLE_MONITORING 0
    fi
    bash "$PROJECT_ROOT/scripts/generate_configs.sh"
    docker-compose up -d --remove-orphans
    wait_healthy
    # summary needs W_* values for ports/cluster
    W_CLUSTER=$(env_get PATRONI_CLUSTER_NAME); W_CLUSTER=${W_CLUSTER:-patroni1}
    W_WRITE_PORT=$(env_get HAPROXY_WRITE_PORT); W_WRITE_PORT=${W_WRITE_PORT:-5551}
    W_READ_PORT=$(env_get HAPROXY_READ_PORT);   W_READ_PORT=${W_READ_PORT:-5552}
    W_PGBOUNCER_PORT=$(env_get PGBOUNCER_PORT); W_PGBOUNCER_PORT=${W_PGBOUNCER_PORT:-6432}
    W_PGBOUNCER_RO_PORT=$(env_get PGBOUNCER_RO_PORT); W_PGBOUNCER_RO_PORT=${W_PGBOUNCER_RO_PORT:-6433}
    PASS_SHOWN=0
    final_summary
}

full_flow() {  # $1 = IS_FRESH
    gather_settings "$1"
    if ! ask_yes "Apply these settings and start the stack?"; then
        echo -e "${YELLOW}Cancelled — nothing was changed.${NC}"
        return 1
    fi
    apply_settings
    final_summary
}

# ============================================================================
# Main
# ============================================================================
title "Patroni HA — Setup Wizard"

STATE=$(stack_state)

if [ "$STATE" = "running" ]; then
    leader=$(current_leader)
    echo -e "Stack is ${GREEN}already running${NC} (leader: ${leader:-unknown})."
    echo "The wizard sets up a stack — choose what to do with the running one:"
    echo "   s) stop it, then continue in the wizard (data kept)"
    echo "   d) destroy it, then start over from scratch (ALL DATA LOST)"
    echo "   q) quit"
    while :; do
        ask "Choice" "q"
        case "$ANSWER" in
            s) docker-compose down; STATE="stopped-with-data"; break ;;
            d) make --no-print-directory destroy; STATE="fresh"; break ;;
            q) echo "Bye."; exit 0 ;;
            *) fail_input "$ANSWER" ;;
        esac
    done
fi

if [ "$STATE" = "stopped-with-data" ]; then
    echo -e "Existing stack data found (volumes kept)."
    echo "   r) resume it with current settings (no changes)"
    echo "   c) change settings first, then start"
    echo "   d) destroy everything and start over (ALL DATA LOST)"
    echo "   q) quit"
    while :; do
        ask "Choice" "r"
        case "$ANSWER" in
            r) resume_as_is; exit 0 ;;
            c) full_flow 0; exit $? ;;
            d) make --no-print-directory destroy; break ;;
            q) echo "Bye."; exit 0 ;;
            *) fail_input "$ANSWER" ;;
        esac
    done
fi

# fresh
full_flow 1
