#!/bin/sh
# pgbadger/entrypoint.sh — start the web UI + the cron scheduler.
#
# Services provided by this container:
#   * busybox httpd  — serves the generated pgBadger HTML report on :80
#   * busybox crond  — runs collect.sh on the PGBADGER_CRON_EXPRESSION schedule
set -eu

RAW=/var/lib/pgbadger/raw
REPORTS=/var/lib/pgbadger/reports
ARCHIVE="$REPORTS/archive"
mkdir -p "$RAW" "$REPORTS" "$ARCHIVE"

CRON="${PGBADGER_CRON_EXPRESSION:-*/30 * * * *}"
TZ="${PGBADGER_TZ:-UTC}"
export TZ

# Install the crontab (alpine's busybox crond reads /etc/crontabs/root)
echo "CRON_TZ=${TZ}
${CRON} /usr/local/bin/collect.sh >> /var/lib/pgbadger/cron.log 2>&1
" > /etc/crontabs/root

# Serve the reports directory (index.html = latest cluster-wide report);
# plant placeholders so the healthcheck passes before the first report exists.
if [ ! -f "$REPORTS/index.html" ]; then
    cat > "$REPORTS/index.html" <<'HTMLEOF'
<!DOCTYPE html><html><head><title>pgBadger</title></head>
<body><h1>pgBadger</h1><p>No reports yet — waiting for the first collection cycle.</p></body></html>
HTMLEOF
fi
if [ ! -f "$REPORTS/list.html" ]; then
    cat > "$REPORTS/list.html" <<'LISTEOF'
<!DOCTYPE html><html><head><title>pgBadger — Report History</title></head>
<body><h1>pgBadger — Report History</h1><p>No reports yet — waiting for the first collection cycle.</p></body></html>
LISTEOF
fi
darkhttpd "$REPORTS" --port 80 &

# First collection at boot so the UI has content immediately
if [ "${PGBADGER_RUN_ON_START:-1}" = "1" ]; then
    /usr/local/bin/collect.sh >> /var/lib/pgbadger/cron.log 2>&1 || true
fi

echo "pgBadger container up: UI on :80, cron='${CRON}' (${TZ}), retention=${PGBADGER_RETENTION_DAYS:-7}d"
exec crond -f -l 8
