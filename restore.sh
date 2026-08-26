#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore Nautobot database and/or media files from backup
#
# By default, finds the most recent backup files in ./backups/.
# Use --db-file / --media-file to specify exact files.
#
# A database restore stops the RUNNING Nautobot app containers (nautobot,
# celery worker/beat) for the drop/load, then restarts exactly the ones it
# stopped.  Containers that were already down stay down.
#
# Usage:
#   ./restore.sh                               Restore latest db + media
#   ./restore.sh -t db                         Restore latest database only
#   ./restore.sh --db-file backups/my.sql.gz   Restore a specific DB backup
#   ./restore.sh -d /mnt/backups               Search a custom directory
# =============================================================================
set -euo pipefail

# The ERR trap does not fire when the script dies on Ctrl-C, and an interrupt
# during the long SQL load is exactly when the app is down — so INT/TERM get
# their own trap and both share this hint.
restart_hint() {
    if [[ "${APP_STOPPED:-false}" == true ]]; then
        echo "NOTE: the Nautobot app containers were stopped for this restore — restart with:" >&2
        echo "  docker compose --project-directory \"${SCRIPT_DIR}\" up -d" >&2
    fi
}
trap 'echo "ERROR: restore failed at line $LINENO (exit $?)." >&2; restart_hint' ERR
trap 'echo "Interrupted." >&2; restart_hint; exit 130' INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
RESTORE_TYPE="all"
BACKUP_DIR="${SCRIPT_DIR}/backups"
DB_FILE=""
MEDIA_FILE=""
MEDIA_VOLUME="nautobot_media"
NAUTOBOT_UID=999
NAUTOBOT_GID=999
APP_STOPPED=false
RUNNING_APP=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            RESTORE_TYPE="$2"
            shift 2
            ;;
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --db-file)
            DB_FILE="$2"
            shift 2
            ;;
        --media-file)
            MEDIA_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ./restore.sh [-t TYPE] [-d DIR] [--db-file FILE] [--media-file FILE]"
            echo ""
            echo "Options:"
            echo "  -t, --type TYPE        What to restore: db, media, all (default: all)"
            echo "  -d, --dir  DIR         Directory to search for backups (default: ./backups)"
            echo "      --db-file FILE     Specific database backup file"
            echo "      --media-file FILE  Specific media backup file"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Supported formats:"
            echo "  Database: .sql.gz (gzipped) or .sql (plain)"
            echo "  Media:    .tar.gz or .tgz"
            echo ""
            echo "A database restore stops the running Nautobot app containers for"
            echo "the drop/load and restarts the ones it stopped when finished."
            echo ""
            echo "When no file is specified, the most recent matching backup in"
            echo "the backup directory is used automatically."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './restore.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$RESTORE_TYPE" in
    db|media|all) ;;
    *)
        echo "ERROR: Invalid type '${RESTORE_TYPE}'. Must be db, media, or all." >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! docker info &>/dev/null; then
    echo "ERROR: Cannot connect to the Docker daemon." >&2
    exit 1
fi

if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    if ! docker inspect --format '{{.State.Running}}' nautobot-db 2>/dev/null | grep -q true; then
        echo "ERROR: The db container is not running. Start the stack first:" >&2
        echo "  docker compose up -d" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Resolve backup files
# ---------------------------------------------------------------------------
# find_latest <dir> <pattern1> [<pattern2> ...]
# Returns the most recently modified file matching any of the given globs.
find_latest() {
    local dir="$1"; shift
    local pattern result
    # Collect all matches, then take the newest by modification time.
    # The || true prevents SIGPIPE (exit 141) when head closes the pipe
    # early, which would kill the script under set -o pipefail.
    # shellcheck disable=SC2012
    result="$(for pattern in "$@"; do
        ls -t "${dir}"/${pattern} 2>/dev/null || true
    done | head -1)" || true
    echo "$result"
}

if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    if [[ -z "$DB_FILE" ]]; then
        DB_FILE="$(find_latest "$BACKUP_DIR" \
            "nautobot_db_*.sql.gz" "nautobot_db_*.sql" \
            "nautobot-db-*.sql.gz" "nautobot-db-*.sql")"
        if [[ -z "$DB_FILE" ]]; then
            echo "ERROR: No database backup found in ${BACKUP_DIR}." >&2
            echo "  Use --db-file to specify a file, or run ./backup.sh first." >&2
            exit 1
        fi
    fi
    if [[ ! -f "$DB_FILE" ]]; then
        echo "ERROR: Database backup not found: ${DB_FILE}" >&2
        exit 1
    fi
fi

if [[ "$RESTORE_TYPE" == "media" || "$RESTORE_TYPE" == "all" ]]; then
    if [[ -z "$MEDIA_FILE" ]]; then
        MEDIA_FILE="$(find_latest "$BACKUP_DIR" \
            "nautobot_media_*.tar.gz" "nautobot_media_*.tgz" \
            "nautobot-media-*.tar.gz" "nautobot-media-*.tgz")"
        if [[ -z "$MEDIA_FILE" ]]; then
            echo "ERROR: No media backup found in ${BACKUP_DIR}." >&2
            echo "  Use --media-file to specify a file, or run ./backup.sh first." >&2
            exit 1
        fi
    fi
    if [[ ! -f "$MEDIA_FILE" ]]; then
        echo "ERROR: Media backup not found: ${MEDIA_FILE}" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Read NAUTOBOT_ENV from .env (default: lab) for the environment-tier guard
# ---------------------------------------------------------------------------
# Lighter guard than reset.sh / load-test-data.sh: no --allow-production-destroy
# override flag, since the operator already specified the backup file.  But on
# non-lab tiers we replace the y/N prompt with a typed-env-name prompt so
# muscle-memory "y" doesn't trigger.

ENV_FILE_PATH="${SCRIPT_DIR}/.env"
NAUTOBOT_ENV_VALUE="$(grep -E '^NAUTOBOT_ENV=' "$ENV_FILE_PATH" 2>/dev/null \
    | tail -1 \
    | cut -d= -f2- \
    | tr -d '"' \
    || true)"
NAUTOBOT_ENV_VALUE="${NAUTOBOT_ENV_VALUE:-MISSING}"

case "$NAUTOBOT_ENV_VALUE" in
    lab)
        USE_ENV_NAME_PROMPT=false
        ;;
    staging|production)
        USE_ENV_NAME_PROMPT=true
        ;;
    MISSING|"")
        echo "WARNING: NAUTOBOT_ENV not set in .env — treating as 'lab'." >&2
        echo "  Set NAUTOBOT_ENV=lab|staging|production explicitly to silence." >&2
        USE_ENV_NAME_PROMPT=false
        ;;
    *)
        echo "ERROR: NAUTOBOT_ENV='$NAUTOBOT_ENV_VALUE' is not one of lab|staging|production." >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo "Nautobot Restore"
echo ""
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Database:    ${DB_FILE}"
fi
if [[ "$RESTORE_TYPE" == "media" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Media:       ${MEDIA_FILE}"
fi
echo "  Environment: ${NAUTOBOT_ENV_VALUE}"
echo ""
echo "WARNING: This will overwrite current data. This cannot be undone."
echo ""

if [[ "$USE_ENV_NAME_PROMPT" == true ]]; then
    printf 'Type %q to confirm restore on the %s tier: ' "$NAUTOBOT_ENV_VALUE" "$NAUTOBOT_ENV_VALUE"
    read -r CONFIRM
    if [[ "$CONFIRM" != "$NAUTOBOT_ENV_VALUE" ]]; then
        echo "Aborted."
        exit 0
    fi
else
    printf "Continue? [y/N] "
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Database restore
# ---------------------------------------------------------------------------
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    echo "Restoring database from ${DB_FILE}..."

    # Postgres refuses to DROP a database that has live sessions, and the
    # stack holds one even at idle (celery beat's scheduler polls the DB).
    # Quiesce the app containers, then clear any straggler sessions, or the
    # drop below fails with "database is being accessed by other users".
    # Only the containers that are RUNNING are recorded and stopped, so the
    # restart below never boots a container the operator had deliberately
    # down (and a stack with no app containers — e.g. mid Postgres upgrade,
    # after `docker compose down` — skips the stop/start entirely).
    for pair in "nautobot:nautobot" "celery_worker:nautobot-celery-worker" \
                "celery_beat:nautobot-celery-beat"; do
        if docker inspect --format '{{.State.Running}}' "${pair#*:}" 2>/dev/null | grep -q true; then
            RUNNING_APP="${RUNNING_APP}${pair%%:*} "
        fi
    done
    if [[ -n "$RUNNING_APP" ]]; then
        echo "  Stopping Nautobot app containers (restarted after the restore): ${RUNNING_APP}"
        APP_STOPPED=true
        # shellcheck disable=SC2086  # intentional word-splitting of service names
        docker compose --project-directory "$SCRIPT_DIR" stop ${RUNNING_APP}
    fi
    docker exec nautobot-db psql -U nautobot -d postgres -Atc \
        "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
         WHERE datname='nautobot' AND pid <> pg_backend_pid();" >/dev/null

    # Drop and recreate the database to avoid conflicts (duplicate primary
    # keys, existing tables, etc.) when restoring into a non-empty database.
    echo "  Dropping and recreating nautobot database..."
    docker exec nautobot-db \
        psql -U nautobot -d postgres -c "DROP DATABASE IF EXISTS nautobot;"
    docker exec nautobot-db \
        psql -U nautobot -d postgres -c "CREATE DATABASE nautobot OWNER nautobot;"

    # Handle both gzipped (.sql.gz) and plain (.sql) backups.
    echo "  Loading SQL dump..."
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "$DB_FILE"
    else
        cat "$DB_FILE"
    fi | docker exec -i nautobot-db psql -U nautobot
    echo "  Database restored."
fi

# ---------------------------------------------------------------------------
# Media restore
# ---------------------------------------------------------------------------
if [[ "$RESTORE_TYPE" == "media" || "$RESTORE_TYPE" == "all" ]]; then
    echo "Restoring media files from ${MEDIA_FILE}..."
    # Resolve to absolute path for the Docker bind-mount.
    MEDIA_FILE_ABS="$(cd "$(dirname "$MEDIA_FILE")" && pwd)/$(basename "$MEDIA_FILE")"
    MEDIA_FILE_NAME="$(basename "$MEDIA_FILE")"
    docker run --rm \
        -v "${MEDIA_VOLUME}:/data" \
        -v "$(dirname "$MEDIA_FILE_ABS"):/backup:ro" \
        alpine sh -c "
            rm -rf /data/*
            tar xzf /backup/${MEDIA_FILE_NAME} -C /data
            chown -R ${NAUTOBOT_UID}:${NAUTOBOT_GID} /data
        "
    echo "  Media files restored."
fi

# ---------------------------------------------------------------------------
# Restart what we stopped
# ---------------------------------------------------------------------------
if [[ "$APP_STOPPED" == true ]]; then
    echo "Restarting Nautobot app containers: ${RUNNING_APP}"
    # `start`, NOT `up -d`: up may recreate containers or even the project
    # network on unrelated config drift (e.g. a pending NAUTOBOT_NETWORK_SUBNET
    # change) — mid-restore is no place for that.  A start failure must not
    # report the completed restore as failed, so it downgrades to a warning.
    # shellcheck disable=SC2086  # intentional word-splitting of service names
    if ! docker compose --project-directory "$SCRIPT_DIR" start ${RUNNING_APP}; then
        echo "WARNING: could not restart: ${RUNNING_APP}" >&2
        echo "  Start manually:  docker compose --project-directory \"${SCRIPT_DIR}\" up -d" >&2
    fi
fi

echo ""
echo "Restore complete."
