# Remote Standby Cluster Provisioning Runbook

This runbook outlines the step-by-step procedure for provisioning a new **Remote Standby Cluster** (e.g., a `<remote-host>` machine on a remote network or home lab) that follows an active primary cluster (e.g., the N-node Patroni Docker stack on your Mac — `db1..dbN`, sized by `PATRONI_REPLICAS` in `.env` — or any other primary side).

The standby cluster operates under a separate scope via Patroni's `standby_cluster:` mechanism, cloning from the active primary over the network (such as a VPN or LAN) and streaming transaction logs (WALs).

All cross-cluster endpoints referenced below come from `.env` §8 (`REMOTE_*`, `MAC_VPN_HOST`, `STANDBY_REMOTE_SLOT_NAME`).

---

## 🏗️ Architecture & Topology

The standby leader node communicates with the primary cluster's entrypoint (HAProxy) to perform the initial sync and stream updates.

```mermaid
graph TD
    subgraph Primary Cluster (e.g. Mac side)
        A["HAProxy Entrypoint ($MAC_VPN_HOST:5551)"]
        B["Active Leader Node (e.g. db1)"]
        A -.->|Routes to| B
    end

    subgraph Standby Cluster (e.g. remote-host)
        C["Standby Leader Node (dbr1)"]
        D["Local etcd Cluster (:2379)"]
        C -->|DCS Coordination| D
    end

    C -- "1. pg_basebackup (VPN/LAN) <br> 2. Streaming WAL protocol" ---> A
```

| Component | Target Location / Configuration | Detail |
| :--- | :--- | :--- |
| **Primary Entrypoint** | `$MAC_VPN_HOST:5551` (Mac HAProxy write port) | HAProxy port that dynamically routes to the current leader. |
| **Standby Host** | `<remote-host>` | The machine hosting the new standby. |
| **Standby Scope** | `patroni1_dr` | Must be a unique scope/namespace in etcd — different from the primary's `patroni1`. |
| **Standby Name** | `dbr1` | Unique name for the standby Patroni node. |
| **Standby DCS** | Local etcd on `<remote-host>`'s network (e.g. `<etcd1>`, `<etcd2>`) | Fully decoupled DCS to prevent cross-WAN split-brain scenarios. |

---

## 📋 Prerequisites

Before proceeding, ensure the following requirements are met on the target host (`<remote-host>`):

1. **Exact PostgreSQL Major Version Match**:
   * The standby must run the **exact same PostgreSQL major version** as the primary cluster (e.g., PostgreSQL 15).
   * If the target host has a different system-wide PostgreSQL package, you **must** install a parallel version from source. Refer to the [install-pg15-arch.md](../remote-standby/install-pg15-arch.md) guide for standard parallel compilations (e.g., into `/opt/pgsql-15/`).

2. **Network Routing & Ports**:
   * The standby host must be able to reach the primary cluster's HAProxy write port (`$MAC_VPN_HOST:5551` over VPN).
   * Ensure any local firewall rules on the standby allow outward TCP connections to this port.

3. **Separate DCS Instance**:
   * The standby **must** use its own etcd cluster (local to the standby or its immediate network).
   * **Do not** point the standby to the primary cluster's etcd nodes. Decoupled DCS stores are a hard requirement of the disaster-recovery architecture.

---

## 🛠️ Step-by-Step Provisioning

### Step 1: Create a Replication Slot on the Active Primary

To ensure that the primary does not discard WAL segments before the new standby has completed its initial clone, you must create a dedicated physical replication slot on the active primary. This deployment uses `STANDBY_REMOTE_SLOT_NAME` from `.env` §8 (default: `standby_remote`).

1. Connect to the **active primary** database (e.g., the current leader node inside the Docker stack):
   ```bash
   docker exec -it db1 psql -U postgres -d postgres -p 5431
   ```

2. Run the physical slot creation query (with your slot name if it differs from the default):
   ```sql
   SELECT pg_create_physical_replication_slot('standby_remote', true);
   ```
   > [!NOTE]
   > Setting the second argument to `true` (`immediately_reserve`) guarantees that PostgreSQL immediately reserves WAL space starting from the slot's creation time.

---

### Step 2: Configure the Standby `patroni.yml`

On the standby host (`<remote-host>`), create the configuration file (e.g., `/etc/patroni/patroni.yml`). Start from the tracked template at [../remote-standby/patroni.yml](../remote-standby/patroni.yml) — it already carries the correct `standby_cluster:` wiring, tuning, and inline commentary. Copy it to the standby host and adjust the keys below:

| Key | Constraint / value |
| :--- | :--- |
| `scope` and `namespace` | **Must differ from the primary cluster's scope** (`patroni1`). The template uses `patroni1_dr` / `/patroni1_dr` — DCS keys live under its own path so there is no collision even if the DCSs can see each other. |
| `name` | Unique node name for this standby (template: `dbr1`). |
| `restapi.connect_address` | The standby host's own address (`<remote-host>:8008`). |
| `etcd3.hosts` | The standby-side etcd cluster (e.g. `<etcd1>:2379,<etcd2>:2379`) — never the primary's etcd. |
| `bootstrap.dcs.standby_cluster.host` / `.port` | The primary's write entrypoint: `host: <mac-vpn-ip>` (`$MAC_VPN_HOST`) and the primary HAProxy write port (`5551` on the Mac stack). |
| `bootstrap.dcs.standby_cluster.primary_slot_name` | The slot created in Step 1 (`standby_remote` / `$STANDBY_REMOTE_SLOT_NAME`). |
| `postgresql.data_dir` | Local path for the standby's PG data (template: `/var/lib/postgres/standby15`). |
| `postgresql.bin_dir` | Path to the parallel-install PG binaries (template: `/opt/pgsql-15/bin`). |
| `postgresql.authentication.*` | Passwords **must match the primary's `.env`** (`REPLICATOR_PASSWORD`, `POSTGRES_PASSWORD`) — replace every `CHANGE_ME_BEFORE_FIRST_USE`. |
| `pg_hba` subnet entries | Replace `<your-subnet>/24` with the standby network's actual subnet. |

> [!IMPORTANT]
> The template keeps `archive_mode: 'off'` on the standby. Standby clusters do not manage WAL archival (e.g. Backup) — do not carry the primary's `archive_command` over.

---

### Step 3: Initialize and Start Patroni

Once the configuration is in place, you can start the Patroni daemon on the standby host.

1. **Systemd Setup** (if running as a systemd service):
   Create `/etc/systemd/system/patroni-standby.service`:
   ```ini
   [Unit]
   Description=Patroni PostgreSQL Orchestrator (Standby)
   After=network.target etcd.service

   [Service]
   Type=simple
   User=postgres
   ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml
   ExecReload=/bin/kill -HUP $MAINPID
   KillMode=process
   TimeoutSec=30
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```

2. **Reload and Start Service**:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable patroni-standby
   sudo systemctl start patroni-standby
   ```

3. **Verify the Initial Bootstrap Log**:
   Check the Patroni logs to monitor the initial clone process:
   ```bash
   journalctl -u patroni-standby -f --no-pager
   ```
   * Expect to see Patroni discover that the database directory is empty and invoke `pg_basebackup` connecting to the primary write entrypoint (`$MAC_VPN_HOST:5551`).
   * Look for successful output ending with: `bootstrap from leader in progress` -> `database system is ready to accept read only connections`.

---

### Step 4: Verify Replication Health

1. **List the Standby Cluster Topology**:
   On the standby host, run:
   ```bash
   patronictl -c /etc/patroni/patroni.yml list
   ```
   * Expect to see `dbr1` listed as **`Standby Leader`** and state as **`running`**.

2. **Check PostgreSQL Recovery Mode**:
   Execute a query on the local standby Postgres instance to verify it is running in recovery (read-only):
   ```bash
   /opt/pgsql-15/bin/psql -U postgres -p 5432 -d postgres -c "SELECT pg_is_in_recovery();"
   ```
   * Expect it to return `t` (true). Adjust the binary path / port if your install differs from the template.

3. **Verify Active Slot on the Primary**:
   On the **active primary** host (e.g. Mac cluster), run:
   ```bash
   docker exec db1 psql -U postgres -d postgres -p 5431 -c \
     "SELECT slot_name, active, wal_status FROM pg_replication_slots WHERE slot_name='standby_remote';"
   ```
   * Expect `active = t` and `wal_status = reserved` or `normal`.

4. **Verify Write Propagation**:
   Perform a write on the primary and observe the immediate replication on the standby:
   ```bash
   # On the primary
   docker exec db1 psql -U postgres -d maborak -p 5431 -c \
     "CREATE TABLE IF NOT EXISTS standby_test (id serial PRIMARY KEY, note text, ts timestamptz DEFAULT now());
      INSERT INTO standby_test (note) VALUES ('Standby test from <remote-host>');"

   # On the standby (<remote-host>)
   /opt/pgsql-15/bin/psql -U postgres -d maborak -p 5432 -c \
     "SELECT * FROM standby_test ORDER BY id DESC LIMIT 1;"
   ```

---

## 🚨 Operations and Disaster Recovery Notes

* **DCS Isolation**: Because the standby cluster has its own decoupled etcd cluster and its own namespace (`/patroni1_dr`), there is zero danger of network splits causing split-brain scenarios on the primary cluster.
* **VPN/Network Outages**: If the network connection drops between the standby and primary, the replication slot on the primary will become `inactive`. The primary will accumulate WAL files in its `pg_wal` directory up to the safety limit. If the network is down for extremely long periods, monitor the primary's disk space.
* **Role Swapping**: If you ever want to promote this standby cluster to be the new active primary, refer to the role-swap and DCS adjustment steps documented in the [switchover.md](switchover.md) runbook (or just run `make switchover-to-remote`).
