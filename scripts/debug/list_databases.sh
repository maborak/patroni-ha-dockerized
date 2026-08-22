#!/bin/bash
# scripts/debug/list_databases.sh — List databases on the cluster leader (or a specified node)
#
# Usage:
#   bash scripts/debug/list_databases.sh                       # leader, human-readable
#   bash scripts/debug/list_databases.sh --node db2            # specific node
#   bash scripts/debug/list_databases.sh --json                # machine-readable
#   bash scripts/debug/list_databases.sh --include-templates   # include template0/template1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

NODE=""
FORMAT="human"
INCLUDE_TEMPLATES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --node)
            NODE="$2"
            shift 2
            ;;
        --json)
            FORMAT="json"
            shift
            ;;
        --include-templates)
            INCLUDE_TEMPLATES=true
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--node dbN] [--json] [--include-templates]

Options:
  --node dbN              Query a specific node (default: auto-detect leader)
  --json                  Emit JSON instead of human-readable output
  --include-templates     Include template0 / template1 in the listing
  -h, --help              Show this help

Examples:
  $0
  $0 --node db2
  $0 --json | jq '.[] | .name'
EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}" >&2
            exit 1
            ;;
    esac
done

if [ -z "$NODE" ]; then
    [ "$FORMAT" = "human" ] && echo -e "${YELLOW}Detecting cluster leader...${NC}" >&2
    NODE=$(detect_leader)
    [ "$FORMAT" = "human" ] && echo -e "${GREEN}✓ Leader: ${NODE}${NC}" >&2
else
    validate_node "$NODE" || exit 1
fi

INTERNAL_PORT=$(get_internal_pg_port)

TEMPLATE_FILTER=""
if [ "$INCLUDE_TEMPLATES" = false ]; then
    TEMPLATE_FILTER="WHERE d.datistemplate = false"
fi

if [ "$FORMAT" = "json" ]; then
    QUERY="SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
        SELECT
            d.datname AS name,
            pg_catalog.pg_get_userbyid(d.datdba) AS owner,
            pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
            d.datcollate AS collation,
            pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(d.datname)) AS size,
            pg_catalog.pg_database_size(d.datname)::text AS size_bytes,
            d.datistemplate AS is_template,
            d.datallowconn AS allow_conn
        FROM pg_catalog.pg_database d
        ${TEMPLATE_FILTER}
        ORDER BY d.datname
    ) t;"
    docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A -c "$QUERY"
    exit $?
fi

QUERY="SELECT
    d.datname AS name,
    pg_catalog.pg_get_userbyid(d.datdba) AS owner,
    pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
    d.datcollate AS collation,
    pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(d.datname)) AS size
FROM pg_catalog.pg_database d
${TEMPLATE_FILTER}
ORDER BY d.datname;"

echo ""
echo -e "${BLUE}${BOLD}Databases on ${NODE}${NC}"
echo ""
docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -c "$QUERY"
