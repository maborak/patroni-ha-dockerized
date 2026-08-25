#!/usr/bin/env python3
"""Builds every Grafana dashboard for the patroni-ha stack into grafana/dashboards/.

Run from repo root:  python3 monitoring/build_dashboards.py
Dashboards are provisioned by Grafana automatically (grafana/provisioning).
"""
import json
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "grafana", "dashboards")
DS = {"type": "prometheus", "uid": "prom"}
FOLDER = "PostgreSQL HA"

_pid = [1000]
def _id():
    _pid[0] += 1
    return _pid[0]

def grid(y, h, w, x): return {"h": h, "w": w, "x": x, "y": y}

def stat(title, expr, y, x, w=4, h=4, unit="short", thresholds=None, mappings=None):
    d = {"defaults": {"unit": unit}, "overrides": []}
    if thresholds:
        steps = [{"color": thresholds[0][0], "value": None}]
        steps += [{"color": c, "value": v} for c, v in thresholds[1:]]
        d["thresholds"] = {"mode": "absolute", "steps": steps}
    if mappings: d["mappings"] = mappings
    return {"id": _id(), "title": title, "type": "stat", "gridPos": grid(y, h, w, x),
            "datasource": DS, "targets": [{"expr": expr, "instant": True, "refId": "A"}],
            "fieldConfig": {"defaults": d, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value",
                        "textMode": "auto"}}

def ts(title, targets, y, x, w, h, unit="short", desc=None, stack=False):
    norm = []
    for i, t in enumerate(targets):
        e, l = (t, "") if isinstance(t, str) else t
        norm.append({"expr": e, "legendFormat": l, "refId": chr(65 + i)})
    p = {"id": _id(), "title": title, "type": "timeseries", "gridPos": grid(y, h, w, x),
         "datasource": DS, "targets": norm,
         "fieldConfig": {"defaults": {"unit": unit,
                                      "custom": {"fillOpacity": 12, "lineWidth": 1}},
                         "overrides": []},
         "options": {"legend": {"displayMode": "table", "placement": "bottom",
                                "calcs": ["lastNotNull", "max"]}}}
    if stack: p["options"]["legend"] = p["options"]["legend"]; p["fieldConfig"]["defaults"]["custom"]["stacking"] = {"mode": "normal"}
    if desc: p["description"] = desc
    return p

def table(title, expr, y, x, w, h, sort_desc=True):
    return {"id": _id(), "title": title, "type": "table", "gridPos": grid(y, h, w, x),
            "datasource": DS,
            "targets": [{"expr": expr, "instant": True, "format": "table", "refId": "A"}],
            "transformations": [
                {"id": "organize", "options": {"excludeByName": {"Time": True, "__name__": True, "job": True}}},
                {"id": "sorting", "options": {"sort": [{"field": "Value #A", "desc": sort_desc}]}}],
            "options": {"showHeader": True}}

def row(title, y):
    return {"id": _id(), "title": title, "type": "row", "gridPos": grid(y, 1, 24, x=0)}

def dash(uid, num, title, desc, tags, panels, templating=None):
    d = {"uid": uid, "title": f"{num} · {title}", "description": desc,
         "tags": tags + ["patroni-ha"], "timezone": "utc", "schemaVersion": 39,
         "version": 1, "refresh": "30s", "time": {"from": "now-3h", "to": "now"},
         "panels": panels}
    if templating: d["templating"] = {"list": templating}
    return d

def write(d):
    name = d["uid"].split("-")[-1] + ".json"
    path = os.path.join(OUT, f"{d['title'].split(' · ')[0]}-{name}")
    json.dump(d, open(path, "w"), indent=1)
    print("wrote", os.path.basename(path), "| panels:", len(d["panels"]))

# ═══════════════ shared expressions ═══════════════
LAG_B   = 'max by (instance)(patroni_xlog_location) - on(instance) (patroni_xlog_replayed_location + 0 * patroni_xlog_location)'
ARCH_ST = 'max(pg_archiver_since_last_archived_seconds)'

# ─────────────────────────────────────────────
# 01 Cluster Overview
# ─────────────────────────────────────────────
P = [
    stat("Nodes up", 'count(up{job="patroni"} == 1)', 0, 0, 4, 4,
         thresholds=[("red"), ("green", 3)]),
    stat("Leader present", 'count(patroni_primary == 1) or vector(0)', 0, 4, 4, 4,
         mappings=[{"type": "value", "options": {
             "1": {"text": "YES", "color": "green"},
             "0": {"text": "NO LEADER", "color": "red"}}}]),
    stat("Max replication lag", LAG_B, 0, 8, 4, 4, unit="bytes",
         thresholds=[("green"), ("yellow", 33554432), ("red", 134217728)]),
    stat("WAL archive staleness (s)", ARCH_ST, 0, 12, 4, 4, unit="s",
         thresholds=[("green"), ("yellow", 300), ("red", 600)]),
    stat("Oldest transaction (s)", 'max(pg_transactions_longest_tx_seconds)', 0, 16, 4, 4,
         unit="s", thresholds=[("green"), ("orange", 300), ("red", 900)]),
    stat("Conn saturation", 'max(pg_activity_connections) / max(pg_activity_max_connections)',
         0, 20, 4, 4, unit="percentunit",
         thresholds=[("green"), ("orange", 0.7), ("red", 0.85)]),
    stat("Host disk free %", 'min(node_filesystem_avail_bytes{fstype=~"xfs|ext4"}) / min(node_filesystem_size_bytes{fstype=~"xfs|ext4"})',
         4, 0, 4, 4, unit="percentunit",
         thresholds=[("red"), ("orange", 0.15), ("green", 0.25)]),
    stat("Firing alerts", 'count(ALERTS{alertstate="firing"} == 1) or vector(0)', 4, 4, 4, 4,
         thresholds=[("green"), ("orange", 1), ("red", 3)]),
    stat("Cluster TPS", 'sum(rate(pg_stat_database_xact_commit{datname="$db"}[1m]))', 4, 8, 4, 4, unit="ops"),
    stat("WAL generation (B/s)", 'sum(deriv(patroni_xlog_location[2m]))', 4, 12, 4, 4, unit="Bps"),
    stat("DB size total", 'sum(pg_database_size_bytes)', 4, 16, 4, 4, unit="bytes"),
    stat("Autovac workers", 'max(pg_transactions_autovacuum_workers_running)', 4, 20, 4, 4),
    table("Firing alerts detail", 'ALERTS{alertstate="firing"} == 1', 8, 0, 12, 7),
    ts("Replication lag (bytes)", [(LAG_B, "{{instance}}")], 8, 12, 12, 7, unit="bytes"),
]
write(dash("patroni-overview", "01", "Cluster Overview",
           "At-a-glance health of the whole HA cluster.", ["overview"], P,
           templating=[{"name": "db", "label": "Database", "type": "query", "datasource": DS,
                        "query": "label_values(pg_database_size_bytes, datname)",
                        "refresh": 1, "includeAll": False,
                        "current": {"text": "maborak", "value": "maborak"}}]))

# ─────────────────────────────────────────────
# 02 Patroni & DCS
# ─────────────────────────────────────────────
P = [
    table("Member topology", 'patroni_postgres_running * on(instance) group_left patroni_primary', 0, 0, 12, 8),
    stat("Primary count", 'count(patroni_primary == 1) or vector(0)', 0, 12, 3, 4,
         mappings=[{"type": "value", "options": {
             "1": {"text": "OK", "color": "green"},
             "0": {"text": "NONE", "color": "red"}}}]),
    stat("Replicas streaming", 'count(patroni_replica == 1)', 0, 15, 3, 4),
    stat("Pending restart nodes", 'count(patroni_pending_restart == 1) or vector(0)', 0, 18, 3, 4,
         thresholds=[("green"), ("yellow", 1)]),
    stat("Failsafe active nodes", 'count(patroni_failsafe_mode_is_active == 1) or vector(0)', 0, 21, 3, 4),
    ts("Timeline per node", [('max by (instance)(patroni_postgres_timeline)', '{{instance}}')], 4, 0, 8, 6),
    ts("DCS last seen (seconds ago)", [('time() - patroni_dcs_last_seen', '{{instance}}')], 4, 8, 8, 6, unit="s"),
    ts("WAL LSN position (bytes)", [('patroni_xlog_location', '{{instance}}')], 4, 16, 8, 6, unit="bytes"),
    ts("Primary start time / leader term age",
       [('time() - patroni_postmaster_start_time', 'leader term age (s)')], 10, 0, 8, 5, unit="s"),
    stat("Paused mode nodes", 'count(patroni_is_paused == 1) or vector(0)', 10, 8, 4, 5,
         mappings=[{"type": "value", "options": {"0": {"text": "no", "color": "green"}}}]),
    stat("Postgres server version (min)",
         'min(patroni_postgres_server_version) / 10000', 10, 12, 4, 5),
    stat("Nodes in archive recovery",
         'count(patroni_postgres_in_archive_recovery == 1) or vector(0)', 10, 16, 4, 5),
    stat("Xlog paused anywhere",
         'count(patroni_xlog_paused == 1) or vector(0)', 10, 20, 4, 5,
         thresholds=[("green"), ("red", 1)]),
]
write(dash("patroni-dcs", "02", "Patroni & DCS",
           "Patroni member states, timeline history, DCS reachability, failover term age.",
           ["patroni"], P))

# ─────────────────────────────────────────────
# 03 Replication & Slots
# ─────────────────────────────────────────────
P = [
    ts("Replication lag (bytes)", [(LAG_B, '{{instance}}')], 0, 0, 12, 8, unit="bytes"),
    ts("Replay delay (seconds)", [('pg_replication_replay_lag_seconds > 0', '{{instance}}')], 0, 12, 6, 8, unit="s"),
    stat("Slots active / total",
         'count(pg_replication_slot_slot_is_active == 1) or vector(0)', 0, 18, 3, 4),
    stat("Slot retaining >2GB WAL",
         'count(pg_replication_slots_pg_wal_lsn_diff > 2147483648) or vector(0)', 0, 21, 3, 4,
         thresholds=[("green"), ("red", 1)]),
    ts("Slot retained WAL", [('pg_replication_slots_pg_wal_lsn_diff', '{{slot}} @ {{instance}}')],
       8, 0, 12, 6, unit="bytes"),
    ts("Sender reply age", [('time() - pg_stat_replication_reply_time', '{{instance}}')],
       8, 12, 6, 6, unit="s"),
    stat("WAL senders configured", 'max(pg_settings_max_wal_senders)', 8, 18, 3, 3),
    stat("Sync replicas", 'count(patroni_sync_standby == 1) or vector(0)', 8, 21, 3, 3),
    table("Slot inventory", 'pg_replication_slot_slot_is_active', 14, 0, 12, 6),
]
write(dash("patroni-replication", "03", "Replication & Slots",
           "Streaming lag, WAL sender health and replication-slot retention.",
           ["replication"], P))

# ─────────────────────────────────────────────
# 04 PostgreSQL Instance (per-node drilldown)
# ─────────────────────────────────────────────
NODE_TPL = [{
    "name": "node", "label": "Node", "type": "query", "datasource": DS,
    "query": "label_values(up{job=\"patroni\"}, instance)",
    "refresh": 1, "includeAll": False, "multi": False,
    "current": {"text": "db1:8001", "value": "db1:8001"}}]
N = 'instance=~"$node"'
D = 'datname="$db"'
P = [
    # Row A — header vitals
    stat("Uptime", f'pg_activity_process_uptime_seconds{{{N}}}', 0, 0, 4, 4, unit="s"),
    stat("Version major", f'patroni_postgres_server_version{{{N}}} / 10000', 0, 4, 4, 4),
    stat("Connections used %",
         f'pg_activity_connections{{{N}}} / pg_activity_max_connections{{{N}}}', 0, 8, 4, 4,
         unit="percentunit", thresholds=[("green"), ("orange", 0.7), ("red", 0.85)]),
    stat("Active backends", f'pg_activity_active{{{N}}}', 0, 12, 4, 4),
    stat("Cache hit % ($db)", 
         f'rate(pg_stat_database_blks_hit{{datname="$db", {N}}}[$__rate_interval]) / clamp_min(rate(pg_stat_database_blks_hit{{datname="$db", {N}}}[$__rate_interval]) + rate(pg_stat_database_blks_read{{datname="$db", {N}}}[$__rate_interval]), 0.001)',
         0, 16, 4, 4, unit="percentunit", thresholds=[("red"), ("yellow", 0.9), ("green", 0.97)]),
    stat("TPS ($db)",
         f'rate(pg_stat_database_xact_commit{{datname="$db", {N}}}[$__rate_interval])',
         0, 20, 4, 4, unit="ops"),
]

# Row B — Connections deep
row("Connections & sessions", 5)
P.append(ts("Connections vs max",
    [(f'pg_activity_connections{{{N}}}', 'used'),
     (f'pg_activity_max_connections{{{N}}}', 'max')], 6, 0, 6, 7))
P.append(ts("Sessions by state",
    [('sum by (state) (pg_sessions_by_state_sessions{instance=~"$node"})', '{{state}}')], 6, 6, 6, 7, stack=True))
P.append(ts("Backends by type",
    [('sum by (backend_type) (pg_backend_types_backends{instance=~"$node"})', '{{backend_type}}')], 6, 12, 6, 7, stack=True))
P.append(ts("Waiting backends", [
    (f'pg_transactions_waiting_backends{{{N}}}', 'waiting {{instance}}'),
    (f'pg_transactions_idle_in_tx_count{{{N}}}', 'idle-in-tx {{instance}}')], 6, 18, 6, 7))

# Row C — Throughput
row("Throughput", 14)
P.append(ts("Transactions per second ($db)", [
    (f'sum(rate(pg_stat_database_xact_commit{{datname="$db", {N}}}[$__rate_interval]))', 'commit'),
    (f'sum(rate(pg_stat_database_xact_rollback{{datname="$db", {N}}}[$__rate_interval]))', 'rollback')], 15, 0, 8, 7, unit="ops"))
P.append(ts("Tuple traffic ($db)", [
    (f'sum(rate(pg_stat_database_tup_inserted{{datname="$db", {N}}}[$__rate_interval]))', 'insert'),
    (f'sum(rate(pg_stat_database_tup_updated{{datname="$db", {N}}}[$__rate_interval]))', 'update'),
    (f'sum(rate(pg_stat_database_tup_deleted{{datname="$db", {N}}}[$__rate_interval]))', 'delete')],
    15, 8, 8, 7, unit="ops"))
P.append(ts("Rows returned vs fetched ($db)", [
    (f'rate(pg_stat_database_tup_returned{{datname="$db", {N}}}[$__rate_interval])', 'returned'),
    (f'rate(pg_stat_database_tup_fetched{{datname="$db", {N}}}[$__rate_interval])', 'fetched')],
    15, 16, 8, 7, unit="ops"))

# Row D — Cache & temp
row("Cache & temporary I/O", 23)
P.append(ts("Blocks hit vs read ($db)", [
    (f'rate(pg_stat_database_blks_hit{{datname="$db", {N}}}[$__rate_interval])', 'hit'),
    (f'rate(pg_stat_database_blks_read{{datname="$db", {N}}}[$__rate_interval])', 'read')],
    24, 0, 8, 6, unit="ops"))
P.append(ts("Temp bytes/s", [
    (f'rate(pg_stat_database_temp_bytes{{datname="$db", {N}}}[$__rate_interval]) > 0', '{{instance}}')],
    24, 8, 8, 6, unit="Bps"))
P.append(ts("Temp files created/s", [
    (f'rate(pg_stat_database_temp_files{{datname="$db", {N}}}[$__rate_interval]) > 0', '{{instance}}')],
    24, 16, 8, 6))

# Row E — WAL & checkpoints (this node)
row("WAL & checkpoints", 31)
P.append(ts("WAL bytes/s (this node)", [
    (f'deriv(pg_wal_stats_bytes{{instance=~"$node"}}[2m])', 'generated B/s')], 32, 0, 6, 6, unit="Bps"))
P.append(ts("WAL records / FPI per second", [
    (f'rate(pg_wal_stats_records{{instance=~"$node"}}[2m])', 'records/s'),
    (f'rate(pg_wal_stats_fpi{{instance=~"$node"}}[2m])', 'FPI/s')],
    32, 6, 6, 6))
P.append(ts("Checkpoints timed vs requested", [
    (f'rate(pg_checkpoints_timed{{instance=~"$node"}}[5m])', 'timed'),
    (f'rate(pg_checkpoints_requested{{instance=~"$node"}}[5m])', 'requested')],
    32, 12, 6, 6))
P.append(stat("Checkpoint requested-ratio",
    f'rate(pg_checkpoints_requested{{instance=~"$node"}}[5m]) / clamp_min(rate(pg_checkpoints_timed{{instance=~"$node"}}[5m]) + rate(pg_checkpoints_requested{{instance=~"$node"}}[5m]), 0.001)',
    32, 18, 6, 6, unit="percentunit", thresholds=[("green"), ("yellow", 0.2), ("red", 0.5)]))

# Row F — Health hygiene
row("Health hygiene", 39)
P.append(ts("Deadlocks & conflicts per hour ($db)", [
    (f'increase(pg_stat_database_deadlocks{{datname="$db", {N}}}[1h])', 'deadlocks'),
    (f'increase(pg_stat_database_conflicts{{datname="$db", {N}}}[1h])', 'conflicts')], 40, 0, 6, 6))
P.append(ts("Conflict types ($db)", [
    (f'increase(pg_stat_database_conflicts_confl_tablespace{{datname="$db", {N}}}[1h])', 'tablespace'),
    (f'increase(pg_stat_database_conflicts_confl_lock{{datname="$db", {N}}}[1h])', 'lock'),
    (f'increase(pg_stat_database_conflicts_confl_snapshot{{datname="$db", {N}}}[1h])', 'snapshot'),
    (f'increase(pg_stat_database_conflicts_confl_bufferpin{{datname="$db", {N}}}[1h])', 'bufferpin'),
    (f'increase(pg_stat_database_conflicts_confl_deadlock{{datname="$db", {N}}}[1h])', 'deadlock')],
    40, 6, 6, 6))
P.append(stat("Prepared transactions", f'pg_prepared_prepared_xacts{{{N}}}', 40, 12, 3, 6,
              thresholds=[("green"), ("yellow", 1)]))
P.append(stat("Oldest prepared age (s)", f'pg_prepared_oldest_prepared_seconds{{{N}}}',
              40, 15, 3, 6, unit="s"))
P.append(ts("Longest transaction age", [
    (f'pg_transactions_longest_tx_seconds{{{N}}}', 'longest tx (s)'),
    (f'pg_transactions_longest_idle_in_tx_seconds{{{N}}}', 'longest idle-in-tx (s)')],
    40, 18, 6, 6, unit="s"))

# Row G — Wraparound safety
row("Wraparound safety", 47)
P.append(stat("Max XID age (wraparound horizon)",
    f'max(pg_wraparound_max_xid_age{{instance=~"$node"}})', 48, 0, 6, 5, unit="short",
    thresholds=[("green"), ("yellow", 500000000), ("red", 1200000000)]))
P.append(ts("XID age over time", [
    (f'max by (instance)(pg_wraparound_max_xid_age{{instance=~"$node"}})', '{{instance}}')],
    48, 6, 9, 5))
P.append(ts("Database sizes on this node", [
    ('pg_database_size_bytes{instance=~"$node"}', '{{datname}}')], 48, 15, 9, 5, unit="bytes"))

# Row H — Storage hotspots
row("Storage hotspots", 54)
P.append(table("Top tables by total size",
    f'topk(12, pg_top_tables_total_size_bytes{{instance=~"$node"}})', 55, 0, 10, 8))
P.append(table("Seq vs idx scan balance",
    f'topk(12, pg_top_tables_seq_scan{{instance=~"$node"}} * 0 + pg_top_tables_idx_scan{{instance=~"$node"}})', 55, 10, 7, 8))
P.append(ts("Live tuples — biggest tables", [
    (f'topk(5, pg_top_tables_live_tup{{instance=~"$node"}})', '{{rel}}')], 55, 17, 7, 8))

# Settings snapshot
P.append(table("Settings snapshot", f'pg_settings_max_connections{{instance=~"$node"}}', 63, 0, 8, 6))
write(dash("patroni-instance", "04", "PostgreSQL Instance",
           "Per-node drill-down. Pick a node with the Node selector.",
           ["postgres"], P, templating=NODE_TPL +
           [{"name": "db", "label": "Database", "type": "query", "datasource": DS,
             "query": "label_values(pg_database_size_bytes, datname)",
             "refresh": 1, "includeAll": False,
             "current": {"text": "maborak", "value": "maborak"}}]))

# ─────────────────────────────────────────────
# 05 Queries (pg_stat_statements)
# ─────────────────────────────────────────────
Q = 'pg_statements_top_'
P = [
    stat("Statements tracked", 'count(pg_statements_top_calls)', 0, 0, 4, 4),
    stat("Total exec time (ms/s scrape)", 'sum(rate(pg_statements_top_total_exec_time_ms[5m])) / 1000',
         0, 4, 4, 4, unit="s"),
    stat("Calls per second", 'sum(rate(pg_statements_top_calls[5m]))', 0, 8, 4, 4, unit="ops"),
    stat("Rows returned per second", 'sum(rate(pg_statements_top_rows[5m]))', 0, 12, 4, 4, unit="ops"),
    stat("Avg cache-hit % (top set)",
         'avg(pg_statements_top_cache_hit_pct)', 0, 16, 4, 4, unit="percent",
         thresholds=[("red", ), ("yellow", 90), ("green", 97)]),
    table("Top by TOTAL time", f'topk(15, {Q}total_exec_time_ms)', 4, 0, 12, 9),
    table("Top by MEAN time", f'topk(15, {Q}mean_exec_time_ms)', 4, 12, 12, 9),
    ts("Mean execution time distribution (top 5)",
       [(f'topk(5, {Q}mean_exec_time_ms)', 'queryid {{queryid}}')], 13, 0, 8, 6, unit="ms"),
    ts("Cache miss % (worst 5)",
       [(f'topk(5, 100 - {Q}cache_hit_pct)', 'queryid {{queryid}}')], 13, 8, 8, 6, unit="percent"),
    ts("Calls rate (top 5)", [(f'topk(5, rate({Q}calls[5m]))', 'queryid {{queryid}}')],
       13, 16, 8, 6, unit="ops"),
]
write(dash("patroni-queries", "05", "Queries — pg_stat_statements",
           "Where does the time go? Requires pg_stat_statements extension (enabled at bootstrap).",
           ["queries"], P))

# ─────────────────────────────────────────────
# 06 Tables, Vacuum & Bloat
# ─────────────────────────────────────────────
V = 'pg_vacuum_hotspots_'
P = [
    {"type":"text","title":"","gridPos":{"h":2,"w":24,"x":0,"y":0},
     "options":{"content":"**Populates automatically as application tables are created and queried.** "
       + "On a fresh bootstrap this page is empty by design — `pg_stat_user_tables` has no rows yet."},
     "datasource":DS},
    stat("Autovac workers running", 'max(pg_transactions_autovacuum_workers_running)', 0, 0, 4, 4),
    stat("Tables tracked", 'count(pg_vacuum_hotspots_dead_ratio_pct)', 0, 4, 4, 4),
    stat("Worst dead-ratio %", 'max(pg_vacuum_hotspots_dead_ratio_pct)', 0, 8, 4, 4, unit="percent",
         thresholds=[("green"), ("yellow", 10), ("red", 25)]),
    stat("Max seq scans (total)", 'max(pg_vacuum_hotspots_seq_scan)', 0, 12, 4, 4),
    table("Vacuum hotspots", f'topk(15, {V}dead_ratio_pct)', 0, 16, 8, 8),
    ts("Dead tuples — top tables", [(f'topk(5, {V}dead_tup)', '{{rel}}')], 0, 0, 8, 8),
    ts("Sequential scans — top tables", [(f'topk(5, {V}seq_scan)', '{{rel}}')], 8, 0, 8, 7, unit="short"),
    stat("Longest since autovacuum (s)", f'max({V}since_last_autovacuum_seconds)', 8, 8, 4, 7,
         unit="s", thresholds=[("green"), ("yellow", 86400), ("red", 604800)]),
]
write(dash("patroni-maintenance", "06", "Tables, Vacuum & Bloat",
           "Which tables need vacuuming, which are scanned sequentially.",
           ["maintenance"], P))

# ─────────────────────────────────────────────
# 07 WAL, Archiving & Backups
# ─────────────────────────────────────────────
P = [
    ts("WAL directory size", [('pg_wal_size_bytes', '{{instance}}')], 0, 0, 6, 6, unit="bytes"),
    ts("WAL segments", [('pg_wal_segments', '{{instance}}')], 0, 6, 6, 6),
    ts("Archive rate", [
        ('sum by (instance)(rate(pg_stat_archiver_archived_count[5m]))', 'archived {{instance}}'),
        ('sum by (instance)(rate(pg_stat_archiver_failed_count[5m]))', 'FAILED {{instance}}')], 0, 12, 6, 6, unit="ops"),
    stat("Staleness (s)", ARCH_ST, 0, 18, 3, 3, unit="s",
         thresholds=[("green"), ("yellow", 300), ("red", 600)]),
    stat("Failures (1h)", 'sum(increase(pg_stat_archiver_failed_count[1h]))', 0, 21, 3, 3,
         thresholds=[("green"), ("red", 1)]),
    ts("WAL generation rate", [('deriv(patroni_xlog_location[2m])', '{{instance}}')], 6, 0, 12, 6, unit="Bps"),
    stat("Segments in use", 'max(pg_wal_segments)', 6, 12, 3, 3),
    stat("wal_segment_size", 'max(pg_settings_wal_segment_size_bytes)', 6, 15, 3, 3, unit="bytes"),
    ts("Slot retained WAL", [('pg_replication_slots_pg_wal_lsn_diff', '{{slot}}')], 6, 18, 6, 6, unit="bytes"),
    ts("Checkpoint timing pressure", [
        ('rate(pg_checkpoints_requested[5m]) / clamp_min(rate(pg_checkpoints_timed[5m]) + rate(pg_checkpoints_requested[5m]), 0.001)', 'requested {{instance}}')], 12, 0, 12, 6, unit="percentunit"),
    ts("max_wal_size headroom", [
        ('pg_wal_size_bytes / on(instance) pg_settings_max_wal_size_bytes', '{{instance}}')], 12, 12, 6, 6, unit="percentunit"),
]
write(dash("patroni-wal-backup", "07", "WAL, Archiving & Backups",
           "Write-ahead log pressure, archive pipeline and slot retention.",
           ["wal"], P))

# ─────────────────────────────────────────────
# 08 Host Resources
# ─────────────────────────────────────────────
P = [
    ts("CPU busy %", [('100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])))', 'busy'),
                      ('avg(rate(node_cpu_seconds_total{mode="iowait"}[$__rate_interval])) * 100', 'iowait')],
       0, 0, 8, 6, unit="percent"),
    ts("Memory", [
        ('node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes', 'used'),
        ('node_memory_MemAvailable_bytes', 'available')], 0, 8, 8, 6, unit="bytes"),
    ts("Filesystem free bytes", [
        ('node_filesystem_avail_bytes{fstype=~"xfs|ext4"}', '{{device}} {{mountpoint}}')],
        0, 16, 8, 6, unit="bytes"),
    ts("Disk I/O utilization", [
        ('rate(node_disk_io_time_seconds_total{device!~"loop.*|ram.*"}[$__rate_interval])', 'io time/s {{device}}')],
        6, 0, 8, 6, unit="percentunit"),
    ts("Disk throughput", [
        ('sum by (device)(rate(node_disk_read_bytes_total{device!~"loop.*|ram.*"}[$__rate_interval]))', 'read'),
        ('sum by (device)(rate(node_disk_written_bytes_total{device!~"loop.*|ram.*"}[$__rate_interval]))', 'written')],
        6, 8, 8, 6, unit="Bps"),
    ts("Network throughput", [
        ('sum by (device)(rate(node_network_receive_bytes_total{device!="lo"}[$__rate_interval]))', 'rx'),
        ('sum by (device)(rate(node_network_transmit_bytes_total{device!="lo"}[$__rate_interval]))', 'tx')],
        6, 16, 8, 6, unit="Bps"),
]
write(dash("host-resources", "08", "Host Resources",
           "The laptop itself: CPU, memory, disk and network behind the database.",
           ["host"], P))

# ─────────────────────────────────────────────
# 09 Alerts
# ─────────────────────────────────────────────
P = [
    stat("Critical firing", 'count(ALERTS{alertstate="firing",severity="critical"} == 1) or vector(0)',
         0, 0, 6, 4, thresholds=[("green"), ("red", 1)]),
    stat("Warning firing", 'count(ALERTS{alertstate="firing",severity="warning"} == 1) or vector(0)',
         0, 6, 6, 4, thresholds=[("green"), ("orange", 1)]),
    stat("All healthy checks", 'count(up == 1)', 0, 12, 6, 4),
    table("Firing alerts", 'ALERTS{alertstate="firing"} == 1', 0, 18, 6, 8),
    ts("Alerts over time", [('count(ALERTS{alertstate="firing"} == 1)', 'firing')], 4, 0, 12, 5),
    table("Every rule state (incl. OK)", 'ALERTS', 9, 0, 24, 10, sort_desc=False),
]
write(dash("alerts-overview", "09", "Alerts",
           "Live state of every rule defined in monitoring/prometheus-alerts.yml.",
           ["alerts"], P))

print("\nSuite complete.")
