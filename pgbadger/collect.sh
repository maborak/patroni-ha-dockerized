#!/bin/sh
# pgbadger/collect.sh — one collection cycle (run by cron and at container start).
#
# For every DB node whose logs are mounted under /logs/dbN:
#   1. COPY finished JSON log files (older than the safety window) into raw/
#   2. verify the copy, then DELETE the source file on the DB node (cleanup)
#   3. prune raw copies beyond PGBADGER_RETENTION_DAYS
#   4. regenerate the cluster-wide report (reports/index.html) from all raw logs
#
# The safety window (PGBADGER_SAFETY_MINUTES) guarantees we never touch a file
# the logging collector may still have open — only finalized rotations are pulled.
set -eu

RAW=/var/lib/pgbadger/raw
REPORTS=/var/lib/pgbadger/reports
RETENTION_DAYS="${PGBADGER_RETENTION_DAYS:-7}"
JOBS="${PGBADGER_JOBS:-4}"
SAFETY_MIN="${PGBADGER_SAFETY_MINUTES:-10}"
TITLE="${PGBADGER_TITLE:-PostgreSQL HA cluster}"

mkdir -p "$RAW" "$REPORTS"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')] $*"; }

log "collection cycle started (safety window: ${SAFETY_MIN}m, retention: ${RETENTION_DAYS}d)"

pulled=0
cleaned=0

for dir in /logs/db*/; do
    [ -d "$dir" ] || continue
    node="$(basename "$dir")"
    mkdir -p "$RAW/$node"

    # '*.json' matches both modern .json files and legacy .json.json files;
    # plain-text stderr logs (no extension) are ignored.
    for f in "$dir"*.json; do
        [ -f "$f" ] || continue
        # skip files still inside the safety window (collector may hold them open)
        if [ -n "$(find "$f" -mmin -"$SAFETY_MIN" 2>/dev/null)" ]; then
            continue
        fi
        base="$(basename "$f")"
        dest="$RAW/$node/$base"
        if [ -e "$dest" ]; then
            # already pulled on a previous cycle but not yet cleaned on the node
            if cmp -s "$f" "$dest"; then
                rm -f "$f"
                cleaned=$((cleaned + 1))
                log "cleaned already-pulled $node/$base"
            fi
            continue
        fi
        if cp "$f" "$dest" && cmp -s "$f" "$dest"; then
            rm -f "$f"
            pulled=$((pulled + 1))
            cleaned=$((cleaned + 1))
            log "pulled + cleaned $node/$base"
        else
            rm -f "$dest"
            log "WARN: copy verification failed, keeping source $node/$base"
        fi
    done
done

# Prune raw copies beyond the retention window
if [ "$RETENTION_DAYS" -gt 0 ]; then
    find "$RAW" -type f -name '*.json*' -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi

# Regenerate the cluster-wide report from all retained raw logs
set --
for f in "$RAW"/*/*.json; do
    [ -f "$f" ] && set -- "$@" "$f"
done

if [ "$#" -gt 0 ]; then
    if pgbadger -f jsonlog -j "$JOBS" -T "$TITLE" -o "$REPORTS/index.html" "$@"; then
        log "report regenerated from $# file(s) (new this cycle: $pulled, cleaned: $cleaned)"
    else
        log "ERROR: pgbadger failed — raw logs kept, sources on nodes already cleaned only when verified"
        exit 1
    fi
else
    log "no log files collected yet — nothing to parse"
fi
