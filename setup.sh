#!/usr/bin/env bash
# =============================================================================
# setup.sh — Initialize Nautobot Docker Compose environment
#
# 1. Validates prerequisites (Docker, Compose V2, curl, openssl).
# 2. Generates a .env file with random secrets and sensible defaults.
# 3. Sets the Nautobot version in the Dockerfile (validated against Docker Hub).
# 4. Creates named Docker volumes.
# 5. Creates required subdirectories inside the media volume.
# 6. Sets volume ownership to the nautobot user (UID 999, GID 999).
#
# Uses a temporary Alpine container for all volume filesystem operations,
# so this works identically on Linux and macOS without sudo.
#
# Usage:
#   ./setup.sh                        Latest Nautobot 3.0 on Python 3.12
#   ./setup.sh -v 2.4                 Nautobot 2.4 on Python 3.12
#   ./setup.sh -v 3.0 -p 3.11        Nautobot 3.0 on Python 3.11
#   ./setup.sh --debug                Enable bash trace (set -x)
# =============================================================================

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NAUTOBOT_VERSION="3.0"
PYTHON_VERSION="3.12"
DEBUG_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            NAUTOBOT_VERSION="$2"
            shift 2
            ;;
        -p|--python)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: ./setup.sh [-v VERSION] [-p PYTHON] [--debug]"
            echo ""
            echo "Options:"
            echo "  -v, --version VERSION   Nautobot version (default: 3.0)"
            echo "  -p, --python  PYTHON    Python version suffix (default: 3.12)"
            echo "      --debug             Enable bash trace for troubleshooting"
            echo "  -h, --help              Show this help message"
            echo ""
            echo "Examples:"
            echo "  ./setup.sh                     # 3.0-py3.12 (default)"
            echo "  ./setup.sh -v 2.4              # 2.4-py3.12"
            echo "  ./setup.sh -v 3.0 -p 3.11      # 3.0-py3.11"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './setup.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

NAUTOBOT_IMAGE_TAG="${NAUTOBOT_VERSION}-py${PYTHON_VERSION}"

if [[ "$DEBUG_MODE" == true ]]; then
    set -x
    echo "DEBUG: Trace mode enabled."
fi

set -euo pipefail

# Trap errors and report the failing line number.
trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

echo "[1/6] Loading configuration..."

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
echo "  Image tag:     networktocode/nautobot:${NAUTOBOT_IMAGE_TAG}"

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
echo "[2/6] Preflight checks..."

# --- Docker CLI ---
if ! command -v docker &>/dev/null; then
    echo "  FAIL: docker is not installed or not in PATH." >&2
    echo "" >&2
    echo "  Install Docker from https://docs.docker.com/get-docker/" >&2
    echo "    macOS/Windows: Install Docker Desktop." >&2
    echo "    Linux:         Follow the Docker Engine install guide for your distro." >&2
    exit 1
fi
echo "  docker:   $(docker --version)"

# --- Verify this is Docker from docker.com (not a snap or distro repackage) ---
# Snap Docker and distro packages often lag behind, lack Compose V2, and can
# behave differently with volumes and permissions.
DOCKER_SERVER_VERSION="$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null || true)"
if [[ -n "$DOCKER_SERVER_VERSION" ]]; then
    echo "  engine:   $DOCKER_SERVER_VERSION"
else
    # Older Docker versions don't expose Platform.Name — fall back to a
    # best-effort snap check on Linux.
    if command -v snap &>/dev/null && snap list docker &>/dev/null 2>&1; then
        echo "  WARNING: Docker appears to be installed via snap." >&2
        echo "           The snap package is not officially supported and may cause" >&2
        echo "           issues with volume permissions and Compose V2." >&2
        echo "           Recommended: remove the snap and install Docker Engine from" >&2
        echo "           https://docs.docker.com/engine/install/" >&2
    fi
fi

# --- Docker daemon connectivity ---
if ! docker info &>/dev/null; then
    echo "  FAIL: Cannot connect to the Docker daemon." >&2
    echo "" >&2
    case "$(uname -s)" in
        Linux)
            echo "  Possible fixes:" >&2
            echo "    1. Start the daemon:    sudo systemctl start docker" >&2
            echo "    2. Add yourself to the docker group (avoids sudo):" >&2
            echo "         sudo usermod -aG docker \$USER" >&2
            echo "         newgrp docker   # apply immediately, or log out and back in" >&2
            ;;
        Darwin)
            echo "  Possible fixes:" >&2
            echo "    1. Open Docker Desktop from /Applications and wait for it to start." >&2
            echo "    2. Or start it from the CLI:  open -a Docker" >&2
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "  Possible fixes:" >&2
            echo "    1. Start Docker Desktop from the Start menu." >&2
            echo "    2. In Docker Desktop settings, enable WSL integration for your distro." >&2
            ;;
        *)
            echo "  Ensure the Docker daemon is running and your user has access." >&2
            ;;
    esac
    exit 1
fi
echo "  daemon:   running"

# --- Docker Compose V2 ---
# This project uses `docker compose` (V2 plugin), not the deprecated
# standalone `docker-compose` (V1 Python package).
if ! docker compose version &>/dev/null; then
    echo "  FAIL: 'docker compose' (Compose V2) is not available." >&2
    echo "" >&2
    echo "  Docker Compose V2 is included with Docker Desktop and can be added" >&2
    echo "  to Docker Engine via the docker-compose-plugin package." >&2
    echo "  See: https://docs.docker.com/compose/install/" >&2
    exit 1
fi
echo "  compose:  $(docker compose version --short)"

# --- curl ---
if ! command -v curl &>/dev/null; then
    echo "  FAIL: curl is required but not found in PATH." >&2
    exit 1
fi
echo "  curl:     $(curl --version | head -1)"

# --- openssl ---
if ! command -v openssl &>/dev/null; then
    echo "  FAIL: openssl is required but not found in PATH." >&2
    exit 1
fi
echo "  openssl:  $(openssl version)"

# --- Validate the Nautobot image tag exists on Docker Hub ---
DOCKER_HUB_URL="https://hub.docker.com/v2/repositories/networktocode/nautobot/tags/${NAUTOBOT_IMAGE_TAG}"
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" "$DOCKER_HUB_URL")"
if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "  FAIL: Image tag 'networktocode/nautobot:${NAUTOBOT_IMAGE_TAG}' not found on Docker Hub." >&2
    echo "" >&2
    echo "  Check available tags at:" >&2
    echo "    https://hub.docker.com/r/networktocode/nautobot/tags" >&2
    exit 1
fi
echo "  image:    networktocode/nautobot:${NAUTOBOT_IMAGE_TAG} (verified on Docker Hub)"

# ---------------------------------------------------------------------------
# Generate .env file
# ---------------------------------------------------------------------------

echo ""
echo "[3/6] Environment file..."

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
# Set Nautobot version in Dockerfile
# ---------------------------------------------------------------------------

echo ""
echo "[4/6] Setting Nautobot version in Dockerfile..."

DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
CURRENT_TAG="$(sed -n 's/^ARG NAUTOBOT_VERSION=//p' "$DOCKERFILE")"

if [[ "$CURRENT_TAG" == "$NAUTOBOT_IMAGE_TAG" ]]; then
    echo "  Dockerfile already set to ${NAUTOBOT_IMAGE_TAG} — no change."
else
    sed -i.bak "s/^ARG NAUTOBOT_VERSION=.*/ARG NAUTOBOT_VERSION=${NAUTOBOT_IMAGE_TAG}/" "$DOCKERFILE"
    rm -f "${DOCKERFILE}.bak"
    echo "  Updated: ${CURRENT_TAG} → ${NAUTOBOT_IMAGE_TAG}"
fi

# ---------------------------------------------------------------------------
# Create volumes
# ---------------------------------------------------------------------------

echo ""
echo "[5/6] Creating Docker volumes..."

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
echo "[6/6] Initializing Nautobot volumes (mkdir + chown ${NAUTOBOT_UID}:${NAUTOBOT_GID})..."

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
