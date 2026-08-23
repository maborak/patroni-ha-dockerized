#!/bin/bash
# archive-wal.sh — archive_command delegate for the Patroni/PostgreSQL nodes.
#
# Called by PostgreSQL as:  archive-wal.sh %p %f
#
# Why a script instead of an inline command:
#   * PG18+ rejects any literal % placeholder in archive_command besides
#     %p/%f (date formats like +"%Y-%m-%d" are impossible inline).
#   * No shell-quoting-inside-YAML fragility.
#   * Strict failure semantics: any rsync failure exits non-zero, so
#     PostgreSQL RETRIES instead of marking the segment archived.
#   * Dedicated log file with real timestamps and error details.
#
# Each node ships its own WAL to its own directory on the Backup host
# (backup.conf defines one server per node), so no leader gate is needed.

set -euo pipefail

WAL_PATH="${1:?usage: archive-wal.sh <wal-path> <wal-name>}"
WAL_NAME="${2:?usage: archive-wal.sh <wal-path> <wal-name>}"
LOG_FILE="/var/log/postgresql/archive.log"
SSH_KEY="/var/lib/postgresql/.ssh/id_rsa"
BARMAN_TARGET="backup@backup:/data/pg-backup/$(hostname)/incoming/${WAL_NAME}"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

on_error() {
    local rc=$?
    log "ERROR: archiving ${WAL_NAME} failed (rc=${rc})"
    exit "$rc"
}
trap on_error ERR

SSH_OPTS="ssh -i ${SSH_KEY} -p 22 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Self-heal the remote directory (fresh Backup volumes don't have per-node
# incoming/ dirs yet — rsync refuses to create parent paths).
ssh -i "${SSH_KEY}" -p 22 -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null backup@backup \
    "mkdir -p /data/pg-backup/$(hostname)/incoming"

rsync -e "${SSH_OPTS}" -a "$WAL_PATH" "$BARMAN_TARGET"

log "Archived: ${WAL_NAME}"
