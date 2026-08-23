#!/bin/bash
# scripts/utils/running_versions.sh — probe the RUNNING software versions from
# the containers and print a compact section (powers the versions block of
# `make status`). Read-only; safe on a stopped stack (prints "not running").

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

container_up() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1\$"
}

# exec_in CT -- ARGS... -> stdout or empty when container down/exec fails
exec_in() {
    local ct="$1"; shift
    container_up "$ct" || return 0
    docker exec "$@" 2>/dev/null || true
}

first_field()  { awk '{print $1; exit}'; }
field()        { awk -v n="$1" '{print $n; exit}'; }

# PostgreSQL (exact server version, first field of "18.6 (Debian ...)")
PG_VER=$(exec_in db1 -u postgres db1 psql -p 5431 -t -A -c "SHOW server_version;" | first_field)
# Patroni ("patroni 4.1.5")
PA_VER=$(exec_in db1 db1 patroni --version | field 2)
# etcd ("etcd Version: v3.7.1")
ET_VER=$(exec_in etcd1 etcd1 etcd --version | awk '/etcd Version/{print $3; exit}')
# HAProxy ("HAProxy version 2.8.27-... 2026/07/29")
HA_VER=$(exec_in haproxy haproxy haproxy -v | field 3)
# PgBouncer ("PgBouncer 1.25.2")
PB_VER=$(exec_in pgbouncer pgbouncer pgbouncer --version | field 2)
# Barman ("3.19.1 Barman by EnterpriseDB (...)")
BA_VER=$(exec_in barman barman barman --version | field 1)
# pgBadger ("pgBadger version 13.2")
GB_VER=$(exec_in pgbadger pgbadger pgbadger --version | field 3)

[ -n "$PG_VER" ] || PG_VER="(not running)"
[ -n "$PA_VER" ] || PA_VER="(not running)"
[ -n "$ET_VER" ] || ET_VER="(not running)"
[ -n "$HA_VER" ] || HA_VER="(not running)"
[ -n "$PB_VER" ] || PB_VER="(not running)"
[ -n "$BA_VER" ] || BA_VER="(not running)"
[ -n "$GB_VER" ] || GB_VER="(not running)"

echo "=== Software Versions (running) ==="
printf "  %-11s %s\n" "PostgreSQL" "$PG_VER"
printf "  %-11s %s\n" "Patroni"    "$PA_VER"
printf "  %-11s %s\n" "etcd"       "$ET_VER"
printf "  %-11s %s\n" "HAProxy"    "$HA_VER"
printf "  %-11s %s\n" "PgBouncer"  "$PB_VER"
printf "  %-11s %s\n" "Barman"     "$BA_VER"
printf "  %-11s %s\n" "pgBadger"   "$GB_VER"
echo "  Supported/configured: make versions"
