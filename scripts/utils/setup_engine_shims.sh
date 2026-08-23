#!/bin/bash
# scripts/utils/setup_engine_shims.sh — generate bin/docker & bin/docker-compose
# shims that route every container CLI call through CONTAINER_ENGINE (.env).
#
#   CONTAINER_ENGINE=docker  → pass-through shims (behavior identical to today)
#   CONTAINER_ENGINE=podman  → docker→podman, docker-compose→podman-compose
#
# The Makefile prepends ./bin to PATH for every recipe, and common.sh does the
# same for standalone script runs — so the whole project follows the selection
# without touching individual call sites.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/.env"

ENGINE="docker"
if [ -f "$ENV_FILE" ]; then
    ENGINE=$(grep -E '^CONTAINER_ENGINE=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
ENGINE="${ENGINE:-docker}"

case "$ENGINE" in
    docker|podman) : ;;
    *) echo "Unsupported CONTAINER_ENGINE='$ENGINE' (use docker|podman)" >&2; exit 1 ;;
esac

mkdir -p "$ROOT/bin"

if [ "$ENGINE" = "docker" ]; then
    # Record ABSOLUTE paths at generation time: a pass-through shim named
    # `docker` living earlier in PATH than the real binary would otherwise
    # recurse into itself.
    #
    # NEVER record a target inside $ROOT/bin — that would be a shim pointing
    # at a shim (infinite exec loop). Resolve past our own shims.
    resolve_outside_bin() {
        local name="$1" p
        while read -r p; do
            case "$p" in "$ROOT/bin/"*) continue ;; esac
            [ -x "$p" ] && { printf '%s' "$p"; return 0; }
        done < <(type -a "$name" 2>/dev/null | awk '{print $NF}')
        return 1
    }
    DOCKER_BIN="$(resolve_outside_bin docker)" || {
        echo "CONTAINER_ENGINE=docker but no docker CLI found outside bin/" >&2
        exit 1
    }
    DCOMPOSE_BIN="$(resolve_outside_bin docker-compose || true)"
    printf '#!/bin/sh\nexec %q "$@"\n' "$DOCKER_BIN"                     > "$ROOT/bin/docker"
    if [ -n "$DCOMPOSE_BIN" ]; then
        printf '#!/bin/sh\nexec %q "$@"\n' "$DCOMPOSE_BIN"               > "$ROOT/bin/docker-compose"
    else
        # legacy binary absent → route through the v2 plugin
        printf '#!/bin/sh\nexec %q compose "$@"\n' "$DOCKER_BIN"         > "$ROOT/bin/docker-compose"
    fi
else
    cat > "$ROOT/bin/docker" <<'EOF'
#!/bin/sh
# docker -> podman shim (project engine selection)
case "${1:-}" in
    compose)
        shift
        if command -v podman-compose >/dev/null 2>&1; then
            exec podman-compose "$@"
        fi
        exec podman compose "$@"
        ;;
esac
exec podman "$@"
EOF
    cat > "$ROOT/bin/docker-compose" <<'EOF'
#!/bin/sh
# docker-compose -> podman-compose shim (project engine selection)
if command -v podman-compose >/dev/null 2>&1; then
    exec podman-compose "$@"
fi
exec podman compose "$@"
EOF
fi

chmod +x "$ROOT/bin/docker" "$ROOT/bin/docker-compose" 
echo "Container engine shims ready: $ENGINE (bin/docker, bin/docker-compose)"
