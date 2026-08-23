#!/bin/bash
# scripts/utils/check_deps.sh — dependency preflight (powers `make doctor`,
# the setup wizard's first step, and container-engine selection).
#
# Usage:
#   check_deps.sh            full dependency check (exit 0/1)
#   check_deps.sh engines    print available container engines, one line:
#                            "docker", "podman", or "docker podman"
#
# Container engine selection:
#   * CONTAINER_ENGINE=docker|podman in .env pins the choice
#   * unset + both installed → reported as "both detected" (the wizard asks)
#   * podman-only hosts need a docker-compatible CLI bridge — this stack's
#     scripts drive containers through `docker <cmd>`; the two standard
#     bridges are the podman-docker shim or the podman.socket + docker CLI.
#
# Required: engine (binary + working daemon) + compose + openssl + python3 + make
# Advisory: psql, disk headroom
#
# Exit codes: 0 = satisfied · 1 = required pieces missing

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ERRORS=0
# No dirname dependency: hosts under preflight may lack coreutils extras
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
ENV_FILE="$SCRIPT_DIR/../../.env"

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
bad()  { echo -e "  ${RED}✗${NC} $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${YELLOW}•${NC} $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

engine_available() { # $1 = docker|podman → binary present AND daemon answers
    have "$1" && "$1" info >/dev/null 2>&1
}

configured_engine() {
    [ -f "$ENV_FILE" ] && grep -E '^CONTAINER_ENGINE=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Mode: engines — machine-readable availability list, then exit
# ---------------------------------------------------------------------------
if [ "${1:-}" = "engines" ]; then
    out=""
    engine_available docker  && out="docker"
    engine_available podman  && out="${out:+$out }podman"
    echo "${out:-none}"
    exit 0
fi

echo "=== Dependency Check ==="

# --- Engine selection --------------------------------------------------------
AVAIL=""
engine_available docker && AVAIL="docker"
engine_available podman && AVAIL="${AVAIL:+$AVAIL }podman"
SELECTED="$(configured_engine)"
case " $AVAIL " in
    *" ${SELECTED} "*) : ;;                                  # pinned engine OK
esac
if [ -z "$SELECTED" ] || ! echo " $AVAIL " | grep -q " $SELECTED "; then
    case "$AVAIL" in
        *docker*) SELECTED="docker" ;;
        *podman*) SELECTED="podman" ;;
        *)        SELECTED="" ;;
    esac
fi

case "$AVAIL" in
    "docker podman")
        if [ -n "$(configured_engine)" ]; then
            ok "engines: docker + podman both available — using ${SELECTED} (CONTAINER_ENGINE)"
        else
            info "both docker and podman detected — the setup wizard will ask which to use"
            info "(pre-select anytime: add CONTAINER_ENGINE=docker|podman to .env)"
        fi ;;
    docker) ok "engine: docker" ;;
    podman) ok "engine: podman" ;;
    *)
        bad "no usable container engine — need docker or podman (binary + running daemon)" ;;
esac

# Docker-compatible CLI gate (all scripts invoke `docker <cmd>`).
# With CONTAINER_ENGINE=podman the project's bin/ shims translate those
# calls, so a system docker CLI is NOT required.
BIN_DOCKER="$SCRIPT_DIR/../../bin/docker"
if [ -n "$SELECTED" ] && ! have docker; then
    if [ "$SELECTED" = "podman" ]; then
        if [ -x "$BIN_DOCKER" ]; then
            ok "routing container calls via project shims (bin/docker → podman)"
        else
            warn "podman selected but bin/ shims missing — run 'make wizard' or 'bash scripts/utils/setup_engine_shims.sh' once"
        fi
    else
        bad "docker CLI not found — this stack drives containers through a docker-compatible interface"
        echo "       Bridge podman with one of:" >&2
        echo "         apt/dnf install podman-docker      # docker shim over podman" >&2
        echo "         systemctl --user enable --now podman.socket  + install docker CLI" >&2
    fi
fi

# --- Daemon sanity for selected engine ---------------------------------------
if [ -n "$SELECTED" ]; then
    if "$SELECTED" info >/dev/null 2>&1; then
        ok "${SELECTED} daemon reachable ($("$SELECTED" info --format '{{.ServerVersion}}' 2>/dev/null))"
    else
        bad "${SELECTED} daemon NOT reachable — is the service running?"
        [ "$SELECTED" = "docker" ] \
            && echo "       (try: sudo systemctl start docker · sudo usermod -aG docker \$USER + re-login)" >&2
    fi
fi

# --- Compose ------------------------------------------------------------------
COMPOSE=""
if [ -n "$SELECTED" ]; then
    if "$SELECTED" compose version >/dev/null 2>&1; then
        COMPOSE="$SELECTED compose ($("$SELECTED" compose version 2>/dev/null | awk '{print $NF}'))"
    elif [ "$SELECTED" = "docker" ] && have docker-compose && docker-compose version >/dev/null 2>&1; then
        COMPOSE="docker-compose ($(docker-compose version 2>/dev/null | awk '{print $NF}'))"
    elif [ "$SELECTED" = "podman" ] && have podman-compose && podman-compose --version >/dev/null 2>&1; then
        COMPOSE="podman-compose ($(podman-compose --version 2>/dev/null | awk '{print $NF}'))"
    fi
fi
if [ -n "$COMPOSE" ]; then ok "compose: $COMPOSE"
else bad "compose not found — need '${SELECTED} compose' (or docker-compose / podman-compose)"
fi

# --- Other required commands ---------------------------------------------------
for cmd in openssl python3 make; do
    if have "$cmd"; then ok "$cmd"
    else bad "$cmd not found — required"
    fi
done

# --- Advisory -------------------------------------------------------------------
if have psql; then ok "psql"
else warn "psql not found — host-side targets like 'make psql'/'make status' need it (optional)"
fi

if have df; then
    AVAIL_KB=$(df -Pk . 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -lt 2097152 ] \
        && warn "less than 2 GB free on the project filesystem (${AVAIL_KB} kB) — PostgreSQL needs headroom" \
        || true
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}${ERRORS} required dependency(ies) missing — fix the ✗ items above, then re-run.${NC}"
    echo "Docker install hint (Debian/Ubuntu): curl -fsSL https://get.docker.com | sudo sh"
    echo "                                     sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi
echo -e "${GREEN}All dependencies satisfied.${NC}"
