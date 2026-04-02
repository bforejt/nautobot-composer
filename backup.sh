#!/usr/bin/env bash
# =============================================================================
# backup.sh — Back up Nautobot database and/or media files
#
# Creates timestamped backups in ./backups/ (or a custom directory).
#   Database: pg_dump piped through gzip  -> nautobot_db_<timestamp>.sql.gz
#   Media:    tar of the nautobot_media volume -> nautobot_media_<timestamp>.tar.gz
#
# Usage:
#   ./backup.sh                  Back up everything (db + media)
#   ./backup.sh -t db            Database only
#   ./backup.sh -t media         Media files only
#   ./backup.sh -d /mnt/backups  Custom output directory
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: backup failed at line $LINENO (exit $?)." >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%F_%H%M%S)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BACKUP_TYPE="all"
BACKUP_DIR="${SCRIPT_DIR}/backups"
MEDIA_VOLUME="nautobot_media"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            BACKUP_TYPE="$2"
            shift 2
            ;;
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ./backup.sh [-t TYPE] [-d DIR]"
            echo ""
            echo "Options:"
            echo "  -t, --type TYPE   What to back up: db, media, all (default: all)"
            echo "  -d, --dir  DIR    Output directory (default: ./backups)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './backup.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

case "$BACKUP_TYPE" in
    db|media|all) ;;
    *)
        echo "ERROR: Invalid type '${BACKUP_TYPE}'. Must be db, media, or all." >&2
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

if [[ "$BACKUP_TYPE" == "db" || "$BACKUP_TYPE" == "all" ]]; then
    if ! docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps db --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
        echo "ERROR: The db container is not running. Start the stack first:" >&2
        echo "  docker compose up -d" >&2
        exit 1
    fi
fi

mkdir -p "$BACKUP_DIR"

echo "Nautobot Backup"
echo "  Type:      ${BACKUP_TYPE}"
echo "  Directory: ${BACKUP_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Database backup
# ---------------------------------------------------------------------------
if [[ "$BACKUP_TYPE" == "db" || "$BACKUP_TYPE" == "all" ]]; then
    DB_FILE="${BACKUP_DIR}/nautobot_db_${TIMESTAMP}.sql.gz"
    echo "Backing up database..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T db \
        pg_dump -U nautobot nautobot | gzip > "$DB_FILE"
    DB_SIZE="$(du -h "$DB_FILE" | cut -f1)"
    echo "  Created: ${DB_FILE} (${DB_SIZE})"
fi

# ---------------------------------------------------------------------------
# Media backup
# ---------------------------------------------------------------------------
if [[ "$BACKUP_TYPE" == "media" || "$BACKUP_TYPE" == "all" ]]; then
    MEDIA_FILE="nautobot_media_${TIMESTAMP}.tar.gz"
    echo "Backing up media files..."
    docker run --rm \
        -v "${MEDIA_VOLUME}:/data:ro" \
        -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
        alpine tar czf "/backup/${MEDIA_FILE}" -C /data .
    MEDIA_SIZE="$(du -h "${BACKUP_DIR}/${MEDIA_FILE}" | cut -f1)"
    echo "  Created: ${BACKUP_DIR}/${MEDIA_FILE} (${MEDIA_SIZE})"
fi

echo ""
echo "Backup complete."
