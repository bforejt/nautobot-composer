#!/usr/bin/env bash
# =============================================================================
# setup.sh — Initialize Nautobot Docker Compose environment
#
# 1. Generates a .env file with random secrets and sensible defaults.
# 2. Creates named Docker volumes.
# 3. Creates required subdirectories inside the media volume.
# 4. Sets volume ownership to the nautobot user (UID 999, GID 999).
#
# Uses a temporary Alpine container for all volume filesystem operations,
# so this works identically on Linux and macOS without sudo.
#
# Usage:
#   ./setup.sh            Normal run
#   ./setup.sh --debug    Enable bash trace (set -x) for troubleshooting
# =============================================================================

# Enable trace mode if --debug is passed.
if [[ "${1:-}" == "--debug" ]]; then
    set -x
    echo "DEBUG: Trace mode enabled."
fi

set -euo pipefail

# Trap errors and report the failing line number.
trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

echo "[1/5] Loading configuration..."

NAUTOBOT_UID=999
NAUTOBOT_GID=999

# Compose project name — derived from directory name, same as Docker Compose.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"

ENV_FILE="${SCRIPT_DIR}/.env"

# Volume names — must match the keys in docker-compose.yml volumes section.
# These are external volumes (external: true), so Compose uses the names as-is
# with no project prefix.
MEDIA_VOLUME="nautobot_media"
GIT_VOLUME="nautobot_git"
JOBS_VOLUME="nautobot_jobs"
POSTGRES_VOLUME="nautobot_postgres_data"
REDIS_VOLUME="nautobot_redis_data"

ALL_VOLUMES=(
    "$MEDIA_VOLUME"
    "$GIT_VOLUME"
    "$JOBS_VOLUME"
    "$POSTGRES_VOLUME"
    "$REDIS_VOLUME"
)

# Subdirectories Nautobot expects inside the media volume.
MEDIA_SUBDIRS=(
    "devicetype-images"
    "image-attachments"
    "health_check_storage_test"
)

echo "  Project name:  $PROJECT_NAME"
echo "  Script dir:    $SCRIPT_DIR"
echo "  .env file:     $ENV_FILE"

# ---------------------------------------------------------------------------
# Helper: generate random strings
#
# NOTE: tr ... | head pipelines trigger SIGPIPE when head closes early.
# With pipefail enabled, this returns non-zero and kills the script.
# Wrapping in a subshell with || true on the tr side avoids this.
# ---------------------------------------------------------------------------

generate_alphanum() {
    local len="${1:-8}"
    # Read extra bytes to ensure we get enough alphanumeric chars after filtering.
    local result
    result="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$len")" || true
    if [[ ${#result} -lt $len ]]; then
        echo "ERROR: Failed to generate ${len}-char alphanumeric string." >&2
        exit 1
    fi
    echo "$result"
}

generate_secret_key() {
    openssl rand -base64 48 2>/dev/null
}

generate_api_token() {
    openssl rand -hex 20 2>/dev/null
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo ""
echo "[2/5] Preflight checks..."

if ! command -v docker &>/dev/null; then
    echo "  FAIL: docker is not installed or not in PATH." >&2
    exit 1
fi
echo "  docker:   $(docker --version)"

if ! docker info &>/dev/null; then
    echo "  FAIL: Docker daemon is not running or current user cannot access it." >&2
    exit 1
fi
echo "  daemon:   running"

if ! command -v openssl &>/dev/null; then
    echo "  FAIL: openssl is required but not found in PATH." >&2
    exit 1
fi
echo "  openssl:  $(openssl version)"

# ---------------------------------------------------------------------------
# Generate .env file
# ---------------------------------------------------------------------------

echo ""
echo "[3/5] Environment file..."

if [[ -f "$ENV_FILE" ]]; then
    echo "  .env already exists — skipping generation."
    echo "  To regenerate:  rm .env && ./setup.sh"
else
    echo "  Generating secrets..."

    SECRET_KEY="$(generate_secret_key)"
    echo "    SECRET_KEY:         generated (${#SECRET_KEY} chars)"

    DB_PASSWORD="$(generate_alphanum 8)"
    echo "    DB_PASSWORD:        generated (${#DB_PASSWORD} chars)"

    SUPERUSER_PASSWORD="$(generate_alphanum 8)"
    echo "    SUPERUSER_PASSWORD: generated (${#SUPERUSER_PASSWORD} chars)"

    API_TOKEN="$(generate_api_token)"
    echo "    API_TOKEN:          generated (${#API_TOKEN} chars)"

    echo "  Writing $ENV_FILE ..."

    cat > "$ENV_FILE" <<EOF
# =============================================================================
# Nautobot Docker Compose — Environment Variables
# Generated by setup.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#
# See env.example for documentation on each variable.
# =============================================================================

# ---------------------------------------------------------------------------
# Nautobot Core
# ---------------------------------------------------------------------------
NAUTOBOT_SECRET_KEY=${SECRET_KEY}
NAUTOBOT_ALLOWED_HOSTS=*
NAUTOBOT_DEBUG=False
NAUTOBOT_LOG_LEVEL=INFO
NAUTOBOT_METRICS_ENABLED=True
NAUTOBOT_MAX_PAGE_SIZE=0
NAUTOBOT_HIDE_RESTRICTED_UI=True
NAUTOBOT_INSTALLATION_METRICS_ENABLED=False

# ---------------------------------------------------------------------------
# PostgreSQL Database
# ---------------------------------------------------------------------------
POSTGRES_DB=nautobot
POSTGRES_USER=nautobot
POSTGRES_PASSWORD=${DB_PASSWORD}

NAUTOBOT_DB_NAME=nautobot
NAUTOBOT_DB_USER=nautobot
NAUTOBOT_DB_PASSWORD=${DB_PASSWORD}
NAUTOBOT_DB_HOST=db
NAUTOBOT_DB_PORT=5432
NAUTOBOT_DB_ENGINE=django.db.backends.postgresql

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------
NAUTOBOT_REDIS_HOST=redis
NAUTOBOT_REDIS_PORT=6379
NAUTOBOT_REDIS_PASSWORD=
NAUTOBOT_REDIS_SSL=False

# ---------------------------------------------------------------------------
# Superuser — Created on First Start
# ---------------------------------------------------------------------------
NAUTOBOT_CREATE_SUPERUSER=true
NAUTOBOT_SUPERUSER_NAME=admin
NAUTOBOT_SUPERUSER_EMAIL=admin@example.com
NAUTOBOT_SUPERUSER_PASSWORD=${SUPERUSER_PASSWORD}
NAUTOBOT_SUPERUSER_API_TOKEN=${API_TOKEN}

# ---------------------------------------------------------------------------
# NAPALM (optional)
# ---------------------------------------------------------------------------
NAPALM_USERNAME=
NAPALM_PASSWORD=
NAPALM_TIMEOUT=30
EOF

    chmod 600 "$ENV_FILE"

    echo "  Created: $ENV_FILE  (mode 600)"
    echo ""
    echo "  ========================================="
    echo "  Nautobot admin credentials"
    echo "  ========================================="
    echo "  Username:   admin"
    echo "  Password:   ${SUPERUSER_PASSWORD}"
    echo "  API token:  ${API_TOKEN}"
    echo "  ========================================="
    echo ""
    echo "  Save these now — they are not stored elsewhere."
fi

# ---------------------------------------------------------------------------
# Create volumes
# ---------------------------------------------------------------------------

echo ""
echo "[4/5] Creating Docker volumes..."

for vol in "${ALL_VOLUMES[@]}"; do
    if docker volume inspect "$vol" &>/dev/null; then
        echo "  $vol — already exists"
    else
        docker volume create "$vol" >/dev/null
        echo "  $vol — created"
    fi
done

# ---------------------------------------------------------------------------
# Create subdirectories and set ownership via temporary container
# ---------------------------------------------------------------------------

echo ""
echo "[5/5] Initializing Nautobot volumes (mkdir + chown ${NAUTOBOT_UID}:${NAUTOBOT_GID})..."

MKDIR_ARGS=""
for subdir in "${MEDIA_SUBDIRS[@]}"; do
    MKDIR_ARGS="${MKDIR_ARGS} /media/${subdir}"
done

docker run --rm \
    -v "${MEDIA_VOLUME}:/media" \
    -v "${GIT_VOLUME}:/git" \
    -v "${JOBS_VOLUME}:/jobs" \
    alpine sh -c "
        mkdir -p ${MKDIR_ARGS}
        chown -R ${NAUTOBOT_UID}:${NAUTOBOT_GID} /media /git /jobs
    "

echo "  Done."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Volume status:"
echo ""

docker run --rm \
    -v "${MEDIA_VOLUME}:/media" \
    -v "${GIT_VOLUME}:/git" \
    -v "${JOBS_VOLUME}:/jobs" \
    alpine sh -c "
        echo '  ${MEDIA_VOLUME}  owner='\$(stat -c '%u:%g' /media);
        for d in /media/*/; do
            echo '    '\$(basename \$d)'/  owner='\$(stat -c '%u:%g' \$d);
        done;
        echo '  ${GIT_VOLUME}  owner='\$(stat -c '%u:%g' /git);
        echo '  ${JOBS_VOLUME}  owner='\$(stat -c '%u:%g' /jobs);
    "

echo ""
echo "Setup complete. Next steps:"
echo "  1. Review .env and adjust NAUTOBOT_ALLOWED_HOSTS for production."
echo "  2. Build the Nautobot image:   docker compose build"
echo "  3. Start the stack:            docker compose up -d"
echo ""
