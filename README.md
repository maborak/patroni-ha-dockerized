# Dockerized Patroni Stack

This directory contains a Docker Compose setup that replicates the entire Patroni stack:
- **etcd** (2 nodes) - Distributed key-value store for Patroni
- **Patroni/PostgreSQL** (4 nodes: db1, db2, db3, db4) - High-availability PostgreSQL cluster
- **Barman** - Backup and recovery manager
- **HAProxy** - Load balancer for PostgreSQL connections

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+

## Quick Start

1. **Start the stack:**
   ```bash
   docker-compose up -d
   ```

2. **Check status:**
   ```bash
   docker-compose ps
   ```

3. **View logs:**
   ```bash
   docker-compose logs -f patroni
   ```

4. **Connect to PostgreSQL via HAProxy:**
   ```bash
   psql -h localhost -p 5000 -U postgres -d postgres
   ```

## Services

### etcd
- **etcd1**: Port 23791 (client), 23801 (peer)
- **etcd2**: Port 23792 (client), 23802 (peer)

### Patroni/PostgreSQL
- **db1**: PostgreSQL 15431, REST API 8001
- **db2**: PostgreSQL 5432, REST API 8002
- **db3**: PostgreSQL 5433, REST API 8003
- **db4**: PostgreSQL 5434, REST API 8004

### HAProxy
- **PostgreSQL**: Port 5000 (load balanced)
- **Stats**: http://localhost:8404/stats

### Barman
- **PostgreSQL**: Port 54320
- **Backup Directory**: `/data/pg-backup` (mounted as `barman_backup` volume)

## Barman Overview

Barman (Backup and Recovery Manager) is a disaster recovery solution for PostgreSQL servers. It provides continuous WAL archiving and base backups, enabling Point-In-Time Recovery (PITR).

### How Barman Works

1. **WAL Archiving**: PostgreSQL continuously streams Write-Ahead Log (WAL) files to Barman via `archive_command`
2. **Base Backups**: Periodic full database backups are taken using `barman backup`
3. **WAL Processing**: Barman processes incoming WAL files and stores them in an organized structure
4. **Recovery**: You can recover to any point in time using base backups + WAL files

### Barman Directory Structure

For each PostgreSQL server (e.g., `db1`, `db2`), Barman maintains:

```
/data/pg-backup/{server}/
├── incoming/          # WAL files arrive here first (temporary staging)
│   └── 000000010000000000000001
├── wals/             # Processed WAL files organized by timeline
│   └── 0000000100000000/
│       ├── 000000010000000000000001
│       ├── 000000010000000000000002.gz
│       └── ...
├── base/             # Base backups
│   └── 20260104T163505/
│       ├── data/
│       └── ...
└── .barman/          # Barman metadata
```

**WAL Flow:**
1. PostgreSQL sends WAL → `/data/pg-backup/{server}/incoming/`
2. Barman cron processes WAL → moves to `/data/pg-backup/{server}/wals/{timeline}/`
3. WALs are compressed (`.gz`) after processing
4. Old WALs are purged based on retention policy

### Restore Commands for PITR

When performing Point-In-Time Recovery, PostgreSQL needs a `restore_command` to fetch WAL files from Barman. Two methods are available:

#### Method 1: barman-wal-restore (Recommended)
```bash
restore_command = 'barman-wal-restore -U barman barman db2 %f %p'
```

**Advantages:**
- Simpler command
- Handles compression automatically
- Built-in error handling
- Recommended for most use cases

#### Method 2: barman get-wal (Atomic-safe)
```bash
restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal db2 %f" > "$tmp" && mv "$tmp" %p)'
```

**Advantages:**
- Atomic file operations (prevents corruption)
- More control over the process
- Useful in high-concurrency scenarios

**How it works:**
- Checks if WAL file already exists (`test -f %p`)
- Creates temporary file with process ID (`%p.tmp.$$`)
- Sets restrictive permissions (`umask 077`)
- Downloads WAL to temp file
- Atomically moves to final location (`mv "$tmp" %p`)

### Barman Commands

```bash
# List all servers
docker exec barman barman list-server

# Check server status
docker exec barman barman check db2

# Create a backup
docker exec barman barman backup db2

# List backups
docker exec barman barman list-backup db2

# Show backup details
docker exec barman barman show-backup db2 20260104T163505

# List WAL files
docker exec barman barman list-wals db2

# Recover to a specific point in time
docker exec barman barman recover \
  --target-time '2026-01-04 15:50:00' \
  --remote-ssh-command 'ssh postgres@db1' \
  db2 20260104T163505 /var/lib/postgresql/15/patroni1
```

## Configuration

### Environment Variables
Edit `.env` file to change passwords:
```
PATRONI_REPLICATOR_PASSWORD=your_password
PATRONI_POSTGRESS_PASSWORD=your_password
```

### Patroni Configuration
Edit `configs/patroni1.yml` to modify Patroni settings.

### HAProxy Configuration
Edit `configs/haproxy.cfg` to modify load balancing settings.

### Barman Configuration
Edit `configs/barman.conf` to modify backup settings.

## Useful Commands

### Check Patroni cluster status
```bash
docker exec db1 patronictl -c /etc/patroni/patroni1.yml list
```

### Promote a replica to leader
```bash
docker exec db1 patronictl -c /etc/patroni/patroni1.yml switchover
```

### Check etcd cluster health
```bash
docker exec etcd1 etcdctl endpoint health
```

### View HAProxy stats
Open http://localhost:8404/stats in your browser

### Backup with Barman

See the [Barman Overview](#barman-overview) section above for detailed information about how Barman works and available commands.

**Quick examples:**
```bash
# Create a backup
docker exec barman barman backup db2

# List backups
docker exec barman barman list-backup db2

# Check server status
docker exec barman barman check db2

# View backup details
docker exec barman barman show-backup db2 20260104T163505
```

**Point-In-Time Recovery:**
See `scripts/perform_pitr.sh` for automated PITR, or refer to the documentation:
- `docs/PITR_GUIDE.md` - Complete step-by-step guide
- `docs/PITR_CONSIDERATIONS.md` - Critical considerations, best practices, and pitfalls
- `docs/PITR_PATRONI_GUIDE.md` - Patroni-specific considerations
- `docs/PITR_QUICK_REFERENCE.md` - Quick command reference
- `docs/PITR_TROUBLESHOOTING.md` - Troubleshooting guide

## Data Persistence

All data is stored in Docker volumes:
- `etcd1_data`, `etcd2_data` - etcd data
- `db1_data`, `db2_data`, `db3_data`, `db4_data` - PostgreSQL data
- `barman_data` - Barman backups

To remove all data:
```bash
docker-compose down -v
```

## Network

All services are connected to the `patroni_network` bridge network (172.20.0.0/16).

## Troubleshooting

### Check service logs
```bash
docker-compose logs [service_name]
```

### Restart a service
```bash
docker-compose restart [service_name]
```

### Rebuild images
```bash
docker-compose build --no-cache
```

### Check network connectivity
```bash
docker exec db1 ping etcd1
```

## Notes

- The first Patroni node (db1) will become the leader after initialization
- HAProxy will automatically route traffic to the current leader
- Barman connects through HAProxy for backups
- All services wait for dependencies before starting

