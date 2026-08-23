# AUTO-GENERATED — DO NOT EDIT. Run 'make generate' instead.
services:
  __ETCD_SERVICES__

  # Patroni/PostgreSQL cluster
  # Base template for Patroni nodes. The x- prefix marks this as a compose
  # EXTENSION field, not a service — otherwise compose creates (and tries to
  # healthcheck) a useless "patroni_base" container on every up.
  x-patroni_base: &patroni_base
    build:
      context: ./patroni
      dockerfile: Dockerfile
      args:
        POSTGRES_VERSION: "__BA_POSTGRES_VERSION__"
        PATRONI_VERSION: "__BA_PATRONI_VERSION__"
    # Note: Must run as root for supervisor, but Patroni runs as postgres user via supervisor
    environment:
      - DEFAULT_DATABASE=${DEFAULT_DATABASE:-maborak}
      - PATRONI_CLUSTER_NAME=${PATRONI_CLUSTER_NAME:-patroni1}
      - POSTGRES_USER=${POSTGRES_USER:-postgres}
      - REPLICATOR_USER=${REPLICATOR_USER:-replicator}
      - POSTGRES_VERSION=${POSTGRES_VERSION:-15}
      - ETCD_HOSTS=${ETCD_HOSTS:-etcd1:2379,etcd2:2379,etcd3:2379}
      - PATRONI_TTL=${PATRONI_TTL:-30}
      - PATRONI_LOOP_WAIT=${PATRONI_LOOP_WAIT:-10}
      - PATRONI_RETRY_TIMEOUT=${PATRONI_RETRY_TIMEOUT:-10}
      - PATRONI_MAX_LAG_ON_FAILOVER=${PATRONI_MAX_LAG_ON_FAILOVER:-1048576}
      - PATRONI_MASTER_START_TIMEOUT=${PATRONI_MASTER_START_TIMEOUT:-300}
      - PATRONI_BASEBACKUP_MAX_RATE=${PATRONI_BASEBACKUP_MAX_RATE:-100M}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
      - REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD:-${POSTGRES_PASSWORD}}
      - PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS:-200}
      - PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS:-2GB}
      - PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE:-6GB}
      - PG_WORK_MEM=${PG_WORK_MEM:-16MB}
      - PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM:-512MB}
      - PG_DEFAULT_STATISTICS_TARGET=${PG_DEFAULT_STATISTICS_TARGET:-100}
      - PG_LOG_MIN_DURATION_STATEMENT=${PG_LOG_MIN_DURATION_STATEMENT:-250ms}
      - PG_LOG_STATEMENT=${PG_LOG_STATEMENT:-ddl}
    networks:
      - patroni_network
    depends_on:
__ETCD_DEPENDS__
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -p 5431 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

__DB_SERVICES__

  # Barman backup server
  barman:
    build:
      context: ./barman
      dockerfile: Dockerfile
      args:
        POSTGRES_VERSION: "__BA_POSTGRES_VERSION__"
    container_name: barman
    hostname: barman
    environment:
      - BARMAN_SERVER_NAME=main
      - PATRONI_REPLICAS=${PATRONI_REPLICAS:-2}
      - POSTGRES_USER=${POSTGRES_USER:-postgres}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
    ports:
      - "${BARMAN_PORT}:5432"
    volumes:
      - barman_data:/var/lib/barman
      - barman_backup:/data/pg-backup
      - ./configs/barman.conf:/etc/barman.conf:ro
      - ./ssh_keys/barman_rsa:/ssh_keys/barman_rsa:ro
      - ./ssh_keys/barman_rsa.pub:/ssh_keys/barman_rsa.pub:ro
    networks:
      - patroni_network
    depends_on:
__DB_DEPENDS_ON_HEALTHY__
    healthcheck:
      test: ["CMD-SHELL", "barman check db1 --nagios 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped

  # HAProxy load balancer
  haproxy:
    image: __HAPROXY_IMAGE__
    container_name: haproxy
    hostname: haproxy
    ports:
      - "${HAPROXY_WRITE_PORT}:5431"  # Write endpoint (leader only)
      - "${HAPROXY_READ_PORT}:5432"  # Read endpoint (replicas)
      - "${HAPROXY_STATS_PORT}:8404"  # Stats
    volumes:
      - ./configs/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - patroni_network
    depends_on:
__DB_DEPENDS_ON_HEALTHY__
    healthcheck:
      test: ["CMD-SHELL", "haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
    restart: unless-stopped

  # PgBouncer
  pgbouncer:
    image: __PGBOUNCER_IMAGE__
    container_name: pgbouncer
    ports:
      - "${PGBOUNCER_PORT:-6432}:6432"
    volumes:
      - ./configs/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
      - POSTGRES_USER=${POSTGRES_USER:-postgres}
    command: sh -c "echo '\"\${POSTGRES_USER:-postgres}\" \"\$POSTGRES_PASSWORD\"' > /tmp/userlist.txt && /usr/bin/pgbouncer /etc/pgbouncer/pgbouncer.ini"
    networks:
      - patroni_network
    depends_on:
      haproxy:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: unless-stopped

  # PgBouncer Read-Only (Port 6433 -> HAProxy 5432)
  pgbouncer-ro:
    image: __PGBOUNCER_IMAGE__
    container_name: pgbouncer-ro
    ports:
      - "${PGBOUNCER_RO_PORT:-6433}:6432"
    volumes:
      - ./configs/pgbouncer-ro.ini:/etc/pgbouncer/pgbouncer.ini
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
      - POSTGRES_USER=${POSTGRES_USER:-postgres}
    command: sh -c "echo '\"\${POSTGRES_USER:-postgres}\" \"\$POSTGRES_PASSWORD\"' > /tmp/userlist.txt && /usr/bin/pgbouncer /etc/pgbouncer/pgbouncer.ini"
    networks:
      - patroni_network
    depends_on:
      haproxy:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: unless-stopped

  # pgBadger log analytics: cron-driven collection from all DB nodes,
  # JSON log parsing, source cleanup, and a built-in web UI for reports.
  pgbadger:
    build:
      context: ./pgbadger
      dockerfile: Dockerfile
      args:
        ALPINE_VERSION: "__BA_ALPINE_VERSION__"
        PGBADGER_VERSION: "__BA_PGBADGER_VERSION__"
    container_name: pgbadger
    hostname: pgbadger
    environment:
      - PGBADGER_CRON_EXPRESSION=${PGBADGER_CRON_EXPRESSION:-*/30 * * * *}
      - PGBADGER_TZ=${PGBADGER_TZ:-UTC}
      - PGBADGER_RETENTION_DAYS=${PGBADGER_RETENTION_DAYS:-7}
      - PGBADGER_JOBS=${PGBADGER_JOBS:-4}
      - PGBADGER_SAFETY_MINUTES=${PGBADGER_SAFETY_MINUTES:-10}
      - PGBADGER_TITLE=${PATRONI_CLUSTER_NAME:-patroni1} pgBadger report
    ports:
      - "${PGBADGER_PORT:-8080}:80"
    volumes:
      - pgbadger_raw:/var/lib/pgbadger/raw
      - pgbadger_reports:/var/lib/pgbadger/reports
__PGBADGER_LOG_VOLUMES__
    networks:
      - patroni_network
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:80/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    restart: unless-stopped

networks:
  patroni_network:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET:-172.20.0.0/16}

volumes:
__ETCD_VOLUMES__
__DB_VOLUMES__
  barman_data:
  barman_backup:
  pgbadger_raw:
  pgbadger_reports:
