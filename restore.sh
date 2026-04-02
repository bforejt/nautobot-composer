#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore Nautobot database and/or media files from backup
#
# By default, finds the most recent backup files in ./backups/.
# Use --db-file / --media-file to specify exact files.
#
# Usage:
#   ./restore.sh                               Restore latest db + media
#   ./restore.sh -t db                         Restore latest database only
#   ./restore.sh --db-file backups/my.sql.gz   Restore a specific DB backup
#   ./restore.sh -d /mnt/backups               Search a custom directory
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: restore failed at line $LINENO (exit $?)." >&2' ERR

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
    if ! docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps db --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
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
# Confirmation
# ---------------------------------------------------------------------------
echo "Nautobot Restore"
echo ""
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Database: ${DB_FILE}"
fi
if [[ "$RESTORE_TYPE" == "media" || "$RESTORE_TYPE" == "all" ]]; then
    echo "  Media:    ${MEDIA_FILE}"
fi
echo ""
echo "WARNING: This will overwrite current data. This cannot be undone."
printf "Continue? [y/N] "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Database restore
# ---------------------------------------------------------------------------
if [[ "$RESTORE_TYPE" == "db" || "$RESTORE_TYPE" == "all" ]]; then
    echo "Restoring database from ${DB_FILE}..."
    # Handle both gzipped (.sql.gz) and plain (.sql) backups.
    if [[ "$DB_FILE" == *.gz ]]; then
        gunzip -c "$DB_FILE"
    else
        cat "$DB_FILE"
    fi | docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T db \
            psql -U nautobot -d nautobot --quiet --single-transaction
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

echo ""
echo "Restore complete."
