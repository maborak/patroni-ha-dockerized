#!/bin/bash
# scripts/utils/show_versions.sh — display configured vs supported software
# versions (powers `make versions`). Read-only; never modifies anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/versions.sh"

echo "=== Software Versions ==="
printf "  %-11s %-14s %-14s %s\n" "COMPONENT" "CONFIGURED" "DEFAULT" "SUPPORTED"
for comp in POSTGRES PATRONI ETCD HAPROXY PGBOUNCER PGBADGER; do
    key="${comp}_VERSION"
    configured="${!key:-}"
    if [ -z "$configured" ]; then
        configured="(unset)"
    elif canon=$(canonical_version "$comp" "$configured" 2>/dev/null); then
        [ "$configured" = "$canon" ] || configured="${configured} (= ${canon})"
    else
        configured="${configured} ✗"
    fi
    printf "  %-11s %-14s %-14s %s\n" \
        "$comp" "$configured" "$(default_version "$comp")" "$(supported_versions "$comp")"
done
echo ""
echo "  ✗ = configured value is NOT supported (config generation will refuse it)"
echo ""
echo "  Registry:  scripts/lib/versions.sh"
echo "  Change:    edit .env (or run 'make wizard') — then 'make up'"
echo "  Notes:     POSTGRES_VERSION / ETCD_VERSION changes on an existing cluster"
echo "             require 'make destroy' + fresh bootstrap."
