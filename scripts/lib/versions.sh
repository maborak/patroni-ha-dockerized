#!/bin/bash
# scripts/lib/versions.sh — Supported software-version registry.
#
# Single source of truth for every component version this stack supports.
# Sourced by generate_configs.sh (fail-fast validation), the setup wizard
# (interactive validation), and `make versions` (display).
#
# A version NOT listed here is rejected with an error — even if a matching
# image tag exists upstream — because only listed combinations are tested
# with this stack (Patroni ↔ PG, Backup ↔ PG, etcd ↔ Patroni DCS, ...).
#
# When adding support for a new upstream release:
#   1. Verify the exact image tag exists (quay.io / docker hub)
#   2. Add it to SUPPORTED_*_VERSIONS below
#   3. Bump DEFAULT_*_VERSIONS if it should become the default
#   4. Run: make smoke-test

# --- PostgreSQL major versions ---------------------------------------------
# Floor is 15: the stack requires jsonlog logging (PG15+) and data-checksums.
# Changing POSTGRES_VERSION on an existing cluster requires destroy + rebootstrap.
SUPPORTED_POSTGRES_VERSIONS="15 16 17 18"
DEFAULT_POSTGRES_VERSION=18

# --- Patroni (exact releases; installed via pip in patroni/Dockerfile) ------
SUPPORTED_PATRONI_VERSIONS="4.1.5"
DEFAULT_PATRONI_VERSION=4.1.5

# --- etcd (quay.io/coreos/etcd tags) ----------------------------------------
# Changing ETCD_VERSION requires destroy + rebootstrap (DCS state lives in volumes).
SUPPORTED_ETCD_VERSIONS="v3.7.1 v3.5.17"
DEFAULT_ETCD_VERSION=v3.7.1

# --- HAProxy (docker branch tags: haproxy:<major.minor>) ---------------------
SUPPORTED_HAPROXY_VERSIONS="3.4 3.2 3.0 2.8"
DEFAULT_HAPROXY_VERSION=3.4

# --- PgBouncer (edoburu/pgbouncer tags; note the v...-p0 suffix format) ------
SUPPORTED_PGBOUNCER_VERSIONS="v1.25.2-p0 v1.25.1-p0"
DEFAULT_PGBOUNCER_VERSION=v1.25.2-p0

# --- pgBadger (github.com/darold/pgbadger release tags, without the v) -------
SUPPORTED_PGBADGER_VERSIONS="13.2 12.4"
DEFAULT_PGBADGER_VERSION=13.2

# ============================================================================
# API (component names are uppercase, e.g. POSTGRES, PATRONI, ETCD,
# HAPROXY, PGBOUNCER, PGBADGER):
#
#   supported_versions POSTGRES       -> "15 16 17 18"
#   default_version POSTGRES          -> 18
#   is_version_supported POSTGRES 17  -> rc 0/1
#   canonical_version ETCD 3.7.1      -> "v3.7.1"  (registry tag spelling)
#   validate_version_or_die POSTGRES 17 -> dies w/ message; exports CANONICAL value
#
# Loose input is accepted and normalized: leading v/V and an -pNN build
# suffix are ignored for comparison, so "3.7.1", "v3.7.1" and "1.25.2"
# are all valid ways to type the canonical tags "v3.7.1" / "v1.25.2-p0".
# ============================================================================

_registry_var() {
    # component -> name of its registry variable (e.g. SUPPORTED_POSTGRES_VERSIONS)
    local comp="$1"
    printf 'SUPPORTED_%s_VERSIONS' "$(echo "$comp" | tr '[:lower:]' '[:upper:]')"
}

supported_versions() {
    local var
    var=$(_registry_var "$1")
    echo "${!var:-}"
}

default_version() {
    local var
    var="$(_registry_var "$1")"
    # SUPPORTED_<COMP>_VERSIONS -> DEFAULT_<COMP>_VERSION
    var="${var/SUPPORTED_/DEFAULT_}"
    var="${var%?}"
    echo "${!var:-}"
}

# Comparable form of a version string: no leading v/V, no -pNN suffix.
_normalize_version() {
    local v="$1"
    v="${v#v}"; v="${v#V}"
    echo "${v%%-p*}"
}

# Registry tag matching the given (possibly loose) version; rc 1 if unsupported.
canonical_version() {
    local comp="$1" want="$2" want_key v
    [ -n "$want" ] || return 1
    want_key=$(_normalize_version "$want")
    for v in $(supported_versions "$comp"); do
        [ "$(_normalize_version "$v")" = "$want_key" ] && { echo "$v"; return 0; }
    done
    return 1
}

is_version_supported() {
    canonical_version "$1" "$2" >/dev/null
}

validate_version_or_die() {
    local comp="$1" value="${2:-}" canon red nc
    red=$'\033[0;31m'; yellow=$'\033[1;33m'; nc=$'\033[0m'
    if [ -z "$value" ]; then
        canon=$(default_version "$comp")
        [ -n "$canon" ] || { echo "${red}ERROR:${nc} no default version registered for ${comp}" >&2; exit 1; }
    else
        canon=$(canonical_version "$comp" "$value") || canon=""
    fi
    if [ -z "$canon" ]; then
        echo "" >&2
        echo "${red}ERROR: unsupported ${comp} version '${value}'.${nc}" >&2
        echo "       Supported ${comp} versions: $(supported_versions "$comp")" >&2
        echo "       (spellings like '3.7.1' or 'v3.7.1' are both fine where applicable)" >&2
        echo "       The supported list lives in scripts/lib/versions.sh — only tested" >&2
        echo "       combinations are allowed. Run 'make versions' to inspect." >&2
        exit 1
    fi
    # Export the CANONICAL registry tag so consumers never see loose spellings.
    export "${comp}_VERSION=${canon}"
}
