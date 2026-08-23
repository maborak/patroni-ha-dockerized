#!/bin/sh
# pgbadger/collect.sh — one collection cycle (run by cron and at container start).
#
# For every DB node whose logs are mounted under /logs/dbN:
#   1. COPY finished JSON log files (older than the safety window) into raw/
#   2. verify the copy, then DELETE the source file on the DB node (cleanup)
#   3. prune raw copies beyond PGBADGER_RETENTION_DAYS
#   4. regenerate the cluster-wide report (reports/index.html) from all raw logs
#   5. archive a timestamped copy (reports/archive/report_YYYY-MM-DD_HH-MM.html)
#   6. regenerate reports/list.html — a browsable index of all reports
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

# --- Archive a timestamped copy so historical reports survive ---
ARCHIVE_DIR="$REPORTS/archive"
mkdir -p "$ARCHIVE_DIR"
STAMP=$(date -u '+%Y-%m-%d_%H-%M')
ARCHIVE_FILE="$ARCHIVE_DIR/report_${STAMP}.html"
if [ -f "$REPORTS/index.html" ]; then
    cp "$REPORTS/index.html" "$ARCHIVE_FILE"
    log "archived report → $ARCHIVE_FILE"
fi

# Prune archives beyond retention window
if [ "$RETENTION_DAYS" -gt 0 ]; then
    find "$ARCHIVE_DIR" -type f -name 'report_*.html' -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi

# --- Generate a browsable listing page ---
LIST_FILE="$REPORTS/list.html"
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

# Collect all reports: current + archived, sorted by mtime descending.
# We write one line per report to BODY_FILE: "epoch|label|size|path"
REPORT_COUNT=0
TOTAL_SIZE=0

# Current report (index.html)
if [ -f "$REPORTS/index.html" ]; then
    MTIME=$(stat -c '%Y' "$REPORTS/index.html" 2>/dev/null || stat -f '%m' "$REPORTS/index.html" 2>/dev/null || echo 0)
    MSIZE=$(wc -c < "$REPORTS/index.html" 2>/dev/null || echo 0)
    echo "${MTIME}|Latest Report|${MSIZE}|index.html" >> "$BODY_FILE"
    TOTAL_SIZE=$((TOTAL_SIZE + MSIZE))
    REPORT_COUNT=$((REPORT_COUNT + 1))
fi

# Archived reports
if [ -d "$ARCHIVE_DIR" ]; then
    for f in $(ls -1t "$ARCHIVE_DIR"/report_*.html 2>/dev/null || true); do
        [ -f "$f" ] || continue
        ftime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
        fsize=$(wc -c < "$f" 2>/dev/null || echo 0)
        echo "${ftime}||${fsize}|archive/$(basename "$f")" >> "$BODY_FILE"
        TOTAL_SIZE=$((TOTAL_SIZE + fsize))
        REPORT_COUNT=$((REPORT_COUNT + 1))
    done
fi

# Human-readable size helper
fmt_size() {
    _b=${1:-0}
    [ "$_b" -ge 0 ] 2>/dev/null || _b=0
    if [ "$_b" -ge 1048576 ]; then
        echo "$((_b / 1048576)) MB"
    elif [ "$_b" -ge 1024 ]; then
        echo "$((_b / 1024)) KB"
    else
        echo "${_b} B"
    fi
}

# Day-label helper: returns a grouping label for a given epoch
#   Today / Yesterday / Mon 18 Aug / etc.
today_epoch=$(date -u '+%s')
today_midnight=$(TZ=UTC date -u -d "$(date -u '+%Y-%m-%d') 00:00:00" '+%s' 2>/dev/null \
    || TZ=UTC date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s' 2>/dev/null || echo 0)
yesterday_midnight=$((today_midnight - 86400))
week_midnight=$((today_midnight - 6 * 86400))

day_label() {
    _e=$1
    if [ "$_e" -ge "$today_midnight" ]; then
        echo "Today"
    elif [ "$_e" -ge "$yesterday_midnight" ]; then
        echo "Yesterday"
    elif [ "$_e" -ge "$week_midnight" ]; then
        date -u -d @"$_e" '+%A %e %B' 2>/dev/null || date -u -r "$_e" '+%A %e %B' 2>/dev/null || echo "This week"
    else
        date -u -d @"$_e" '+%e %B %Y' 2>/dev/null || date -u -r "$_e" '+%e %B %Y' 2>/dev/null || echo "Older"
    fi
}

# --- Build the HTML ---
cat > "$BODY_FILE.header" <<'HEADEREOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>pgBadger — Report History</title>
<style>
  :root {
    --bg: #f8f9fa; --card: #fff; --border: #e2e8f0;
    --text: #1a202c; --muted: #718096; --accent: #2b6cb0;
    --accent-light: #ebf4ff; --green: #276749; --green-bg: #f0fff4;
    --tag-bg: #edf2f7; --tag-text: #4a5568;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.5;
  }
  .container { max-width: 960px; margin: 0 auto; padding: 2rem 1.5rem; }

  /* Header */
  .header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 1rem; margin-bottom: 2rem; }
  .header h1 { font-size: 1.5rem; font-weight: 700; }
  .header h1 span { color: var(--accent); }
  .header-nav { display: flex; gap: .75rem; }
  .btn {
    display: inline-flex; align-items: center; gap: .4rem;
    padding: .5rem 1rem; border-radius: .375rem; font-size: .875rem;
    font-weight: 500; text-decoration: none; border: 1px solid var(--border);
    background: var(--card); color: var(--text); transition: all .15s;
  }
  .btn:hover { border-color: var(--accent); color: var(--accent); }
  .btn-primary { background: var(--accent); color: #fff; border-color: var(--accent); }
  .btn-primary:hover { background: #2c5282; }

  /* Stats bar */
  .stats {
    display: flex; gap: 2rem; padding: 1rem 1.25rem;
    background: var(--card); border: 1px solid var(--border); border-radius: .5rem;
    margin-bottom: 2rem; flex-wrap: wrap;
  }
  .stat { display: flex; flex-direction: column; }
  .stat-value { font-size: 1.25rem; font-weight: 700; color: var(--accent); }
  .stat-label { font-size: .75rem; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }

  /* Day groups */
  .day-group { margin-bottom: 2rem; }
  .day-header {
    display: flex; align-items: center; gap: .75rem;
    font-size: .8rem; font-weight: 600; text-transform: uppercase;
    letter-spacing: .04em; color: var(--muted); margin-bottom: .75rem;
    padding-bottom: .5rem; border-bottom: 1px solid var(--border);
  }
  .day-header .count {
    background: var(--tag-bg); color: var(--tag-text);
    padding: .15rem .5rem; border-radius: .75rem; font-size: .7rem;
  }

  /* Report cards */
  .report-list { display: flex; flex-direction: column; gap: .5rem; }
  .report-row {
    display: grid; grid-template-columns: auto 1fr auto auto;
    align-items: center; gap: 1rem;
    padding: .75rem 1rem; background: var(--card);
    border: 1px solid var(--border); border-radius: .375rem;
    text-decoration: none; color: var(--text); transition: all .15s;
  }
  .report-row:hover { border-color: var(--accent); box-shadow: 0 1px 3px rgba(0,0,0,.06); }
  .report-row.current { border-left: 3px solid var(--green); background: var(--green-bg); }
  .report-time { font-size: .875rem; font-weight: 600; font-variant-numeric: tabular-nums; min-width: 5rem; }
  .report-label { font-size: .875rem; color: var(--muted); }
  .report-label .tag {
    display: inline-block; font-size: .7rem; font-weight: 600; text-transform: uppercase;
    background: var(--green-bg); color: var(--green); padding: .1rem .4rem;
    border-radius: .25rem; margin-right: .4rem; vertical-align: middle;
  }
  .report-size { font-size: .8rem; color: var(--muted); font-variant-numeric: tabular-nums; text-align: right; min-width: 4rem; }
  .report-arrow { color: var(--border); font-size: 1rem; }
  .report-row:hover .report-arrow { color: var(--accent); }

  /* Empty state */
  .empty { text-align: center; padding: 4rem 1rem; color: var(--muted); }
  .empty-icon { font-size: 3rem; margin-bottom: 1rem; }

  /* Footer */
  .footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); font-size: .75rem; color: var(--muted); text-align: center; }
</style>
</head>
<body>
<div class="container">
HEADEREOF

cat > "$BODY_FILE.body" <<EOF
<div class="header">
  <h1><span>pgBadger</span> Report History</h1>
  <div class="header-nav">
    <a href="index.html" class="btn btn-primary">Latest Report</a>
    <a href="list.html" class="btn">Refresh</a>
  </div>
</div>
<div class="stats">
  <div class="stat"><span class="stat-value">${REPORT_COUNT}</span><span class="stat-label">Reports</span></div>
  <div class="stat"><span class="stat-value">$(fmt_size $TOTAL_SIZE)</span><span class="stat-label">Total Size</span></div>
  <div class="stat"><span class="stat-value">${RETENTION_DAYS}d</span><span class="stat-label">Retention</span></div>
  <div class="stat"><span class="stat-value">${JOBS}</span><span class="stat-label">Parse Jobs</span></div>
</div>
EOF

if [ "$REPORT_COUNT" -eq 0 ]; then
    cat >> "$BODY_FILE.body" <<'EMPTYEOF'
<div class="empty">
  <div class="empty-icon">📊</div>
  <p>No reports generated yet.</p>
  <p style="margin-top:.5rem;font-size:.85rem;">Reports appear after the first pgBadger collection cycle.</p>
</div>
EMPTYEOF
else
    # --- Group reports by day ---
    # Sort the collected lines by epoch descending (column 1)
    SORTED_FILE=$(mktemp)
    sort -t'|' -k1 -rn "$BODY_FILE" > "$SORTED_FILE"
    CURRENT_DAY=""
    TABLE_OPEN=0

    while IFS='|' read -r _epoch _label _size _path; do
        [ -z "$_epoch" ] && continue
        _day=$(day_label "$_epoch")
        _time=$(date -u -d @"$_epoch" '+%H:%M' 2>/dev/null || date -u -r "$_epoch" '+%H:%M' 2>/dev/null || echo '??:??')
        _sz=$(fmt_size "$_size")
        _tag=""
        [ "$_label" = "Latest Report" ] && _tag="<span class=\"tag\">Latest</span>"
        _row_class="report-row"
        [ "$_label" = "Latest Report" ] && _row_class="report-row current"

        if [ "$_day" != "$CURRENT_DAY" ]; then
            if [ "$TABLE_OPEN" -eq 1 ]; then
                echo '  </div>' >> "$BODY_FILE.body"
                echo '</div>' >> "$BODY_FILE.body"
            fi
            CURRENT_DAY="$_day"
            echo "<div class=\"day-group\">" >> "$BODY_FILE.body"
            echo "  <div class=\"day-header\">${_day}</div>" >> "$BODY_FILE.body"
            echo '  <div class="report-list">' >> "$BODY_FILE.body"
            TABLE_OPEN=1
        fi

        cat >> "$BODY_FILE.body" <<ROWEOF
    <a href="${_path}" class="${_row_class}">
      <span class="report-time">${_time}</span>
      <span class="report-label">${_tag}${_label:-$(basename "${_path}")}</span>
      <span class="report-size">${_sz}</span>
      <span class="report-arrow">→</span>
    </a>
ROWEOF
    done < "$SORTED_FILE"
    rm -f "$SORTED_FILE"

    # Close last day group
    if [ "$TABLE_OPEN" -eq 1 ]; then
        echo '  </div>' >> "$BODY_FILE.body"
        echo '</div>' >> "$BODY_FILE.body"
    fi
fi

# Assemble final HTML
cat "$BODY_FILE.header" "$BODY_FILE.body" > "$LIST_FILE"
cat >> "$LIST_FILE" <<'FOOTEREOF'
<div class="footer">
  pgBadger report archive &middot; Reports older than retention are pruned automatically<br>
  <a href="index.html" style="color:var(--accent);">Latest Report</a>
</div>
</div>
</body>
</html>
FOOTEREOF

rm -f "$BODY_FILE.header" "$BODY_FILE.body"
log "listing page updated ($REPORT_COUNT reports)"
