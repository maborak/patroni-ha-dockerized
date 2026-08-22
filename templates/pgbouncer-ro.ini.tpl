;; AUTO-GENERATED — DO NOT EDIT. Run 'make generate' instead.
[databases]
; Wildcard: Route ALL connections to Replicas (Read-Only)
* = host=haproxy port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /tmp/userlist.txt
admin_users = __POSTGRES_USER__
stats_users = __POSTGRES_USER__
pool_mode = __PGBOUNCER_POOL_MODE__
server_reset_query = DISCARD ALL
max_client_conn = __PGBOUNCER_MAX_CLIENT_CONN__
default_pool_size = __PGBOUNCER_DEFAULT_POOL_SIZE__
reserve_pool_size = __PGBOUNCER_RESERVE_POOL_SIZE__
reserve_pool_timeout = __PGBOUNCER_RESERVE_POOL_TIMEOUT__
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
