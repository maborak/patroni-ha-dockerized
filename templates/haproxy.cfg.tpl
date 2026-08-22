global
    log stdout format raw local0
    stats socket /tmp/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    option  clitcpka
    option  srvtcpka
    timeout connect 5000ms
    timeout client  30m
    timeout server  30m
    retries 3

# Stats interface (HTTP mode required for stats)
listen stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE
    stats auth __HAPROXY_STATS_USER__:__HAPROXY_STATS_PASSWORD__

# Frontend for WRITE operations (routes to leader only)
frontend patroni_write
    bind *:5431
    default_backend patroni_write_backend

# Backend for WRITE operations (leader only)
backend patroni_write_backend
    balance first
    option httpchk GET /primary
    http-check expect status 200
__WRITE_SERVERS__

# Frontend for READ operations (routes to replicas)
frontend patroni_read
    bind *:5432
    default_backend patroni_read_backend

# Backend for READ operations (replicas only)
backend patroni_read_backend
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
__READ_SERVERS__
