#!/bin/bash
# scripts/backup/restore_database.sh — Restore a single database from a .tgz produced
# by dump_database.sh.
#
# Two modes:
#   LOCAL  — default. Restore lands on the local Patroni cluster leader.
#   REMOTE — triggered when --target is a libpq URI (postgresql://...). Restore
#            lands on the remote host parsed from the URI. A local db* container
#            is used as the pg_restore client (so the URI's password ends up in
#            its process list and in your shell history — be aware).
#
# By default refuses to overwrite an existing target; pass --clean to drop+recreate.
#
# Usage:
#   bash scripts/backup/restore_database.sh --archive backups/pazuzu_20260515_204914.tgz
#   bash scripts/backup/restore_database.sh --archive backups/x.tgz --target mydb_copy
#   bash scripts/backup/restore_database.sh --archive backups/x.tgz --clean
#   bash scripts/backup/restore_database.sh --interactive
#   bash scripts/backup/restore_database.sh --archive backups/x.tgz \
#       --target postgresql://postgres:secret@localhost:5432/maborak --clean

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

ARCHIVE=""
TARGET=""
NODE=""
JOBS=4
CLEAN=false
NO_OWNER=false
NO_ACL=false
INTERACTIVE=false
ASSUME_YES=false
DEBUG=false
INTERRUPTED=false

# SIGINT handler: don't kill the script mid-print — just flip the flag so
# the post-restore logic can distinguish "user aborted" from
# "pg_restore exit 1 means warnings". The current command (pg_restore | awk)
# still gets SIGINT and exits, which yields control back to bash.
on_sigint() {
    INTERRUPTED=true
    echo "" >&2
    echo -e "${YELLOW}⚠ Interrupted by user (SIGINT). Finalizing...${NC}" >&2
}
trap on_sigint INT

usage() {
    cat <<EOF
Usage: $(basename "$0") [--from PATH|URI | --archive PATH] [--target NAME|URI] [options]
       $(basename "$0") --interactive

Restore a database into the local Patroni leader (default) or a remote host,
from any of these source types (--from / --archive):
  FILE.tgz      archive produced by make dump-db (pg_dump -Fd, tarred)
  FILE.dump     custom-format pg_dump archive (e.g. kept by a live import)
  DIRECTORY     an unpacked pg_dump -Fd directory
  postgresql:// live source database — dumped on the fly (pg_dump -Fd), then
                restored through the same pipeline (probe, progress, resume)

Options:
  --from SRC         Source: .tgz file, .dump file, directory, or postgresql:// URI
                     (alias: --archive; make restore-db FROM=… / DSN=… / ARCHIVE=…)
  --target NAME|URI  Target DB name (local cluster, default) OR libpq URI (remote restore)
  --node dbN         Local: force destination node (default: cluster leader)
                       Remote: force client container (default: first running db*)
  --jobs N           pg_restore parallel jobs (default: 4)
  --clean            Drop the target database first if it exists
  --no-owner         pg_restore --no-owner (skip ownership restoration)
  --no-acl           pg_restore --no-acl (skip GRANT/REVOKE restoration)
  --interactive      Wizard: pick source (files, path, or live URI) and target
  --yes              Skip the Start/Cancel confirmation (use with care)
  --debug            Print every psql/pg_restore command before running it (passwords masked)
  -h, --help         Show this help

Examples:
  # From a dump-db archive into the cluster leader
  $(basename "$0") --archive backups/pazuzu_20260515_204914.tgz
  $(basename "$0") --archive backups/x.tgz --target mydb_copy
  # From a LIVE external database into the cluster (was make import-db)
  $(basename "$0") --from postgresql://dev:secret@127.0.0.1:5100/maborak
  $(basename "$0") --from postgresql://dev:secret@db.example.com:5432/app --target app_imported --clean
  # Into a remote host instead of the cluster
  $(basename "$0") --archive backups/x.tgz --target postgresql://postgres:secret@localhost:5432/maborak --clean
  # Wizard (pick source + target interactively)
  $(basename "$0") --interactive
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --archive|--from|--source) ARCHIVE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --node) NODE="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --clean) CLEAN=true; shift ;;
        --no-owner) NO_OWNER=true; shift ;;
        --no-acl) NO_ACL=true; shift ;;
        --interactive) INTERACTIVE=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --debug) DEBUG=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    echo -e "${RED}✗ --jobs must be a positive integer (got: $JOBS)${NC}" >&2
    exit 1
fi

# --- Remote-mode detection (if --target is a libpq URI) ----------------------
# When TARGET is postgresql://... or postgres://..., the script switches to
# remote mode: SQL admin (CREATE/DROP/EXISTS) and pg_restore all run against
# the remote host. A local container is still used as the pg_restore client
# (so the archive can be extracted somewhere with psql/pg_restore installed),
# but Patroni leader detection is skipped entirely.
REMOTE_MODE=false
REMOTE_DSN=""
REMOTE_DSN_ADMIN=""
PG_USER=""; PG_PASSWORD=""; PG_HOST=""; PG_PORT=""; PG_DBNAME=""; PG_PARAMS=""

# URL-decode (percent-decode) a string. Handles common cases like %40 → @,
# %23 → #, etc. Used so a URI like postgresql://u:p%40ss@host/db gives PG_PASSWORD=p@ss
# even though we already split userinfo on the right-most literal @.
_url_decode() {
    local s="$1"
    # printf %b interprets \xNN escapes — convert %NN to \xNN first
    printf '%b' "${s//%/\\x}"
}

parse_pg_uri() {
    local uri="$1"
    # Reject unix-socket DSNs (postgresql:///dbname?host=/var/run/postgresql) — the
    # restore flow only supports TCP-style URIs because we connect from a container
    # to a remote host. A unix-socket DSN almost always means "I meant local mode."
    if [[ "$uri" =~ ^postgres(ql)?://[^@]*(@?)/ ]] && [[ "$uri" =~ \?host= ]]; then
        echo -e "${RED}✗ Unix-socket DSN is not supported. Use a TCP URI: postgresql://user:pass@host:port/dbname${NC}" >&2
        return 1
    fi
    local rest="${uri#postgresql://}"
    rest="${rest#postgres://}"
    local main="${rest%%\?*}"
    PG_PARAMS=""
    [[ "$rest" == *\?* ]] && PG_PARAMS="${rest#*\?}"
    local userinfo=""
    local hostpart="$main"
    if [[ "$main" == *@* ]]; then
        # Split on the LAST '@' so passwords containing '@' parse correctly
        # (libpq's own URI parser uses the same right-most-@ rule)
        userinfo="${main%@*}"
        hostpart="${main##*@}"
    fi
    PG_USER="${userinfo%%:*}"
    PG_PASSWORD=""
    [[ "$userinfo" == *:* ]] && PG_PASSWORD="${userinfo#*:}"
    # URL-decode user/password (handles %40 → @ etc.)
    PG_USER=$(_url_decode "$PG_USER")
    PG_PASSWORD=$(_url_decode "$PG_PASSWORD")
    # Detect IPv6 literal: starts with '[' → host is bracketed, port is after ']:'
    if [[ "$hostpart" =~ ^\[([^\]]+)\](:([0-9]+))?(/.*)?$ ]]; then
        PG_HOST="${BASH_REMATCH[1]}"
        PG_PORT="${BASH_REMATCH[3]:-5432}"
        local after_bracket="${BASH_REMATCH[4]}"
        PG_DBNAME="${after_bracket#/}"
        PG_DBNAME="${PG_DBNAME%%\?*}"
    else
        local hostport="${hostpart%%/*}"
        local dbpart=""
        [[ "$hostpart" == */* ]] && dbpart="${hostpart#*/}"
        PG_HOST="${hostport%%:*}"
        PG_PORT="5432"
        [[ "$hostport" == *:* ]] && PG_PORT="${hostport#*:}"
        PG_DBNAME="${dbpart%%\?*}"
    fi
    # Reject multi-host DSNs (libpq supports comma-separated hosts; we don't)
    if [[ "$PG_HOST" == *,* ]]; then
        echo -e "${RED}✗ Multi-host DSN is not supported. Pass a single host: postgresql://user:pass@host:port/dbname${NC}" >&2
        return 1
    fi
    # Validate port is numeric
    if ! [[ "$PG_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid port in DSN: '$PG_PORT' (parsed from URI)${NC}" >&2
        return 1
    fi
}

mask_dsn() {
    # Greedy match so a '@' in the password still gets masked correctly:
    # capture up to "scheme://user:", swallow anything, leave the final "@host..."
    echo "$1" | sed -E 's|(://[^:/]+:).*(@[^@]+)$|\1****\2|'
}

# --- Resume state helpers ----------------------------------------------------
# State file holds enough info to resume an interrupted restore. Lives in
# $PROJECT_ROOT/.restore-state/, key derived from archive + target (NOT
# including the password — but DSN with password is saved in the file body,
# so umask 077 is used at write time).
STATE_DIR="${PROJECT_ROOT}/.restore-state"

# state_key — stable key for an archive+target pair. Does NOT include password.
state_key() {
    local archive_abs="$1"
    local target_id="$2"
    local input="${archive_abs}|${target_id}"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | awk '{print $1}'
    else
        # Fallback: deterministic-ish, less collision-resistant
        printf '%s' "$input" | cksum | awk '{print $1}'
    fi
}

state_file_path() {
    local key="$1"
    echo "${STATE_DIR}/${key}.env"
}

# Encode a value so it survives in a single-quoted shell variable assignment:
# replace each ' with '\''  (close-quote, escaped quote, re-open).
# Required because saved values are read with quote-stripping, NOT eval.
_state_encode() {
    local s="${1//\'/\'\\\'\'}"
    echo "$s"
}

# save_state_file: writes a shell-readable env file with restore parameters.
# Security:
#   - $STATE_DIR is chmod'd to 0700 (dir perms), files are 0600 (file perms via umask 077).
#   - DSN passwords are NOT persisted; only the host/port/user/dbname components are
#     saved so the next invocation can rebuild the connection-targeting hash without
#     leaking credentials to disk. The user re-supplies the password via TARGET=URI
#     or PGPASSWORD on resume.
save_state_file() {
    local key="$1"
    local file
    file=$(state_file_path "$key")
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    # Compute a passwordless DSN for the saved REMOTE_DSN field (so we can re-derive
    # the connection target but don't store the password on disk).
    local saved_dsn=""
    if [ -n "$REMOTE_DSN" ]; then
        # mask_dsn replaces the password with **** — same shape, no secret
        saved_dsn=$(mask_dsn "$REMOTE_DSN")
    fi
    (
        umask 077
        cat > "$file" <<EOF
# Auto-generated by restore_database.sh on interrupt — DO NOT EDIT MANUALLY.
# Password is intentionally OMITTED from REMOTE_DSN (****) — re-supply via the
# TARGET= argument or PGPASSWORD env var when resuming.
ARCHIVE='$(_state_encode "$ARCHIVE")'
EXTRACT_PATH='$(_state_encode "$EXTRACT_PATH")'
TARGET='$(_state_encode "$TARGET")'
REMOTE_MODE='$REMOTE_MODE'
REMOTE_DSN='$(_state_encode "$saved_dsn")'
PG_HOST='$(_state_encode "$PG_HOST")'
PG_PORT='$PG_PORT'
PG_DBNAME='$(_state_encode "$PG_DBNAME")'
PG_USER='$(_state_encode "$PG_USER")'
JOBS='$JOBS'
NO_OWNER='$NO_OWNER'
NO_ACL='$NO_ACL'
INTERRUPT_TIMESTAMP='$(date +%s)'
INTERRUPT_TIME='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF
    )
    echo -e "${CYAN}  State saved: $file${NC}" >&2
}

# load_state_file: source the env file's vars into the *_PREV namespace
# (so callers can compare against current invocation without clobbering live state)
load_state_file() {
    local key="$1"
    local file
    file=$(state_file_path "$key")
    [ -f "$file" ] || return 1
    # shellcheck disable=SC1090
    source "$file"
    return 0
}

clear_state_file() {
    local key="$1"
    rm -f "$(state_file_path "$key")" 2>/dev/null
    return 0
}

# trace_cmd: when DEBUG=true, print a command (with any libpq DSN masked) to stderr
# Does NOT execute — caller still runs the command. Use run_traced for both.
trace_cmd() {
    [ "$DEBUG" = true ] || return 0
    local out="" arg
    for arg in "$@"; do
        # Mask any libpq DSN anywhere in the arg (handles --dbname=postgresql://... too)
        arg=$(mask_dsn "$arg")
        # Quote args that contain anything other than safe-shell characters
        if [ -z "$arg" ] || ! [[ "$arg" =~ ^[a-zA-Z0-9._/=:@-]+$ ]]; then
            arg="'${arg//\'/\'\\\'\'}'"
        fi
        out="$out $arg"
    done
    printf "${BLUE}[exec]${NC}%s\n" "$out" >&2
}

# run_traced: trace_cmd + execute. Preserves exit code.
run_traced() {
    trace_cmd "$@"
    "$@"
}

# --- Interactive source + target wizard ----------------------------------------
# Runs BEFORE target-URI detection so a URI chosen here flows into the normal
# TARGET parsing below. SOURCE_URI holds a live postgresql:// source.
SOURCE_URI=""
wizard_pick_source() {
    BACKUP_DIR="$PROJECT_ROOT/backups"
    if [[ "$ARCHIVE" =~ ^postgres(ql)?:// ]]; then
        SOURCE_URI="$ARCHIVE"; ARCHIVE=""; return 0
    fi
    [ "$INTERACTIVE" = true ] || return 0
    [ -n "$ARCHIVE" ] && return 0

    echo "" >&2
    echo -e "${BLUE}${BOLD}Restore wizard — choose a source${NC}" >&2
    if [ -d "$BACKUP_DIR" ]; then
        ARCHIVES=()
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            ARCHIVES+=("$f")
        done < <(ls -1t "$BACKUP_DIR"/*.tgz "$BACKUP_DIR"/*.dump 2>/dev/null || true)
    else
        ARCHIVES=()
        echo -e "${YELLOW}  (no $BACKUP_DIR directory yet)${NC}" >&2
    fi

    if [ ${#ARCHIVES[@]} -gt 0 ]; then
        echo -e "${BLUE}Archives in ./backups (newest first):${NC}" >&2
        for idx in "${!ARCHIVES[@]}"; do
            f="${ARCHIVES[$idx]}"
            size=$(du -h "$f" | awk '{print $1}')
            printf "  ${CYAN}%2d)${NC} %s  (%s)\n" "$((idx + 1))" "$(basename "$f")" "$size" >&2
        done
    fi
    echo "" >&2
    echo "  u)  live database URI (dump + restore on the fly)" >&2
    echo "  p)  path to a .tgz / .dump file or -Fd directory" >&2
    echo "" >&2

    local prompt="Source"
    [ ${#ARCHIVES[@]} -gt 0 ] && prompt="Source [1-${#ARCHIVES[@]}], u, or p"
    echo -ne "${BOLD}${prompt}: ${NC}" >&2
    local choice; IFS= read -r choice || choice=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ ${#ARCHIVES[@]} -gt 0 ] \
        && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ARCHIVES[@]}" ]; then
        ARCHIVE="${ARCHIVES[$((choice - 1))]}"
        echo -e "${GREEN}✓ Selected: $(basename "$ARCHIVE")${NC}" >&2
    elif [ "$choice" = "u" ] || [ "$choice" = "U" ]; then
        while :; do
            echo -ne "${BOLD}Source URI (postgresql://user:pass@host:port/db): ${NC}" >&2
            IFS= read -r SOURCE_URI || { echo -e "${YELLOW}Input closed — aborting, nothing was changed.${NC}" >&2; exit 0; }
            [[ "$SOURCE_URI" =~ ^postgres(ql)?:// ]] && break
            echo -e "${RED}Invalid URI. Expected postgresql://user[:pass]@host[:port]/db${NC}" >&2
        done
    elif [ "$choice" = "p" ] || [ "$choice" = "P" ]; then
        while :; do
            echo -ne "${BOLD}Path to .tgz / .dump / directory: ${NC}" >&2
            IFS= read -r ARCHIVE || { echo -e "${YELLOW}Input closed — aborting, nothing was changed.${NC}" >&2; exit 0; }
            [ -e "$ARCHIVE" ] && break
            echo -e "${RED}No such file or directory: $ARCHIVE${NC}" >&2
        done
    else
        echo -e "${RED}✗ Invalid choice.${NC}" >&2
        exit 1
    fi
}

wizard_pick_target() {
    [ "$INTERACTIVE" = true ] || return 0
    local def=""
    if [ -n "$SOURCE_URI" ]; then
        def="$(parse_pg_uri_quiet_db "$SOURCE_URI")"
    elif [ -n "$ARCHIVE" ]; then
        local base
        base=$(basename "$ARCHIVE"); base="${base%.tgz}"; base="${base%.dump}"
        def=$(echo "$base" | sed -E 's/_[0-9]{8}_[0-9]{6}$//')
    fi
    echo "" >&2
    echo -e "${BLUE}Target — press Enter for the local cluster leader${NC}" >&2
    echo -e "  Enter a database NAME (restore into the local HA cluster), or" >&2
    echo -e "  a full postgresql://user:pass@host:port/db URI (restore into a remote host)." >&2
    echo -ne "${BOLD}Target [${def:-database name}]: ${NC}" >&2
    local ans; IFS= read -r ans || ans=""
    [ -n "$ans" ] && TARGET="$ans"
    [ -z "$TARGET" ] && TARGET="$def"
    echo "" >&2
}

# parse_pg_uri_quiet_db: extract just the database name from a URI (no globals)
parse_pg_uri_quiet_db() {
    local rest="${1#*://}" main="${rest%%\?*}" hostpart="$main"
    [[ "$main" == *@* ]] && hostpart="${main##*@}"
    local db="${hostpart##*/}"
    [ "$db" = "$hostpart" ] && db=""
    printf '%s' "$db"
}

wizard_pick_source
wizard_pick_target

if [[ "$TARGET" =~ ^postgres(ql)?:// ]]; then
    REMOTE_MODE=true
    REMOTE_DSN="$TARGET"
    parse_pg_uri "$REMOTE_DSN" || exit 1
    if [ -z "$PG_DBNAME" ]; then
        echo -e "${RED}✗ Remote DSN must include a database name (postgresql://user:pass@host:port/dbname)${NC}" >&2
        exit 1
    fi
    if [ -z "$PG_USER" ]; then
        echo -e "${RED}✗ Remote DSN must include a user (postgresql://user:pass@host:port/dbname)${NC}" >&2
        exit 1
    fi
    # Admin DSN: same creds + host, but pointing at 'postgres' DB (for CREATE/DROP)
    REMOTE_DSN_ADMIN="postgresql://${PG_USER}"
    [ -n "$PG_PASSWORD" ] && REMOTE_DSN_ADMIN="${REMOTE_DSN_ADMIN}:${PG_PASSWORD}"
    REMOTE_DSN_ADMIN="${REMOTE_DSN_ADMIN}@${PG_HOST}:${PG_PORT}/postgres"
    [ -n "$PG_PARAMS" ] && REMOTE_DSN_ADMIN="${REMOTE_DSN_ADMIN}?${PG_PARAMS}"
    # The rest of the script treats TARGET as the DB name (not the URI)
    TARGET="$PG_DBNAME"
fi

# --- Client-mode detection (REMOTE only) -------------------------------------
# Prefer host-installed pg_restore/psql for remote restores: avoids docker exec
# overhead and keeps the password out of the container's process list.
# Fall back to a docker container only if the host doesn't have them.
CLIENT_MODE="docker"   # local mode always uses docker (peer auth via socket)
if [ "$REMOTE_MODE" = true ]; then
    if command -v pg_restore >/dev/null 2>&1 && command -v psql >/dev/null 2>&1; then
        CLIENT_MODE="host"
        HOST_PG_RESTORE_VER=$(pg_restore --version 2>/dev/null | head -1)
        echo -e "${GREEN}✓ Using host client: ${HOST_PG_RESTORE_VER}${NC}" >&2
    else
        MISSING=""
        command -v pg_restore >/dev/null 2>&1 || MISSING="pg_restore"
        command -v psql >/dev/null 2>&1 || MISSING="${MISSING:+$MISSING, }psql"
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠ Host is missing: ${MISSING}${NC}" >&2
        echo -e "${YELLOW}  No local PostgreSQL client tools found on this machine.${NC}" >&2
        echo -e "${YELLOW}  Fallback: run pg_restore/psql from inside a db* container via 'docker exec'.${NC}" >&2
        echo -e "${YELLOW}  ${BOLD}Caveat:${NC}${YELLOW} the DSN password will be visible in that container's process list.${NC}" >&2
        echo -e "${YELLOW}  To use host tools instead, install postgresql-client (e.g. 'brew install libpq' or 'apt install postgresql-client') and re-run.${NC}" >&2
        echo "" >&2
        if [ "$ASSUME_YES" = false ]; then
            echo -ne "${BOLD}Continue using the docker fallback? [y/N]: ${NC}" >&2
            read -r confirm
            case "$confirm" in
                y|Y|yes|YES) ;;
                *) echo -e "${YELLOW}Cancelled.${NC}"; exit 1 ;;
            esac
        else
            echo -e "${YELLOW}--yes set: proceeding with docker fallback.${NC}" >&2
        fi
        CLIENT_MODE="docker"
    fi
fi


# --- Live-source (URI) parsing ------------------------------------------------
# SOURCE_URI was set by --from or the wizard. Parse into SRC_* globals.
# (parse_pg_uri fills PG_*; we stash them into SRC_* and reset, because PG_*
# is reserved for the REMOTE TARGET for the rest of the script.)
if [ -n "$SOURCE_URI" ]; then
    parse_pg_uri "$SOURCE_URI" || exit 1
    [ -z "$PG_DBNAME" ] && { echo -e "${RED}✗ Source URI must include a database name${NC}" >&2; exit 1; }
    [ -z "$PG_USER" ]   && { echo -e "${RED}✗ Source URI must include a user${NC}" >&2; exit 1; }
    [ -z "$PG_PASSWORD" ] && {
        printf "Password for %s@%s: " "$PG_USER" "$PG_HOST"
        IFS= read -rs PG_PASSWORD </dev/tty || { echo; exit 1; }
        echo ""
        SOURCE_URI="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DBNAME}"
    }
    SRC_DSN="$SOURCE_URI"
    SRC_USER="$PG_USER"; SRC_PASSWORD="$PG_PASSWORD"; SRC_HOST="$PG_HOST"
    SRC_PORT="$PG_PORT"; SRC_DBNAME="$PG_DBNAME"
    PG_USER=""; PG_PASSWORD=""; PG_HOST=""; PG_PORT=""; PG_DBNAME=""
fi

# --- Source resolution (skip for live URIs) ------------------------------------
CUSTOM_FORMAT=false    # true → ARCHIVE is a single custom-format .dump file
if [ -n "$SOURCE_URI" ]; then
    : # live source — dumped later, just before restore
elif [ -d "$ARCHIVE" ]; then
    # unpacked pg_dump -Fd directory given directly
    if [ ! -f "$ARCHIVE/toc.dat" ]; then
        echo -e "${RED}✗ Directory $ARCHIVE does not look like a pg_dump -Fd archive (no toc.dat).${NC}" >&2
        exit 1
    fi
    ARCHIVE="$(cd "$ARCHIVE" && pwd)"
else
    if [ ! -f "$ARCHIVE" ]; then
        echo -e "${RED}✗ Source not found: $ARCHIVE${NC}" >&2
        exit 1
    fi
    case "$ARCHIVE" in
        *.dump|*.pgdump) CUSTOM_FORMAT=true ;;
        *.tgz) : ;;
        *)
            # Sniff the magic header rather than trusting the extension
            if head -c 5 "$ARCHIVE" | grep -q '^PGDMP'; then
                CUSTOM_FORMAT=true
            else
                echo -e "${YELLOW}⚠ Unrecognized source extension: $ARCHIVE — assuming .tgz (tar of a -Fd directory).${NC}" >&2
            fi
            ;;
    esac
    ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
fi

# --- Determine target DB name -------------------------------------------------
if [ -z "$TARGET" ]; then
    if [ -n "$SOURCE_URI" ]; then
        TARGET="$SRC_DBNAME"
    else
        BASE=$(basename "$ARCHIVE" .tgz)
        BASE="${BASE%.dump}"
        # Strip trailing _YYYYmmdd_HHMMSS if present
        TARGET=$(echo "$BASE" | sed -E 's/_[0-9]{8}_[0-9]{6}$//')
        if [ -z "$TARGET" ] || [ "$TARGET" = "$BASE" ] && ! [[ "$BASE" =~ _[0-9]{8}_[0-9]{6}$ ]]; then
            echo -e "${YELLOW}⚠ Could not parse DB name from filename; using full basename: $BASE${NC}" >&2
            TARGET="$BASE"
        fi
    fi
fi

# --- Pick destination node (local) OR client container (remote+docker) -------
if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
    NODE=""  # host mode — no container needed
    echo -e "${GREEN}✓ Remote target:   ${PG_HOST}:${PG_PORT}/${PG_DBNAME} as ${PG_USER}${NC}" >&2

    # Reachability check from host.
    # pg_isready checks TCP + auth-handshake without requiring a specific DB to exist —
    # safer than `SELECT 1` against /postgres (some cloud providers rename or omit the
    # 'postgres' DB: DO uses 'defaultdb', Azure uses 'azure_maintenance', etc.).
    echo -e "${YELLOW}Checking remote reachability...${NC}" >&2
    if ! pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DBNAME" >/dev/null 2>&1; then
        echo -e "${RED}✗ Cannot reach ${PG_HOST}:${PG_PORT} (pg_isready failed)${NC}" >&2
        echo -e "${YELLOW}  Test: pg_isready -h $PG_HOST -p $PG_PORT -U $PG_USER -d $PG_DBNAME${NC}" >&2
        exit 1
    fi
    # Also verify we can actually connect AND authenticate by hitting the target DB.
    # Use the target DB (not /postgres) — the target was parsed from the URI and must exist.
    if ! psql "$REMOTE_DSN" -c "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}✗ Reachable but cannot authenticate to ${PG_DBNAME} as ${PG_USER}${NC}" >&2
        echo -e "${YELLOW}  Check credentials. Test: psql '$(mask_dsn "$REMOTE_DSN")' -c 'SELECT 1;'${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Remote reachable + authenticated${NC}" >&2
elif [ "$REMOTE_MODE" = true ]; then
    # remote + docker fallback: NODE = client container that runs pg_restore
    if [ -z "$NODE" ]; then
        for candidate in db1 db2 db3 db4; do
            if docker ps --format '{{.Names}}' | grep -q "^${candidate}$"; then
                NODE="$candidate"
                break
            fi
        done
        if [ -z "$NODE" ]; then
            echo -e "${RED}✗ No running db* container found to use as pg_restore client.${NC}" >&2
            echo -e "${YELLOW}  Start the cluster (make up) or install postgresql-client on the host.${NC}" >&2
            exit 1
        fi
    else
        validate_node "$NODE" || exit 1
    fi
    echo -e "${GREEN}✓ Client container: ${NODE} (executes pg_restore)${NC}" >&2
    echo -e "${GREEN}✓ Remote target:   ${PG_HOST}:${PG_PORT}/${PG_DBNAME} as ${PG_USER}${NC}" >&2

    # Reachability check — fail fast before extracting the archive.
    # pg_isready inside the container avoids needing a specific admin DB to exist
    # (some cloud providers don't have /postgres).
    echo -e "${YELLOW}Checking remote reachability...${NC}" >&2
    if ! docker exec "$NODE" pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DBNAME" >/dev/null 2>&1; then
        echo -e "${RED}✗ Cannot reach ${PG_HOST}:${PG_PORT} from ${NODE} (pg_isready failed)${NC}" >&2
        echo -e "${YELLOW}  Test: docker exec ${NODE} pg_isready -h $PG_HOST -p $PG_PORT -U $PG_USER -d $PG_DBNAME${NC}" >&2
        exit 1
    fi
    # Also auth-handshake against the target DB
    if ! docker exec "$NODE" psql "$REMOTE_DSN" -c "SELECT 1;" >/dev/null 2>&1; then
        echo -e "${RED}✗ Reachable but cannot authenticate to ${PG_DBNAME} as ${PG_USER}${NC}" >&2
        echo -e "${YELLOW}  Test: docker exec ${NODE} psql '$(mask_dsn "$REMOTE_DSN")' -c 'SELECT 1;'${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Remote reachable + authenticated${NC}" >&2
else
    if [ -z "$NODE" ]; then
        echo -e "${YELLOW}Detecting cluster leader...${NC}" >&2
        NODE=$(detect_leader_api 2>/dev/null || detect_leader)
        if [ -z "$NODE" ]; then
            echo -e "${RED}✗ Could not detect leader. Specify --node.${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}✓ Leader: ${NODE}${NC}" >&2
    else
        validate_node "$NODE" || exit 1
        LEADER=$(detect_leader_api 2>/dev/null || echo "")
        if [ -n "$LEADER" ] && [ "$NODE" != "$LEADER" ]; then
            echo -e "${YELLOW}⚠ Warning: $NODE is not the current leader ($LEADER). Restore will fail if $NODE is read-only.${NC}" >&2
        fi
    fi
fi

INTERNAL_PORT=$(get_internal_pg_port)

# --- Mode-aware SQL/restore helpers ------------------------------------------
# psql_admin     — connect to admin DB (for CREATE/DROP/EXISTS/pg_stat_activity)
# psql_target    — connect directly to the target DB (for table counts etc.)
# pg_restore_cmd — run pg_restore against the target
if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
    psql_admin()     { run_traced psql "$REMOTE_DSN_ADMIN" -t -A "$@"; }
    psql_target()    { run_traced psql "$REMOTE_DSN" -t -A "$@"; }
    # pg_restore is invoked through run_pg_restore_with_progress (see below)
elif [ "$REMOTE_MODE" = true ]; then
    psql_admin()     { run_traced docker exec "$NODE" psql "$REMOTE_DSN_ADMIN" -t -A "$@"; }
    psql_target()    { run_traced docker exec "$NODE" psql "$REMOTE_DSN" -t -A "$@"; }
else
    psql_admin()     { run_traced docker exec "$NODE" psql -U postgres -d postgres -p "$INTERNAL_PORT" -h localhost -t -A "$@"; }
    psql_target()    { run_traced docker exec "$NODE" psql -U postgres -d "$TARGET" -p "$INTERNAL_PORT" -h localhost -t -A "$@"; }
fi

# build_resume_toc_list: emits a TOC --use-list filter that selects
# post-data items + SEQUENCE SET items but EXCLUDES TABLE DATA.
#
# Why this is needed (C2 fix):
# pg_dump's TOC places SEQUENCE SET entries in the *data* section, not
# post-data. Using plain `--section=post-data` on a resume silently skips
# SEQUENCE SET; after the resume "succeeds", every nextval() call collides
# with existing rows. We rebuild the TOC and only comment-out (skip) the
# TABLE DATA entries — everything else (including SEQUENCE SET + post-data
# items) gets restored.
#
# Result file: ${extract_path}/.resume_toc.list (cleaned up by the EXIT trap).
build_resume_toc_list() {
    local extract_path="$1"
    local toc_file="${extract_path}/.resume_toc.list"
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        pg_restore -l "$extract_path" > "$toc_file" 2>/dev/null || return 1
    else
        # Generate inside the container, then read back to a path the client can pass
        docker exec "$NODE" sh -c "pg_restore -l '$extract_path' > '$toc_file'" 2>/dev/null || return 1
    fi
    # Comment out TABLE DATA lines (those rows are already loaded).
    # pg_restore -l line format: "ID; OID OID TYPE schema name owner"
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        sed -i.bak -E 's/^([0-9]+; [0-9]+ [0-9]+ TABLE DATA )/;\1/' "$toc_file" 2>/dev/null
        rm -f "${toc_file}.bak"
    else
        docker exec "$NODE" sed -i -E 's/^([0-9]+; [0-9]+ [0-9]+ TABLE DATA )/;\1/' "$toc_file" 2>/dev/null
    fi
    echo "$toc_file"
}

# build_pg_restore_argv: returns the pg_restore argv for the current mode.
# Echo'd NUL-separated, caller reads into an array. Includes --verbose so we
# can parse progress; --exit-on-error=false makes the parallel default explicit.
# In RESUME_MODE, uses --use-list with a TOC that excludes TABLE DATA.
build_pg_restore_argv() {
    local extract_path="$1"
    local resume_args=""
    if [ "$RESUME_MODE" = true ]; then
        local toc
        toc=$(build_resume_toc_list "$extract_path") || {
            echo -e "${RED}✗ Could not build resume TOC list from $extract_path${NC}" >&2
            return 1
        }
        resume_args="--use-list=$toc"
    fi
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        printf '%s\0' pg_restore --verbose $resume_args "--dbname=$REMOTE_DSN" -Fd -j "$JOBS" $EXTRA_FLAGS "$extract_path"
    elif [ "$REMOTE_MODE" = true ]; then
        printf '%s\0' docker exec "$NODE" pg_restore --verbose $resume_args "--dbname=$REMOTE_DSN" -Fd -j "$JOBS" $EXTRA_FLAGS "$extract_path"
    else
        printf '%s\0' docker exec "$NODE" pg_restore --verbose $resume_args -U postgres -d "$TARGET" -p "$INTERNAL_PORT" -h localhost -Fd -j "$JOBS" $EXTRA_FLAGS "$extract_path"
    fi
}

# count_toc_entries: returns total number of TOC entries (for progress %).
# In RESUME_MODE, counts the resume filter list (post-data + SEQUENCE SET,
# excluding TABLE DATA) — matches what pg_restore will actually attempt.
count_toc_entries() {
    local extract_path="$1"
    local total=0
    if [ "$RESUME_MODE" = true ]; then
        local toc="${extract_path}/.resume_toc.list"
        if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
            [ -f "$toc" ] && total=$(grep -c '^[0-9]' "$toc" 2>/dev/null || true)
        else
            total=$(docker exec "$NODE" sh -c "test -f '$toc' && grep -c '^[0-9]' '$toc'" 2>/dev/null || true)
        fi
    else
        if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
            total=$(pg_restore -l "$extract_path" 2>/dev/null | grep -c '^[0-9]' || true)
        else
            total=$(docker exec "$NODE" pg_restore -l "$extract_path" 2>/dev/null | grep -c '^[0-9]' || true)
        fi
    fi
    [ -z "$total" ] && total=0
    echo "$total"
}

# run_pg_restore_with_progress:
#   - Counts TOC entries to compute %
#   - Runs pg_restore --verbose; parses output for object-level progress
#   - Updates a single \r-prefixed status line: [pct%] done/total  current item
#   - Background watchdog warns if no progress for $STALL_THRESHOLD_SECONDS
# Sets RESTORE_EXIT to pg_restore's exit code.
run_pg_restore_with_progress() {
    local extract_path="$1"
    local total
    total=$(count_toc_entries "$extract_path")

    local -a argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done < <(build_pg_restore_argv "$extract_path")

    echo -e "${CYAN}  Objects to restore: ${total:-unknown}${NC}"
    trace_cmd "${argv[@]}"

    # Heartbeat file — awk re-writes it on each progress update; the watchdog
    # checks its mtime and warns if pg_restore appears stalled.
    local hb="/tmp/.pg_restore_heartbeat.$$"
    local hb_guard="${hb}.guard"
    local stall_threshold="${STALL_THRESHOLD_SECONDS:-180}"
    echo 0 > "$hb"
    touch "$hb_guard"

    # Background stall-watchdog. Polls every 30s, prints a yellow warning if
    # heartbeat hasn't been touched in $stall_threshold seconds. Self-rate-limits
    # by re-touching the heartbeat after each warning.
    (
        while [ -f "$hb_guard" ]; do
            sleep 30
            [ -f "$hb_guard" ] || break
            [ -f "$hb" ] || continue
            local last_mod now age
            last_mod=$(stat -f '%m' "$hb" 2>/dev/null || stat -c '%Y' "$hb" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$((now - last_mod))
            if [ "$age" -gt "$stall_threshold" ]; then
                printf "\n${YELLOW}⚠ pg_restore appears stalled — no new TOC item for ${age}s${NC}\n" >&2
                printf "${YELLOW}  Common causes: PgBouncer pool exhaustion, network hang, lock wait, slow disk on remote.${NC}\n" >&2
                printf "${YELLOW}  Check: docker logs backup / pg_stat_activity on the target / network to ${PG_HOST}.${NC}\n" >&2
                touch "$hb"   # reset so we don't spam every 30s
            fi
        done
    ) &
    local watchdog_pid=$!

    local pg_started
    pg_started=$(date +%s)
    set +e
    # awk parses pg_restore --verbose lines and:
    #   (a) updates the \r-prefixed progress line on stderr
    #   (b) re-writes the heartbeat file so the watchdog sees activity
    # Counting rule: only start-of-work markers (creating/processing/executing/setting),
    # NOT "finished item" — counting both would double in -j N parallel mode.
    "${argv[@]}" 2>&1 | awk -v total="$total" -v hb="$hb" '
        /^pg_restore: (creating|processing data|executing|setting owner)/ {
            n++
            sub(/^pg_restore: /, "", $0)
            label = substr($0, 1, 70)
            if (total > 0) {
                pct = int(n * 100 / total)
                if (pct > 100) pct = 100
                printf("\r  [%3d%%] %d/%d  %-72s\033[K", pct, n, total, label) > "/dev/stderr"
            } else {
                printf("\r  [%d objects] %-72s\033[K", n, label) > "/dev/stderr"
            }
            fflush()
            # Touch the heartbeat (write small content + flush — bumps mtime).
            print n > hb
            close(hb)
            next
        }
        /^pg_restore: (error|warning):/ {
            printf("\n%s\n", $0) > "/dev/stderr"
            next
        }
        { next }
    '
    RESTORE_EXIT=${PIPESTATUS[0]}
    set -e

    # Tear down the watchdog
    rm -f "$hb_guard"
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    rm -f "$hb"

    local pg_elapsed=$(( $(date +%s) - pg_started ))
    echo "" >&2
    echo -e "${CYAN}  pg_restore elapsed: ${pg_elapsed}s${NC}" >&2
}

# --- Quote helper for psql identifiers ----------------------------------------
quote_ident() {
    local s="${1//\"/\"\"}"
    echo "\"$s\""
}
quote_literal() {
    local s="${1//\'/\'\'}"
    echo "'$s'"
}

TARGET_QUOTED_IDENT=$(quote_ident "$TARGET")
TARGET_QUOTED_LIT=$(quote_literal "$TARGET")

# --- Check if target DB exists ------------------------------------------------
EXISTS=$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = ${TARGET_QUOTED_LIT};" 2>/dev/null | tr -d ' ')

# --- Resume detection: look for a saved state file from a prior interrupt -----
# Only auto-resume when: target DB exists, state file matches, --clean NOT set.
# When --clean is set, the user is opting out of resume — wipe the state file.
RESUME_MODE=false
if [ "$REMOTE_MODE" = true ]; then
    STATE_KEY=$(state_key "$ARCHIVE" "${PG_HOST}:${PG_PORT}/${TARGET}")
else
    STATE_KEY=$(state_key "$ARCHIVE" "local/${TARGET}")
fi
STATE_FILE_PATH=$(state_file_path "$STATE_KEY")

if [ "$CLEAN" = true ] && [ -f "$STATE_FILE_PATH" ]; then
    echo -e "${YELLOW}⚠ --clean was passed; ignoring saved state at $STATE_FILE_PATH${NC}" >&2
    clear_state_file "$STATE_KEY"
elif [ "$EXISTS" = "1" ] && [ -f "$STATE_FILE_PATH" ] && [ "$CLEAN" = false ]; then
    # Load saved state into shadow vars (we don't want to clobber current invocation).
    # We deliberately avoid `eval` / `source` here: the state file is on disk and could
    # in principle be corrupted, hand-edited, or world-readable on a poorly-perm'd box.
    # _state_decode strips the surrounding single quotes and unescapes '\'' sequences.
    PREV_ARCHIVE=""; PREV_EXTRACT_PATH=""; PREV_INTERRUPT_TIME=""; PREV_JOBS=""
    _state_decode() {
        local s="$1"
        # Strip leading and trailing single quote, if present
        s="${s#\'}"
        s="${s%\'}"
        # Unescape '\'' → '
        printf '%s' "${s//\'\\\'\'/\'}"
    }
    while IFS='=' read -r k v; do
        # Skip malformed lines (don't abort under set -e)
        [[ "$k" =~ ^[A-Z_]+$ ]] || continue
        case "$k" in
            ARCHIVE)        PREV_ARCHIVE=$(_state_decode "$v") ;;
            EXTRACT_PATH)   PREV_EXTRACT_PATH=$(_state_decode "$v") ;;
            INTERRUPT_TIME) PREV_INTERRUPT_TIME=$(_state_decode "$v") ;;
            JOBS)           PREV_JOBS=$(_state_decode "$v") ;;
        esac
    done < <(grep -E '^[A-Z_]+=' "$STATE_FILE_PATH" 2>/dev/null || true)

    AGE_HUMAN="unknown"
    if [ -n "$PREV_INTERRUPT_TIME" ]; then
        AGE_HUMAN="$PREV_INTERRUPT_TIME"
    fi

    # Probe the target DB: how many user tables already have data? This guards
    # against resuming a DB that never reached TABLE DATA loading — without this,
    # resume would build constraints/indexes/FKs on empty tables and produce a
    # "successful" restore that is silently empty.
    NONEMPTY_TABLES=$(psql_target -c "
        SELECT COUNT(*) FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND pg_relation_size(quote_ident(schemaname)||'.'||quote_ident(tablename)) > 8192;
    " 2>/dev/null | tr -d ' ')
    [ -z "$NONEMPTY_TABLES" ] && NONEMPTY_TABLES=0

    echo ""
    echo -e "${CYAN}${BOLD}⏵ Resume detected${NC}"
    echo -e "  ${CYAN}Saved at:${NC}        $AGE_HUMAN"
    echo -e "  ${CYAN}State file:${NC}      $STATE_FILE_PATH"
    echo -e "  ${CYAN}Saved jobs:${NC}      $PREV_JOBS  (current: $JOBS)"
    echo -e "  ${CYAN}Tables w/ data:${NC}  $NONEMPTY_TABLES (>8KB each)"
    echo ""
    if [ "$NONEMPTY_TABLES" = "0" ]; then
        echo -e "${RED}${BOLD}✗ Cannot resume: no tables in '$TARGET' have data.${NC}" >&2
        echo -e "${YELLOW}The previous interrupt likely fired BEFORE TABLE DATA finished loading.${NC}" >&2
        echo -e "${YELLOW}Resuming with post-data-only would build constraints/indexes on empty tables.${NC}" >&2
        echo -e "${YELLOW}  Re-run with ${BOLD}CLEAN=1${NC}${YELLOW} to drop the partial DB and restart from scratch.${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}A previous restore of this archive into '$TARGET' was interrupted.${NC}"
    echo -e "${YELLOW}Resuming will run pg_restore with a ${BOLD}--use-list${NC}${YELLOW} filter that:${NC}"
    echo -e "${YELLOW}  - skips TABLE DATA (rows are already loaded)${NC}"
    echo -e "${YELLOW}  - re-applies indexes, constraints (PK/UQ/FK), triggers${NC}"
    echo -e "${YELLOW}  - ${BOLD}applies SEQUENCE SET${NC}${YELLOW} so nextval() resumes from the correct value${NC}"
    echo -e "${YELLOW}  - 'already exists' errors on items previously created are tolerated${NC}"
    echo ""
    if [ "$ASSUME_YES" = true ]; then
        echo -e "${GREEN}--yes set: resuming automatically.${NC}"
        RESUME_MODE=true
    else
        echo -ne "${BOLD}Resume the interrupted restore? [${GREEN}y${NC}${BOLD}]es  [${YELLOW}n${NC}${BOLD}]o (cancel)  [${RED}c${NC}${BOLD}]lean wipe & restart: ${NC}"
        read -r resume_ans || resume_ans=""
        case "$resume_ans" in
            y|Y|yes|YES)
                RESUME_MODE=true
                ;;
            c|C|clean|CLEAN)
                echo -e "${YELLOW}Cleaning saved state + switching to full restore (DROP + RECREATE).${NC}"
                clear_state_file "$STATE_KEY"
                CLEAN=true   # Hand off to the existing DROP/RECREATE path
                # The downstream DROP branch already prompts again; users get
                # one more confirmation before destructive action.
                ;;
            *)
                echo -e "${YELLOW}Cancelled.${NC}"
                exit 1
                ;;
        esac
    fi
fi

# --- Detect active connections to the target DB ------------------------------
ACTIVE_COUNT=0
ACTIVE_DETAIL=""
if [ "$EXISTS" = "1" ]; then
    ACTIVE_DETAIL=$(psql_admin -F'|' -c \
        "SELECT pid, COALESCE(usename,'?'), COALESCE(NULLIF(application_name,''),'?'), COALESCE(client_addr::text,'local'), state FROM pg_stat_activity WHERE datname = ${TARGET_QUOTED_LIT} AND pid <> pg_backend_pid() ORDER BY backend_start;" 2>/dev/null || true)
    if [ -n "$ACTIVE_DETAIL" ]; then
        ACTIVE_COUNT=$(printf '%s\n' "$ACTIVE_DETAIL" | grep -c '^[0-9]' || true)
    fi
fi

# --- Show plan ----------------------------------------------------------------
if [ -n "$SOURCE_URI" ]; then
    ARCHIVE_DISPLAY="live URI ($(mask_dsn "$SOURCE_URI"))"
    ARCHIVE_SIZE=""
else
    ARCHIVE_SIZE=$(du -h "$ARCHIVE" | awk '{print $1}')
    ARCHIVE_DISPLAY="$ARCHIVE  (${ARCHIVE_SIZE})"
fi
echo ""
echo -e "${BLUE}${BOLD}=== Restore Plan ===${NC}"
echo -e "  ${CYAN}Archive:${NC}      $ARCHIVE_DISPLAY"
echo -e "  ${CYAN}Target DB:${NC}    $TARGET"
if [ "$REMOTE_MODE" = true ]; then
    echo -e "  ${CYAN}Target type:${NC}  ${YELLOW}${BOLD}REMOTE${NC}"
    echo -e "  ${CYAN}Remote host:${NC}  ${PG_HOST}:${PG_PORT} as ${PG_USER}"
    echo -e "  ${CYAN}Target DSN:${NC}   $(mask_dsn "$REMOTE_DSN")"
    if [ "$CLIENT_MODE" = "host" ]; then
        echo -e "  ${CYAN}Via client:${NC}   ${GREEN}host${NC} (${HOST_PG_RESTORE_VER})"
    else
        echo -e "  ${CYAN}Via client:${NC}   ${YELLOW}docker${NC} → $NODE container (host lacks pg_restore/psql)"
    fi
else
    echo -e "  ${CYAN}Target node:${NC}  $NODE (leader)"
fi
echo -e "  ${CYAN}Jobs:${NC}         $JOBS"
EXTRA_FLAGS=""
[ "$NO_OWNER" = true ] && EXTRA_FLAGS="$EXTRA_FLAGS --no-owner"
[ "$NO_ACL" = true ] && EXTRA_FLAGS="$EXTRA_FLAGS --no-acl"
echo -e "  ${CYAN}pg_restore opts:${NC}${EXTRA_FLAGS:- (default)}"
if [ "$EXISTS" = "1" ]; then
    if [ "$RESUME_MODE" = true ]; then
        echo -e "  ${CYAN}Mode:${NC}         ${GREEN}${BOLD}RESUME${NC} (post-data only — indexes/constraints/triggers)"
    elif [ "$CLEAN" = true ]; then
        echo -e "  ${CYAN}Mode:${NC}         ${YELLOW}${BOLD}DROP + RECREATE${NC} (target already exists)"
    else
        if [ "$INTERACTIVE" = true ]; then
            echo -e "  ${CYAN}Mode:${NC}         ${YELLOW}TARGET EXISTS${NC} — choose action below"
        else
            echo ""
            if [ "$REMOTE_MODE" = true ]; then
                echo -e "${RED}✗ Target database '$TARGET' already exists on ${PG_HOST}:${PG_PORT}.${NC}" >&2
            else
                echo -e "${RED}✗ Target database '$TARGET' already exists on $NODE.${NC}" >&2
            fi
            echo -e "${YELLOW}  Pass CLEAN=1 to drop and recreate, or TARGET=NAME to restore into a different DB.${NC}" >&2
            echo -e "${YELLOW}  (No saved state file found for this archive+target — nothing to resume.)${NC}" >&2
            exit 1
        fi
    fi
    if [ "$RESUME_MODE" != true ] && [ "$ACTIVE_COUNT" -gt 0 ]; then
        echo -e "  ${CYAN}Active conns:${NC} ${RED}${BOLD}${ACTIVE_COUNT}${NC} — will be ${YELLOW}terminated${NC}"
        printf '%s\n' "$ACTIVE_DETAIL" | head -5 | awk -F'|' '{printf "      • pid=%s user=%s app=%s addr=%s state=%s\n", $1, $2, $3, $4, $5}'
        if [ "$ACTIVE_COUNT" -gt 5 ]; then
            echo "      • ... and $((ACTIVE_COUNT - 5)) more"
        fi
    elif [ "$RESUME_MODE" != true ]; then
        echo -e "  ${CYAN}Active conns:${NC} 0"
    fi
else
    echo -e "  ${CYAN}Mode:${NC}         CREATE new database"
fi
echo ""

# --- Start / Cancel confirmation ----------------------------------------------
if [ "$ASSUME_YES" = false ]; then
    if [ "$EXISTS" = "1" ] && [ "$CLEAN" != true ] && [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}${BOLD}Target database '$TARGET' already exists on $NODE.${NC}"
        echo -e "${YELLOW}Choose action:${NC}"
        echo -e "  ${GREEN}d${NC}  Drop and recreate (CLEAN)"
        echo -e "  ${CYAN}r${NC}  Restore into a different database name"
        echo -e "  ${RED}c${NC}  Cancel"
        echo -ne "${BOLD}Action [d/r/c]: ${NC}"
        read -r choice
        case "$choice" in
            d|D|drop|DROP)
                CLEAN=true
                ;;
            r|R|rename|RENAME)
                echo -ne "${BOLD}New target database name: ${NC}"
                read -r new_target
                if [ -n "$new_target" ]; then
                    TARGET="$new_target"
                    # Re-check if new target exists
                    EXISTS=0
                else
                    echo -e "${YELLOW}Cancelled.${NC}"; exit 1
                fi
                ;;
            *)
                echo -e "${YELLOW}Cancelled.${NC}"; exit 1
                ;;
        esac
    fi
    if [ "$EXISTS" = "1" ] && [ "$CLEAN" = true ]; then
        if [ "$REMOTE_MODE" = true ]; then
            WARN="${RED}${BOLD}This will DROP '$TARGET' on REMOTE ${PG_HOST}:${PG_PORT}"
        else
            WARN="${RED}${BOLD}This will DROP '$TARGET' on $NODE"
        fi
        [ "$ACTIVE_COUNT" -gt 0 ] && WARN="${WARN} and terminate ${ACTIVE_COUNT} connection(s)"
        echo -e "${WARN}.${NC}"
    fi
    echo -ne "${BOLD}Action — [${GREEN}s${NC}${BOLD}]tart  [${RED}c${NC}${BOLD}]ancel: ${NC}"
    read -r confirm
    case "$confirm" in
        s|S|start|START|y|Y|yes|YES) echo -e "${GREEN}✓ Starting...${NC}" ;;
        *) echo -e "${YELLOW}Cancelled.${NC}"; exit 1 ;;
    esac
fi

# --- Prepare paths ------------------------------------------------------------
# Stages (steps 1-2 of 5) produce EXTRACT_PATH: a pg_dump input the restore
# client can read — an unpacked -Fd directory OR a custom-format file.
#   .tgz      → copy + tar -xzf (original flow)
#   .dump     → copy only (CUSTOM_FORMAT)
#   directory → copy only (already -Fd)
#   live URI  → pg_dump -Fd on the fly (dump_from_live_uri), then copy
ARCHIVE_BASE="live_$(printf '%s' "${SRC_DBNAME:-db}" | tr -c 'A-Za-z0-9_.-' '_')"
[ -n "$ARCHIVE" ] && ARCHIVE_BASE=$(basename "$ARCHIVE")
DUMP_DIR_NAME="${ARCHIVE_BASE%.tgz}"
DUMP_DIR_NAME="${DUMP_DIR_NAME%.dump}"

# dump_from_live_uri: probe the source, then pg_dump -Fd into a HOST directory.
# Uses the leader / first running db container as the dump client; falls back
# to a one-shot postgres:<major> image when the source is NEWER than the cluster.
dump_from_live_uri() {
    local host_for_client="$SRC_HOST"
    case "$SRC_HOST" in localhost|127.0.0.1|::1)
        echo -e "${YELLOW}NOTE: source host '$SRC_HOST' rewritten to host.docker.internal for the container client${NC}" >&2
        host_for_client="host.docker.internal" ;;
    esac
    local dsn="postgresql://${SRC_USER}:${SRC_PASSWORD}@${host_for_client}:${SRC_PORT}/${SRC_DBNAME}"

    local client=""
    client=$(detect_leader 2>/dev/null || true)
    [ -z "$client" ] && for n in $(get_db_nodes); do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${n}$" && { client="$n"; break; }
    done

    echo -e "${YELLOW}[0/5] Probing live source ${SRC_USER}@${host_for_client}:${SRC_PORT}/${SRC_DBNAME}...${NC}" >&2
    local src_version="" src_size=""
    if [ -n "$client" ]; then
        src_version=$(docker exec -e PGPASSWORD="$SRC_PASSWORD" "$client" \
            psql "$dsn" -tAc "SHOW server_version" 2>/dev/null | head -1)
        [ -n "$src_version" ] && src_size=$(docker exec -e PGPASSWORD="$SRC_PASSWORD" "$client" \
            psql "$dsn" -tAc "SELECT pg_size_pretty(pg_database_size(current_database()))" 2>/dev/null | head -1)
    fi
    if [ -z "$src_version" ]; then
        echo -e "${RED}✗ Could not connect to the live source.${NC}" >&2
        echo -e "${YELLOW}  Check the URI, credentials, and reachability from Docker.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Source reachable: PostgreSQL $src_version${src_size:+ ($src_size)}${NC}" >&2

    LIVE_DUMP_HOST="$(mktemp -d "${TMPDIR:-/tmp}/restore_live_${SRC_DBNAME}.XXXXXX")"
    local src_major="${src_version%%.*}"

    if [ -n "$client" ] && [ "${src_major:-0}" -le "$(get_patroni_pg_version 2>/dev/null || echo 0)" ] 2>/dev/null; then
        echo -e "${YELLOW}[1/5] Dumping live source with pg_dump -Fd (client: $client)...${NC}" >&2
        trace_cmd docker exec -e PGPASSWORD="****" "$client" pg_dump -Fd -f "/tmp/live_dump_$$" "$dsn"
        docker exec -e PGPASSWORD="$SRC_PASSWORD" "$client" \
            pg_dump -Fd -f "/tmp/live_dump_$$" "$dsn" || { echo -e "${RED}✗ pg_dump failed.${NC}" >&2; exit 1; }
        docker cp "$client:/tmp/live_dump_$$/." "$LIVE_DUMP_HOST/" || { echo -e "${RED}✗ Could not copy dump from $client.${NC}" >&2; exit 1; }
        docker exec "$client" rm -rf "/tmp/live_dump_$$"
    else
        echo -e "${YELLOW}[1/5] Dumping live source with pg_dump -Fd (postgres:${src_major} image — source newer than cluster)...${NC}" >&2
        trace_cmd docker run --rm -v "$LIVE_DUMP_HOST":/out -e PGPASSWORD="****" "postgres:$src_major" \
            pg_dump -Fd -f /out "$dsn"
        docker run --rm -v "$LIVE_DUMP_HOST":/out -e PGPASSWORD="$SRC_PASSWORD" "postgres:$src_major" \
            pg_dump -Fd -f /out "$dsn" || { echo -e "${RED}✗ pg_dump failed.${NC}" >&2; exit 1; }
    fi
    [ -f "$LIVE_DUMP_HOST/toc.dat" ] || { echo -e "${RED}✗ Dump directory is missing toc.dat — aborting.${NC}" >&2; exit 1; }
    echo -e "${GREEN}✓ Live dump complete ($(du -sh "$LIVE_DUMP_HOST" | awk '{print $1}'))${NC}" >&2
}

cleanup_live_dump() { [ -n "${LIVE_DUMP_HOST:-}" ] && rm -rf "$LIVE_DUMP_HOST" 2>/dev/null || true; }

if [ -n "$SOURCE_URI" ]; then
    dump_from_live_uri
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        # host-mode remote target: restore reads the dump right on the host
        EXTRACT_PATH="$LIVE_DUMP_HOST"
        cleanup() { cleanup_live_dump; }
    else
        # local target or docker-client remote: stage the dump inside the client container
        CONTAINER_DIR="/tmp/${DUMP_DIR_NAME}"
        docker exec "$NODE" rm -rf "$CONTAINER_DIR" 2>/dev/null || true
        docker cp "$LIVE_DUMP_HOST" "$NODE:$CONTAINER_DIR" || { echo -e "${RED}✗ Could not stage live dump into $NODE.${NC}" >&2; exit 1; }
        EXTRACT_PATH="$CONTAINER_DIR"
        cleanup() { cleanup_live_dump; docker exec "$NODE" rm -rf "$CONTAINER_DIR" 2>/dev/null || true; }
    fi
    trap cleanup EXIT
    echo -e "${YELLOW}[2/5] (skipped — live source dumped straight to -Fd directory)${NC}" >&2
elif [ "$CUSTOM_FORMAT" = true ]; then
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        EXTRACT_PATH="$ARCHIVE"
        cleanup() { :; }
    else
        CONTAINER_DUMP="/tmp/${ARCHIVE_BASE}"
        echo -e "${YELLOW}[1/5] Copying custom-format dump into ${NODE}...${NC}" >&2
        run_traced docker cp "$ARCHIVE" "$NODE:$CONTAINER_DUMP"
        echo -e "${GREEN}✓ Copied${NC}" >&2
        EXTRACT_PATH="$CONTAINER_DUMP"
        cleanup() { docker exec "$NODE" rm -rf "$CONTAINER_DUMP" 2>/dev/null || true; }
    fi
    trap cleanup EXIT
    echo -e "${YELLOW}[2/5] (skipped — custom-format file needs no extraction)${NC}" >&2
elif [ -d "$ARCHIVE" ]; then
    if [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
        EXTRACT_PATH="$ARCHIVE"
        cleanup() { :; }
    else
        CONTAINER_DIR="/tmp/${DUMP_DIR_NAME}"
        echo -e "${YELLOW}[1/5] Copying -Fd directory into ${NODE}...${NC}" >&2
        run_traced docker cp "$ARCHIVE" "$NODE:$CONTAINER_DIR"
        echo -e "${GREEN}✓ Copied${NC}" >&2
        EXTRACT_PATH="$CONTAINER_DIR"
        cleanup() { docker exec "$NODE" rm -rf "$CONTAINER_DIR" 2>/dev/null || true; }
    fi
    trap cleanup EXIT
    echo -e "${YELLOW}[2/5] (skipped — directory is already unpacked)${NC}" >&2
elif [ "$REMOTE_MODE" = true ] && [ "$CLIENT_MODE" = "host" ]; then
    # Extract directly on the host — no docker cp needed
    EXTRACT_BASE="/tmp"
    EXTRACT_PATH="${EXTRACT_BASE}/${DUMP_DIR_NAME}"
    cleanup() { rm -rf "$EXTRACT_PATH" 2>/dev/null || true; }
    trap cleanup EXIT

    echo -e "${YELLOW}[1/5] Extracting archive on host (${EXTRACT_BASE})...${NC}"
    run_traced tar -xzf "$ARCHIVE" -C "$EXTRACT_BASE"
    if [ ! -f "$EXTRACT_PATH/toc.dat" ]; then
        echo -e "${RED}✗ Extracted directory does not look like a pg_dump archive (no toc.dat at $EXTRACT_PATH).${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Extracted${NC}"
    echo -e "${YELLOW}[2/5] (skipped — host extraction did both copy + extract)${NC}" >&2
else
    # Extract inside the container
    CONTAINER_TGZ="/tmp/${ARCHIVE_BASE}"
    EXTRACT_PATH="/tmp/${DUMP_DIR_NAME}"
    cleanup() { docker exec "$NODE" rm -rf "$CONTAINER_TGZ" "$EXTRACT_PATH" 2>/dev/null || true; }
    trap cleanup EXIT

    echo -e "${YELLOW}[1/5] Copying archive into ${NODE}...${NC}" >&2
    run_traced docker cp "$ARCHIVE" "$NODE:$CONTAINER_TGZ"
    echo -e "${GREEN}✓ Copied${NC}" >&2

    echo -e "${YELLOW}[2/5] Extracting archive in ${NODE}...${NC}" >&2
    run_traced docker exec "$NODE" tar -xzf "$CONTAINER_TGZ" -C /tmp
    if ! docker exec "$NODE" test -f "$EXTRACT_PATH/toc.dat"; then
        echo -e "${RED}✗ Extracted directory does not look like a pg_dump archive (no toc.dat at $EXTRACT_PATH).${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Extracted${NC}"
fi

START_TS=$(date +%s)

if [ "$RESUME_MODE" = true ]; then
    echo -e "${YELLOW}[3/5] (skipped — RESUME mode preserves existing database '$TARGET')${NC}"
    echo -e "${YELLOW}[4/5] (skipped — RESUME mode reuses existing database '$TARGET')${NC}"
else
    if [ "$EXISTS" = "1" ] && [ "$CLEAN" = true ]; then
        echo -e "${YELLOW}[3/5] Dropping existing database '$TARGET'...${NC}"
        psql_admin -v ON_ERROR_STOP=1 -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ${TARGET_QUOTED_LIT} AND pid <> pg_backend_pid();" >/dev/null
        psql_admin -v ON_ERROR_STOP=1 -c "DROP DATABASE ${TARGET_QUOTED_IDENT};"
        echo -e "${GREEN}✓ Dropped${NC}"
        EXISTS=0
    fi

    if [ "$EXISTS" != "1" ]; then
        echo -e "${YELLOW}[4/5] Creating empty database '$TARGET'...${NC}"
        psql_admin -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${TARGET_QUOTED_IDENT};"
        echo -e "${GREEN}✓ Created${NC}"
    fi
fi

if [ "$RESUME_MODE" = true ]; then
    echo -e "${YELLOW}[5/5] Running pg_restore (-j $JOBS) with progress — ${BOLD}post-data section only${NC}${YELLOW}...${NC}"
else
    echo -e "${YELLOW}[5/5] Running pg_restore (-j $JOBS) with progress...${NC}"
fi
RESTORE_EXIT=0
run_pg_restore_with_progress "$EXTRACT_PATH"

DURATION=$(($(date +%s) - START_TS))

# pg_restore exit codes:
#   0   — success
#   1   — completed with warnings (e.g. role/ownership mismatches) OR was SIGINT'd
#   >1  — fatal error
# When the user pressed Ctrl+C, pg_restore catches SIGINT and exits 1 — same
# code as "warnings". We can only distinguish them via the INTERRUPTED flag
# set by our own SIGINT trap.
if [ "$INTERRUPTED" = true ]; then
    echo ""
    echo -e "${RED}${BOLD}=== Restore INTERRUPTED ===${NC}" >&2
    echo -e "  ${CYAN}Target DB:${NC}  $TARGET"
    if [ "$REMOTE_MODE" = true ]; then
        echo -e "  ${CYAN}Remote:${NC}     ${PG_HOST}:${PG_PORT} as ${PG_USER}"
    else
        echo -e "  ${CYAN}Node:${NC}       $NODE"
    fi
    echo -e "  ${CYAN}Duration:${NC}   ${DURATION}s (aborted before completion)"

    # Save state so the next invocation can auto-detect + resume.
    # Key is a stable hash of archive+target (no password).
    if [ "$REMOTE_MODE" = true ]; then
        STATE_KEY=$(state_key "$ARCHIVE" "${PG_HOST}:${PG_PORT}/${TARGET}")
    else
        STATE_KEY=$(state_key "$ARCHIVE" "local/${TARGET}")
    fi
    save_state_file "$STATE_KEY"

    echo ""
    echo -e "${YELLOW}${BOLD}Data is likely partial.${NC}"
    echo -e "${YELLOW}  - TABLE DATA loads run early in the TOC, so rows are usually present.${NC}"
    echo -e "${YELLOW}  - Indexes, constraints (PRIMARY/UNIQUE/${BOLD}FOREIGN KEY${NC}${YELLOW}), triggers, and SEQUENCE SETs run late and may be MISSING.${NC}"
    echo -e "${YELLOW}  - Without FKs, referential integrity is NOT enforced. Without SEQUENCE SETs, nextval() will collide.${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}To finish only the missing tail:${NC} re-run the SAME command you ran originally."
    echo -e "${GREEN}The script will detect the saved state and offer to resume (skips TABLE DATA,${NC}"
    echo -e "${GREEN}re-applies indexes/constraints/triggers/sequences via --use-list filter).${NC}"
    echo ""
    if [ "$REMOTE_MODE" = true ]; then
        # Print the command with a placeholder for the password — the masked **** form
        # can't be pasted back (libpq would treat **** as the literal password and fail
        # auth). Tell the user explicitly to use their original DSN.
        _safe_dsn="postgresql://${PG_USER}:<YOUR_PASSWORD>@${PG_HOST}:${PG_PORT}/${PG_DBNAME}"
        echo -e "  ${CYAN}make restore-db ARCHIVE='$ARCHIVE' \\\\${NC}"
        echo -e "  ${CYAN}    TARGET='$_safe_dsn'${NC}"
        echo -e "  ${YELLOW}(substitute <YOUR_PASSWORD> with your original DSN password)${NC}"
    else
        echo -e "  ${CYAN}make restore-db ARCHIVE='$ARCHIVE' TARGET='$TARGET'${NC}"
    fi
    echo ""
    echo -e "${CYAN}To start fresh instead (drops the partial DB):${NC} add ${BOLD}CLEAN=1${NC}"
    exit 130
fi

if [ "$RESTORE_EXIT" -gt 1 ]; then
    echo ""
    echo -e "${RED}✗ pg_restore failed (exit $RESTORE_EXIT)${NC}" >&2
    # Don't clear state — failure could be transient; keep so user can re-resume
    exit "$RESTORE_EXIT"
elif [ "$RESTORE_EXIT" -eq 1 ]; then
    if [ "$RESUME_MODE" = true ]; then
        echo -e "${YELLOW}⚠ pg_restore (resume) finished with warnings (exit 1). Expected: 'already exists' errors on items that were created before the interrupt.${NC}"
    else
        echo -e "${YELLOW}⚠ pg_restore finished with warnings (exit 1). Common with role/ownership mismatches; data should be intact.${NC}"
    fi
else
    echo -e "${GREEN}✓ pg_restore complete${NC}"
fi

# Restore succeeded (exit 0 or 1) — clear the saved-state file
if [ -n "$STATE_KEY" ]; then
    clear_state_file "$STATE_KEY"
fi

# Post-restore stats
TABLE_COUNT=$(psql_target -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE';" 2>/dev/null | tr -d ' ')
DB_SIZE=$(psql_admin -c "SELECT pg_size_pretty(pg_database_size(${TARGET_QUOTED_LIT}));" 2>/dev/null | tr -d ' ')

echo ""
echo -e "${BLUE}${BOLD}=== Restore Complete ===${NC}"
echo -e "  ${CYAN}Target DB:${NC} $TARGET"
if [ "$REMOTE_MODE" = true ]; then
    echo -e "  ${CYAN}Remote:${NC}    ${PG_HOST}:${PG_PORT} as ${PG_USER}"
    if [ "$CLIENT_MODE" = "host" ]; then
        echo -e "  ${CYAN}Via:${NC}       host pg_restore"
    else
        echo -e "  ${CYAN}Via:${NC}       $NODE container"
    fi
else
    echo -e "  ${CYAN}Node:${NC}      $NODE"
fi
echo -e "  ${CYAN}Tables:${NC}    ${TABLE_COUNT:-?}"
echo -e "  ${CYAN}DB size:${NC}   ${DB_SIZE:-?}"
echo -e "  ${CYAN}Duration:${NC}  ${DURATION}s"
echo ""
echo -e "${CYAN}Connect:${NC}"
if [ "$REMOTE_MODE" = true ]; then
    echo -e "  psql '$(mask_dsn "$REMOTE_DSN")'"
else
    echo -e "  make psql DATABASE=$TARGET"
fi
