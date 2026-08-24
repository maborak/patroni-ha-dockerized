#!/bin/bash
# scripts/testing/smoke_test_templates.sh — contract test between
# templates/*.tpl placeholders and the code that substitutes them.
#
# Regression for: __ARCHIVE_COMMAND__/__RESTORE_COMMAND__/__ARCHIVE_MODE__
# added to templates/patroni.yml.tpl without matching entries in the
# entrypoint's substitution map → nodes crashed at startup with
# '__RESTORE_COMMAND__: not found'.
#
# Usage: bash scripts/testing/smoke_test_templates.sh  (part of make smoke-test)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; shift; for c in "$@"; do echo "$c" | sed 's/^/        /'; done; FAILURES=$((FAILURES + 1)); }

TPL="$ROOT/templates/patroni.yml.tpl"
EP="$ROOT/patroni/entrypoint.sh"

# Placeholders used by the template
tpl_vars=$(grep -oE '__[A-Z_]+__' "$TPL" | sort -u)

# Keys the entrypoint knows how to substitute
sub_keys=$(grep -oE "'__[A-Z_]+__'" "$EP" | tr -d "'" | sort -u)

echo ""
echo "── patroni.yml.tpl ↔ entrypoint subs map ──"

MISSING=$(comm -23 <(echo "$tpl_vars") <(echo "$sub_keys"))
if [ -z "$MISSING" ]; then
    pass "every template placeholder has an entrypoint substitution"
else
    fail "placeholders with NO entrypoint substitution:" \
        "$MISSING" \
        "(add them to the subs map in patroni/entrypoint.sh)"
fi

# The backup-tooling trio must exist explicitly (intent documentation)
for v in __ARCHIVE_MODE__ __ARCHIVE_COMMAND__ __RESTORE_COMMAND__; do
    echo "$sub_keys" | grep -qx "$v" \
        && pass "subs map covers $v" \
        || fail "subs map missing $v"
done

# Simulate the render: nothing double-underscore may survive
LEFTOVER=$(python3 - "$TPL" "$EP" <<'PY'
import os, re, sys
subs_src = open(sys.argv[2]).read()
keys = re.findall(r"'(__[A-Z_]+__)'\s*:", subs_src)
text = open(sys.argv[1]).read()
for k in keys:
    text = text.replace(k, "<value>")
left = sorted(set(re.findall(r'__[A-Z_]+__', text)))
print("\n".join(left))
PY
)
if [ -z "$LEFTOVER" ]; then
    pass "simulated render leaves no unresolved placeholders"
else
    fail "unresolved placeholders after simulated render:" "$LEFTOVER"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Templates smoke test PASSED."
    exit 0
else
    echo "Templates smoke test FAILED: $FAILURES check(s) failed."
    exit 1
fi
