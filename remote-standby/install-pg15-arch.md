# Install PostgreSQL 15.17 from source on Arch Linux

> **Use case**: install PG 15 as a parallel install at `/opt/pgsql-15/`, coexisting with the system PG (any major version) from pacman. Required when streaming replication needs an exact major-version match against an upstream cluster.

---

## Context

- Host is Arch Linux, pacman package manager.
- System already has `postgresql` and `postgresql-libs` from pacman at a different major version (e.g. 18.x). **DO NOT TOUCH** those packages.
- We need PG 15.17 installed as a **parallel install** at `/opt/pgsql-15/`, outside pacman, coexisting with the system PG.

---

## Steps to perform (codify as Ansible tasks)

### 1. Install build dependencies via pacman, idempotent

```bash
pacman -Sy --noconfirm --needed \
    base-devel readline zlib openssl libxml2 libxslt icu curl \
    llvm clang lz4 zstd e2fsprogs
```

Why the extra deps beyond core: `llvm` + `clang` are needed by `--with-llvm` (JIT). `lz4` / `zstd` enable TOAST + WAL compression options. `e2fsprogs` provides `libuuid`, required by `--with-uuid=e2fs` so the `uuid-ossp` contrib extension builds. systemd headers (`--with-systemd`) come from `systemd`, already in base.

### 2. Create working directories

```bash
mkdir -p /opt/build
mkdir -p /opt/pgsql-15
chown root:root /opt/build /opt/pgsql-15
```

### 3. Download PG 15.17 source tarball

- URL: `https://ftp.postgresql.org/pub/source/v15.17/postgresql-15.17.tar.gz`
- Save to: `/opt/build/postgresql-15.17.tar.gz`
- Size: ~30 MB

```bash
curl -fsSL -o /opt/build/postgresql-15.17.tar.gz \
    https://ftp.postgresql.org/pub/source/v15.17/postgresql-15.17.tar.gz
```

### 4. Extract

```bash
cd /opt/build
tar xzf postgresql-15.17.tar.gz
# Result: /opt/build/postgresql-15.17/
```

### 5. Configure with these flags (exact tested combination)

```bash
cd /opt/build/postgresql-15.17
./configure --prefix=/opt/pgsql-15 \
    --with-openssl \
    --with-libxml \
    --with-libxslt \
    --with-icu \
    --with-systemd \
    --with-llvm \
    --with-lz4 \
    --with-zstd \
    --with-uuid=e2fs
```

Flag rationale:

| Flag | Why |
|---|---|
| `--with-openssl` | TLS for client + replication connections |
| `--with-libxml` / `--with-libxslt` | XML functions, `xml2` contrib |
| `--with-icu` | ICU collations (default since PG10+) |
| `--with-systemd` | Enables `sd_notify`; lets Patroni run with `Type=notify` for cleaner systemd lifecycle |
| `--with-llvm` | JIT compilation; 10-50% faster on analytic queries |
| `--with-lz4` | LZ4 TOAST/WAL compression (PG14+) |
| `--with-zstd` | Zstandard TOAST/WAL compression (PG15+) |
| `--with-uuid=e2fs` | Makes `CREATE EXTENSION "uuid-ossp"` actually work — without it, `make -C contrib` silently skips the uuid-ossp module |

### 6. Build (parallel, ~3-5 min on 4 cores)

```bash
make -j$(nproc) -s
```

### 7. Install core

```bash
make install
# Result:
#   /opt/pgsql-15/bin/{postgres,psql,pg_basebackup,initdb,pg_ctl,pg_dump,...}
#   /opt/pgsql-15/lib/
#   /opt/pgsql-15/share/
#   /opt/pgsql-15/include/
```

### 7b. Build + install contrib (REQUIRED — `make install` skips it)

`shared_preload_libraries = pg_stat_statements,auto_explain,...` will refuse to load without these. Skipping this step is what put db2/db3 into "start failed" historically.

```bash
make -j$(nproc) -C contrib
make -C contrib install
# Adds /opt/pgsql-15/lib/{pg_stat_statements,auto_explain,uuid-ossp,
#                          pgcrypto,hstore,postgres_fdw,btree_gin,...}.so
```

### 8. Cleanup build directory

```bash
rm -rf /opt/build
```

### 9. Verify

```bash
/opt/pgsql-15/bin/postgres --version
# Expected output: postgres (PostgreSQL) 15.17
```

---

## Idempotency

Skip the entire build when **all three** of these are true:

1. `/opt/pgsql-15/bin/postgres --version` returns the expected version.
2. `/opt/pgsql-15/lib/pg_stat_statements.so` exists (proves contrib was installed).
3. `/opt/pgsql-15/.build-version` (operator-managed marker) matches the current flag set.

Re-run when any of those fails — e.g., `pg15_version` bumped, contrib never installed (the historical bug), or new `./configure` flags added (bump the marker to invalidate).

---

## Variables for the Ansible role

```yaml
pg15_version: "15.17"
pg15_source_url: "https://ftp.postgresql.org/pub/source/v15.17/postgresql-15.17.tar.gz"
pg15_prefix: "/opt/pgsql-15"
pg15_build_version: "v2-core+contrib+systemd+llvm+lz4+zstd+uuid"  # bump to invalidate existing installs
pg15_configure_flags: >-
  --prefix=/opt/pgsql-15
  --with-openssl --with-libxml --with-libxslt --with-icu
  --with-systemd --with-llvm --with-lz4 --with-zstd --with-uuid=e2fs
pg15_build_deps:
  - base-devel
  - readline
  - zlib
  - openssl
  - libxml2
  - libxslt
  - icu
  - curl
  - llvm        # --with-llvm
  - clang       # required by --with-llvm
  - lz4         # --with-lz4
  - zstd        # --with-zstd
  - e2fsprogs   # --with-uuid=e2fs
```

---

## Things NOT to do

- ❌ Do NOT remove or modify system `postgresql` / `postgresql-libs` pacman packages.
- ❌ Do NOT put `/opt/pgsql-15` into pacman's IgnorePkg — it's not a pacman package.
- ❌ Do NOT chown `/opt/pgsql-15` to postgres user. Root ownership is correct.
- ❌ Do NOT pass `--without-readline` to configure.
- ❌ Do NOT use EnterpriseDB CDN (requires login as of 2026).
- ❌ Do NOT use Arch Linux Archive (only has 15.4, plus libs conflict with system 18.x).

---

## Verification tasks

1. `/opt/pgsql-15/bin/postgres --version` matches `pg15_version`.
2. `/opt/pgsql-15/bin/initdb --version` matches.
3. `/opt/pgsql-15/bin/pg_basebackup --version` matches.
4. `/opt/pgsql-15/bin/psql --version` matches.
5. `/opt/pgsql-15/lib/pg_stat_statements.so` exists.
6. `/opt/pgsql-15/lib/uuid-ossp.so` exists (confirms `--with-uuid` worked).
7. `/opt/pgsql-15/lib/llvmjit.so` exists (confirms `--with-llvm` worked).
8. `/opt/pgsql-15/bin/pg_config --configure` shows every expected flag.
9. `cat /opt/pgsql-15/.build-version` matches `pg15_build_version`.

---

## Build timings (4-core x86_64 box)

| Phase | Time |
|---|---|
| pacman dep install | ~30 sec |
| source download | ~30 sec |
| `./configure` | ~60 sec |
| `make -j4` | ~3 min |
| `make install` | ~30 sec |
| **Total** | **under 6 minutes per host** |

---

## What this unlocks

PG 15.17 binaries live at `/opt/pgsql-15/bin/` — usable by any consumer (Patroni's `bin_dir` config, direct `pg_ctl` calls, etc.) that needs PostgreSQL 15.x specifically while the system PG remains a different major version.
