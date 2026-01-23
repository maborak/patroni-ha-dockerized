# Barman Status Check Guide

## Key Fields to Monitor in `barman status db1`

### ✅ **Critical Health Indicators**

#### 1. **WAL Archiving Status**
```
Last archived WAL: 0000000100000006000000CD, at Sun Jan  4 15:52:35 2026
Current WAL segment: 0000000100000006000000CE
Failures of WAL archiver: 0
Server WAL archiving rate: 1837.35/hour
```

**What to check:**
- ✅ **Last archived WAL** should be recent (within last few minutes)
- ✅ **Current WAL segment** should be close to last archived (1-2 segments ahead is normal)
- ✅ **Failures of WAL archiver** should be **0** (any number > 0 indicates problems)
- ✅ **WAL archiving rate** should be positive (indicates active archiving)

**⚠️ Warning signs:**
- Last archived WAL is old (> 5 minutes) → WAL archiving may be stuck
- Current WAL is many segments ahead of last archived → WALs not being archived fast enough
- Failures > 0 → Check archive logs and SSH connectivity
- WAL archiving rate = 0 → No WALs being archived

#### 2. **Backup Status**
```
No. of available backups: 6
First available backup: 20260104T145620
Last available backup: 20260104T153446
Minimum redundancy requirements: satisfied (6/1)
```

**What to check:**
- ✅ **No. of available backups** should meet your redundancy needs
- ✅ **Last available backup** should be recent (based on your backup schedule)
- ✅ **Minimum redundancy** should show "satisfied" (e.g., "6/1" means 6 backups available, minimum 1 required)

**⚠️ Warning signs:**
- No backups available → No backups have been created
- Last backup is old → Need to create new backup
- Minimum redundancy shows "NOT satisfied" → Need more backups

#### 3. **Server Status**
```
Active: True
Disabled: False
Cluster state: in production
Passive node: False
```

**What to check:**
- ✅ **Active** should be **True**
- ✅ **Disabled** should be **False**
- ✅ **Cluster state** should be **"in production"**
- ✅ **Passive node** should be **False** (unless intentionally using passive mode)

**⚠️ Warning signs:**
- Active: False → Barman server is not active
- Disabled: True → Server is disabled
- Cluster state: not "in production" → Database may be down or in recovery

#### 4. **Data Size Monitoring**
```
Current data size: 19.6 GiB
```

**What to check:**
- Monitor for unexpected growth (may indicate bloat or data issues)
- Compare with backup sizes to ensure consistency

### 📊 **Quick Health Check Commands**

```bash
# Full status check
docker exec barman barman status db1

# Check only WAL archiving (most critical)
docker exec barman barman status db1 | grep -E "(Last archived|Failures|archiving rate)"

# Check backup availability
docker exec barman barman status db1 | grep -E "(available backups|redundancy)"

# Detailed server information
docker exec barman barman show-server db1

# Check for any errors
docker exec barman barman check db1
```

### 🎯 **Priority Checks (in order)**

1. **Failures of WAL archiver: 0** ← Most critical
2. **Last archived WAL** is recent (within last few minutes)
3. **Minimum redundancy: satisfied**
4. **Active: True**
5. **WAL archiving rate** is positive

### 📝 **Example Healthy Status**

```
✅ Failures of WAL archiver: 0
✅ Last archived WAL: 0000000100000006000000CD, at Sun Jan  4 15:52:35 2026
✅ Server WAL archiving rate: 1837.35/hour
✅ No. of available backups: 6
✅ Minimum redundancy requirements: satisfied (6/1)
✅ Active: True
✅ Disabled: False
```

### ⚠️ **Example Problematic Status**

```
❌ Failures of WAL archiver: 5          ← Check archive logs
❌ Last archived WAL: (old timestamp)    ← WAL archiving stuck
❌ Server WAL archiving rate: 0         ← No archiving happening
❌ Minimum redundancy: NOT satisfied    ← Need more backups
❌ Active: False                         ← Barman not active
```

