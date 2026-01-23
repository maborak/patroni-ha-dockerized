# PITR Process Considerations

This document outlines critical considerations, best practices, warnings, and edge cases for performing Point-In-Time Recovery (PITR) with Barman in a Patroni cluster environment.

## Table of Contents

1. [Prerequisites and Pre-Flight Checks](#prerequisites-and-pre-flight-checks)
2. [Timing Considerations](#timing-considerations)
3. [WAL Availability and Gaps](#wal-availability-and-gaps)
4. [Timeline Handling](#timeline-handling)
5. [Cluster Management](#cluster-management)
6. [Recovery Methods](#recovery-methods)
7. [Error Handling and Recovery](#error-handling-and-recovery)
8. [Performance Considerations](#performance-considerations)
9. [Security Considerations](#security-considerations)
10. [Best Practices](#best-practices)
11. [Common Pitfalls](#common-pitfalls)

---

## Prerequisites and Pre-Flight Checks

### ✅ Required Before Starting PITR

1. **Backup Exists**
   - Verify backup exists: `barman list-backup <server>`
   - Check backup status: `barman show-backup <server> <backup-id>`
   - Ensure backup is marked as `DONE` (not `FAILED` or `WAITING_FOR_WALS`)

2. **WAL Archiving is Active**
   - Check archiving status: `barman status <server>`
   - Verify `Failures: 0` (or acceptable low number)
   - Ensure `Last archived` is recent and matches current time

3. **Network Connectivity**
   - PostgreSQL server can SSH to Barman server
   - SSH keys are properly configured
   - Barman server is accessible and responsive

4. **Disk Space**
   - Sufficient space for recovery directory (typically 2x database size)
   - Space for backup of current data directory
   - Space for WAL files during recovery

5. **Cluster State**
   - Understand current cluster topology
   - Identify which node to use for recovery (prefer replica)
   - Ensure you have cluster admin access (`patronictl`)

### ⚠️ Critical Warnings

- **Data Loss Risk**: PITR will overwrite existing data on the target node
- **Cluster Disruption**: Recovery requires stopping nodes, which affects availability
- **Irreversible**: Once recovery starts, original data is backed up but recovery cannot be easily undone
- **Timing Sensitivity**: Target time must be after backup end time

---

## Timing Considerations

### Target Time Validation

1. **Must Be After Backup End Time**
   ```
   Target time > Backup end time
   ```
   - Script validates this automatically
   - Recovery to times before backup end will fail

2. **Must Be Before Last Archived WAL**
   ```
   Target time ≤ Last archived WAL time
   ```
   - Check: `barman show-server <server> | grep last_archived`
   - Recovery beyond last archived WAL will fail

3. **Microsecond Precision**
   - PostgreSQL backups include microsecond precision
   - Example: `2026-01-05 05:08:10.806023`
   - If recovering very close to backup end, include microseconds

4. **Close to Backup End Time**
   - **Warning**: If target time is < 10 seconds after backup end:
     - May require WAL files that are partial (`.partial`)
     - PostgreSQL cannot use partial WAL files
     - **Recommendation**: Use exact backup end time or `latest`

5. **Using `latest`**
   - Recover to most recent available state
   - No target time validation needed
   - Best option when exact time is not critical
   - Automatically handles WAL availability

### Time Zone Considerations

- Barman stores times in UTC
- Target time should be specified in UTC or PostgreSQL's timezone
- Example: `'2026-01-05 05:08:11+00:00'` (UTC) or `'2026-01-05 05:08:11'` (assumes server timezone)

---

## WAL Availability and Gaps

### WAL Gap Detection

The script performs comprehensive WAL gap detection in Step 3:

1. **Calculates Required WAL Segments**
   - From backup end time to target time
   - Accounts for timeline switches

2. **Checks Multiple Locations**
   - `/data/pg-backup/<server>/wals/<timeline>/` (processed WALs)
   - `/data/pg-backup/<server>/incoming/` (pending processing)

3. **Timeline-Aware Checking**
   - Checks backup timeline and up to 5 timelines ahead
   - Handles rapid timeline switches

### Common WAL Gap Scenarios

#### Scenario 1: WAL Archiving Stopped
**Symptoms:**
- Last archived WAL is before target time
- Large time gap between last archived and target

**Causes:**
- Database stopped or crashed
- WAL archiving disabled
- Network issues
- Database in recovery mode (not archiving new WALs)

**Solutions:**
- Use `latest` to recover to most recent available state
- Check if a later backup exists
- Verify WAL archiving is active

#### Scenario 2: Rapid Timeline Switches
**Symptoms:**
- Missing intermediate WAL segments
- Timeline history files exist but WALs are missing

**Causes:**
- Multiple failovers in short time
- Timeline switches without archiving intermediate WALs

**Solutions:**
- Use `latest` (handles timeline switches automatically)
- Recover to a time before the rapid switches
- Check if missing WALs exist in `incoming/` directory

#### Scenario 3: Partial WAL Files
**Symptoms:**
- WAL file exists but ends with `.partial`
- Recovery fails with "could not read WAL file"

**Causes:**
- Database crashed during WAL archiving
- Network interruption during transfer

**Solutions:**
- Use a target time before the partial WAL
- Use `latest` to skip partial WALs
- Wait for complete WAL if database is still running

### WAL Processing Delay

**Important**: WALs may be in `incoming/` directory but not yet processed by `barman cron`:
- PostgreSQL archives WAL → `incoming/`
- `barman cron` processes → moves to `wals/<timeline>/`
- Script checks both locations to account for this delay

**Recommendation**: Run `barman cron` manually if needed:
```bash
docker exec barman barman cron
```

---

## Timeline Handling

### Timeline Basics

- **Timeline**: PostgreSQL's way of tracking database history
- **Timeline Switch**: Occurs during promotion, failover, or point-in-time recovery
- **Timeline History Files**: `.history` files track timeline switches (e.g., `0000000D.history`)

### Timeline Considerations During PITR

1. **`recovery_target_timeline = 'latest'`**
   - **Required** when recovering across timeline switches
   - Allows PostgreSQL to follow timeline history
   - Automatically added by script

2. **Timeline History Files**
   - PostgreSQL requests these during recovery
   - Missing history files are handled gracefully (return success)
   - Script may create missing intermediate history files

3. **Multiple Timeline Switches**
   - Script checks up to 5 timelines ahead
   - If more switches occurred, gaps may exist
   - Use `latest` to handle automatically

### Timeline History File Behavior

**With `barman-wal-restore`:**
- May restore many history files (expected behavior)
- Logs: `restored log file "000000XX.history" from archive`
- This is normal when `recovery_target_timeline = 'latest'`

**With `barman-get-wal`:**
- History files may not exist or may fail silently
- Less verbose logging
- Recovery continues without explicit history file restoration

**Recommendation**: Both methods work correctly; choose based on preference.

---

## Cluster Management

### Node Selection

**Best Practice: Use a Replica Node**
- ✅ Avoids disrupting current primary
- ✅ Allows testing before promoting
- ✅ Provides rollback path
- ✅ Minimizes cluster downtime

**Process:**
1. Identify a replica: `patronictl list`
2. Stop Patroni on replica (isolate from cluster)
3. Perform PITR on isolated node
4. Verify recovery
5. Promote recovered node to leader

### Stopping Nodes

**When Nodes Are Stopped:**
- **Step 7.6**: After successful recovery on target node
- **Step 7.9**: Only if `--auto-start` is specified

**Why Stop Other Nodes:**
- Prevents split-brain scenarios
- Ensures recovered node becomes leader
- Avoids conflicts with existing cluster state

**Manual Control:**
- Use `--auto-start` flag to control post-recovery automation
- Without flag: Script stops at recovery completion
- With flag: Automatically stops nodes, starts target, promotes leader

### Promoting Recovered Node

**After Recovery:**
1. Stop all other nodes (prevents conflicts)
2. Start Patroni on target node
3. Promote to leader: `patronictl failover`
4. Reinitialize other nodes (if `--auto-start`)

**Verification:**
```bash
patronictl list
# Should show recovered node as Leader
```

---

## Recovery Methods

### Method 1: `barman-wal-restore` (Default)

**Command:**
```bash
restore_command = 'test -f %p || barman-wal-restore -U barman barman <server> %f %p'
```

**Advantages:**
- ✅ Simpler command
- ✅ Handles compression automatically
- ✅ Built-in error handling
- ✅ Recommended for most use cases

**Considerations:**
- Requires SSH key in default location (`~/.ssh/id_rsa`)
- May restore many timeline history files (verbose logging)
- Uses `barman-wal-restore` utility

### Method 2: `barman-get-wal`

**Command:**
```bash
restore_command = 'test -f %p || (umask 077; tmp="%p.tmp.$$"; ssh -o BatchMode=yes barman@barman "barman get-wal <server> %f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" %p || (rm -f "$tmp"; exit 0))'
```

**Advantages:**
- ✅ Atomic file operations (prevents corruption)
- ✅ More control over the process
- ✅ Useful in high-concurrency scenarios
- ✅ Less verbose history file logging

**Considerations:**
- More complex command
- Requires manual compression handling (if WALs are compressed)
- Requires SSH access to Barman server

### Choosing a Method

**Use `barman-wal-restore` when:**
- Simplicity is preferred
- Standard recovery scenarios
- Default choice

**Use `barman-get-wal` when:**
- Need atomic operations
- High-concurrency environments
- Prefer less verbose logging

**Switch Method:**
```bash
--wal-method barman-wal-restore  # Default
--wal-method barman-get-wal      # Alternative
```

---

## Error Handling and Recovery

### Common Recovery Failures

#### 1. "recovery ended before configured recovery target was reached"

**Causes:**
- Missing WAL files
- Partial WAL files
- WAL gaps
- Target time beyond available WALs

**Solutions:**
- Check WAL availability: `barman show-server <server>`
- Use `latest` instead of specific time
- Use backup end time
- Check for WAL gaps (script warns in Step 3)

#### 2. "could not stat file pg_wal/RECOVERYHISTORY"

**Causes:**
- PostgreSQL requesting internal recovery files
- `restore_command` not handling special files

**Solutions:**
- Script handles this automatically
- `restore_command` returns success for missing special files
- Recovery continues normally

#### 3. "Connection problem with ssh"

**Causes:**
- SSH key not found
- SSH key permissions incorrect
- Barman host key not accepted

**Solutions:**
- Script copies SSH key to default location
- Verify key permissions: `chmod 600 ~/.ssh/id_rsa`
- Accept Barman host key (script does this automatically)

#### 4. "WAL file '000000XX.history' not found"

**Causes:**
- Timeline history file doesn't exist
- Normal when timeline switches occurred

**Solutions:**
- Script handles this gracefully (returns success)
- Recovery continues without the history file
- PostgreSQL will create new timeline if needed

### Recovery Monitoring

**Real-Time Monitoring:**
- Script shows PostgreSQL logs in real-time
- Automatically detects recovery completion
- Detects recovery failures

**Manual Monitoring:**
```bash
# Check recovery status
docker exec <node> psql -U postgres -p 5431 -c "SELECT pg_is_in_recovery();"

# View PostgreSQL logs
docker exec <node> tail -f /var/log/postgresql/*.log
```

### Recovery Completion Detection

**Script Automatically Detects:**
- ✅ "database system is ready to accept connections"
- ✅ `pg_is_in_recovery()` returns `false`
- ✅ Recovery target reached

**Manual Verification:**
```bash
# Check if recovery completed
docker exec <node> psql -U postgres -p 5431 -c "SELECT pg_is_in_recovery();"
# Should return: f (false)

# Check recovery target
docker exec <node> psql -U postgres -p 5431 -c "SELECT pg_last_wal_replay_lsn(), pg_last_wal_replay_timestamp();"
```

---

## Performance Considerations

### Recovery Time

**Factors Affecting Recovery Time:**
1. **Database Size**: Larger databases take longer
2. **WAL Volume**: More WALs to replay = longer recovery
3. **Target Time Distance**: Further from backup = more WALs
4. **Network Speed**: WAL fetching speed
5. **Disk I/O**: WAL replay is I/O intensive

**Typical Recovery Times:**
- Small database (< 10GB): 5-15 minutes
- Medium database (10-100GB): 15-60 minutes
- Large database (> 100GB): 1-4 hours

### WAL Fetching Performance

**Optimization Tips:**
1. **Pre-copy WALs** (if known): Copy required WALs before recovery
2. **Use `barman-wal-restore`**: Generally faster than `barman-get-wal`
3. **Network Optimization**: Ensure fast connection to Barman server
4. **Parallel Recovery**: Not supported (PostgreSQL limitation)

### Timeline History Files

**Performance Impact:**
- Many history file requests during recovery
- Each request requires SSH connection
- Minimal impact on overall recovery time

**Optimization (Future):**
- Pre-copy all history files before recovery
- Reduces `restore_command` calls
- Currently not implemented (optional optimization)

---

## Security Considerations

### SSH Key Management

**Requirements:**
- SSH key-based authentication to Barman server
- Key must be accessible to `postgres` user
- Default location: `~/.ssh/id_rsa`

**Script Actions:**
- Copies `barman_rsa` key to default location
- Sets correct permissions (`600`)
- Accepts Barman host key

**Security Best Practices:**
- Use dedicated SSH key for Barman (not shared)
- Restrict SSH key permissions
- Use `BatchMode=yes` in SSH commands (prevents password prompts)
- Rotate SSH keys periodically

### File Permissions

**Recovery Directory:**
- Created with `700` permissions (owner only)
- Contains sensitive database data

**PostgreSQL Data Directory:**
- Owned by `postgres:postgres`
- Permissions: `700` (directory), `600` (files)

**Configuration Files:**
- `postgresql.auto.conf`: `600` permissions
- `recovery.signal`: `600` permissions

### Network Security

**Considerations:**
- WAL transfer over SSH (encrypted)
- Barman server should be on trusted network
- Consider VPN for remote Barman servers

---

## Best Practices

### 1. Pre-Recovery Checklist

- [ ] Verify backup exists and is valid
- [ ] Check WAL archiving status
- [ ] Identify target node (prefer replica)
- [ ] Document target recovery time
- [ ] Verify disk space availability
- [ ] Test SSH connectivity to Barman
- [ ] Backup current data (script does this automatically)

### 2. Recovery Execution

- [ ] Use `--server` to specify backup server (or let script auto-detect)
- [ ] Use `--target` to automate application to node
- [ ] Use `--restore` to start recovery automatically
- [ ] Monitor recovery progress in real-time
- [ ] Verify recovery completion before promoting

### 3. Post-Recovery Verification

- [ ] Verify `pg_is_in_recovery()` returns `false`
- [ ] Check recovery target was reached
- [ ] Verify data consistency
- [ ] Test application connectivity
- [ ] Run data validation queries
- [ ] Compare before/after statistics

### 4. Cluster Management

- [ ] Stop other nodes before promoting recovered node
- [ ] Promote recovered node to leader
- [ ] Reinitialize other nodes (if `--auto-start`)
- [ ] Verify cluster topology
- [ ] Monitor cluster health after recovery

### 5. Documentation

- [ ] Document recovery reason
- [ ] Record backup ID used
- [ ] Record target recovery time
- [ ] Document any issues encountered
- [ ] Keep recovery logs for audit

---

## Common Pitfalls

### Pitfall 1: Target Time Too Close to Backup End

**Problem:**
- Target time < 10 seconds after backup end
- Requires WAL files that may be partial
- Recovery fails

**Solution:**
- Use exact backup end time (with microseconds)
- Use `latest` to recover to most recent state
- Script warns about this scenario

### Pitfall 2: WAL Gaps Not Detected

**Problem:**
- Recovery fails mid-way due to missing WALs
- No warning before recovery starts

**Solution:**
- Script performs gap detection in Step 3
- Checks both `wals/` and `incoming/` directories
- Warns and prompts for confirmation

### Pitfall 3: Timeline Switches Not Handled

**Problem:**
- Recovery stops at timeline boundary
- Doesn't follow timeline switches

**Solution:**
- Script adds `recovery_target_timeline = 'latest'`
- Handles timeline history files
- Checks multiple timelines for WAL gaps

### Pitfall 4: SSH Connection Issues

**Problem:**
- `restore_command` fails with SSH errors
- Recovery cannot fetch WALs

**Solution:**
- Script copies SSH key to default location
- Accepts Barman host key automatically
- Verifies SSH connectivity before recovery

### Pitfall 5: Recovery Runs in Background

**Problem:**
- User doesn't see recovery progress
- Ctrl+C stops script instead of recovery

**Solution:**
- Script shows real-time PostgreSQL logs
- Automatically detects recovery completion
- Prevents accidental interruption

### Pitfall 6: Cluster Split-Brain

**Problem:**
- Recovered node conflicts with existing cluster
- Multiple leaders exist

**Solution:**
- Script stops other nodes before promoting
- Use `--auto-start` for automated cluster management
- Verify cluster topology after recovery

### Pitfall 7: Partial WAL Files

**Problem:**
- WAL file exists but is `.partial`
- PostgreSQL cannot use partial WALs

**Solution:**
- Script checks for partial WALs
- Warns if target time requires partial WAL
- Recommends using `latest` or earlier time

### Pitfall 8: Incorrect Server Specification

**Problem:**
- Backup exists on different server than expected
- Script fails to find backup

**Solution:**
- Script auto-detects backup server
- Use `--server` to explicitly specify
- Lists available backups if not found

---

## Summary

### Critical Success Factors

1. ✅ **WAL Availability**: Ensure WALs exist for target time
2. ✅ **Timeline Handling**: Use `recovery_target_timeline = 'latest'`
3. ✅ **Node Isolation**: Stop other nodes before promoting
4. ✅ **SSH Configuration**: Proper SSH keys and connectivity
5. ✅ **Monitoring**: Watch recovery progress and verify completion

### Quick Reference

**Successful PITR Requires:**
- Valid backup (DONE status)
- Active WAL archiving
- WAL files available for target time
- Proper SSH configuration
- Sufficient disk space
- Cluster management (stop nodes, promote leader)

**When to Use `latest`:**
- Exact time not critical
- WAL gaps detected
- Target time very close to backup end
- Timeline switches occurred

**Recovery Method Selection:**
- `barman-wal-restore`: Default, simpler
- `barman-get-wal`: Atomic operations, less verbose

**Automation Level:**
- Without `--auto-start`: Manual cluster management
- With `--auto-start`: Automated post-recovery steps

---

## Additional Resources

- [PITR Guide](./PITR_GUIDE.md): Complete step-by-step guide
- [PITR Patroni Guide](./PITR_PATRONI_GUIDE.md): Patroni-specific considerations
- [PITR Quick Reference](./PITR_QUICK_REFERENCE.md): Quick command reference
- [PITR Troubleshooting](./PITR_TROUBLESHOOTING.md): Troubleshooting guide

---

**Last Updated**: Based on `perform_pitr.sh` script analysis
**Version**: 1.0

