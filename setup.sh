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
#   ./setup.sh                        Latest Nautobot 3.1 on Python 3.12
#   ./setup.sh -v 3.0                 Nautobot 3.0 on Python 3.12
#   ./setup.sh -v 2.4                 Nautobot 2.4 on Python 3.12
#   ./setup.sh -v 3.1 -p 3.11        Nautobot 3.1 on Python 3.11
#   ./setup.sh --debug                Enable bash trace (set -x)
# =============================================================================

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NAUTOBOT_VERSION="3.1"
PYTHON_VERSION="3.12"
DEBUG_MODE=false
DO_BUILD=false
DO_START=false
DO_WAIT=false

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
        --build)
            DO_BUILD=true
            shift
            ;;
        --start)
            DO_START=true
            shift
            ;;
        --wait)
            DO_WAIT=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            cat <<'HELP'
Usage: ./setup.sh [-v VERSION] [-p PYTHON] [--build] [--start] [--wait] [--debug]

Options:
  -v, --version VERSION   Nautobot version (default: 3.1)
  -p, --python  PYTHON    Python version suffix (default: 3.12)
      --build             After setup, run 'docker compose build'
      --start             After setup (and --build if given), run
                          'docker compose up -d'
      --wait              After --start, poll the nautobot container's
                          health and block until it reports 'healthy'
                          (15 minute timeout — first-boot migrations
                          can be slow)
      --debug             Enable bash trace for troubleshooting
  -h, --help              Show this help message

Examples:
  # Default: just initialize secrets, volumes, and version selection.
  ./setup.sh

  # First-time install in one shot — set up, build, start, wait until healthy.
  ./setup.sh --build --start --wait

  # Switch to a different Nautobot version on an existing install.
  ./setup.sh -v 3.0 --build --start --wait

  # Older Nautobot 2.x line.
  ./setup.sh -v 2.4 --build --start --wait

  # Pin a different Python version.
  ./setup.sh -v 3.1 -p 3.11
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run './setup.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

# --wait without --start is meaningless; treat it as an alias for the pair.
if [[ "$DO_WAIT" == true && "$DO_START" != true ]]; then
    DO_START=true
fi

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
POSTGRES_VOLUME="nautobot_postgres_data"
REDIS_VOLUME="nautobot_redis_data"
GITLAB_CONFIG_VOLUME="gitlab_config"
GITLAB_LOGS_VOLUME="gitlab_logs"
GITLAB_DATA_VOLUME="gitlab_data"

ALL_VOLUMES=(
    "$MEDIA_VOLUME"
    "$GIT_VOLUME"
    "$POSTGRES_VOLUME"
    "$REDIS_VOLUME"
    "$GITLAB_CONFIG_VOLUME"
    "$GITLAB_LOGS_VOLUME"
    "$GITLAB_DATA_VOLUME"
)

# Jobs are bind-mounted from ./jobs instead of a named volume, so
# setup.sh just ensures the directory exists with correct ownership.
JOBS_HOST_DIR="${SCRIPT_DIR}/jobs"

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

    # 24 alphanumeric chars ≈ 143 bits of entropy.  Alphanumeric avoids
    # quoting/escaping hazards in connection strings and shell one-liners.
    DB_PASSWORD="$(generate_alphanum 24)"
    echo "    DB_PASSWORD:        generated (${#DB_PASSWORD} chars)"

    SUPERUSER_PASSWORD="$(generate_alphanum 24)"
    echo "    SUPERUSER_PASSWORD: generated (${#SUPERUSER_PASSWORD} chars)"

    API_TOKEN="$(generate_api_token)"
    echo "    API_TOKEN:          generated (${#API_TOKEN} chars)"

    # Admin password for the optional firmware server's Filebrowser UI
    # (the "firmware" Compose profile).  Generated up front so the add-on works
    # without hand-editing; unused unless that compose file is included.
    FIRMWARE_ADMIN_PASSWORD="$(generate_alphanum 24)"
    echo "    FIRMWARE_ADMIN_PW:  generated (${#FIRMWARE_ADMIN_PASSWORD} chars)"

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
# Deployment tier — gates destructive operations (reset.sh, load-test-data.sh,
# restore.sh).  Allowed values: lab, staging, production.
#   lab        — default; destructive operations proceed with normal confirms
#   staging    — destructive operations refuse without --allow-production-destroy
#   production — same as staging; the env-name typed prompt replaces the
#                generic confirmation
# Set this to 'production' once you've pivoted this deployment beyond lab use.
NAUTOBOT_ENV=lab

# Image tag for the upstream Nautobot base image.  Read at build time as
# a docker compose build-arg.  Set or changed via 'setup.sh -v <version>'.
NAUTOBOT_VERSION=${NAUTOBOT_IMAGE_TAG}

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
REDIS_MAXMEMORY=512mb

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

# ---------------------------------------------------------------------------
# Firmware Server (optional add-on — Compose profile: firmware)
# See env.example for documentation on each variable.
# ---------------------------------------------------------------------------
FIRMWARE_BIND_ADDRESS=0.0.0.0
FIRMWARE_FILEBROWSER_PORT=8088
FIRMWARE_HTTPS_PORT=9443
FIRMWARE_HTTP_PORT=9080
FIRMWARE_SERVER_NAME=localhost
FIRMWARE_ALLOWED_CIDRS=0.0.0.0/0
FIRMWARE_ADMIN_USER=admin
FIRMWARE_ADMIN_PASSWORD=${FIRMWARE_ADMIN_PASSWORD}
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
    echo ""
    echo "  Firmware server UI admin (only if you enable the firmware add-on):"
    echo "  Username:   ${FIRMWARE_ADMIN_USER:-admin}"
    echo "  Password:   ${FIRMWARE_ADMIN_PASSWORD}"
    echo "  ========================================="
    echo ""
    echo "  Save these now — they are not stored elsewhere."
fi

# ---------------------------------------------------------------------------
# Configure Nautobot version (image tag in .env, requirements.txt symlink)
# ---------------------------------------------------------------------------

echo ""
echo "[4/6] Configuring Nautobot version..."

# Persist the resolved image tag in .env so docker-compose.yml's build-args
# picks it up at build time.  This replaces the older approach of rewriting
# the Dockerfile in place — that mutated a tracked file on every version
# switch and showed up as uncommitted changes in `git status`.
if [[ -f "$ENV_FILE" ]] && grep -qE '^NAUTOBOT_VERSION=' "$ENV_FILE"; then
    # Update existing line.
    sed -i.bak "s|^NAUTOBOT_VERSION=.*|NAUTOBOT_VERSION=${NAUTOBOT_IMAGE_TAG}|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    echo "  .env: NAUTOBOT_VERSION → ${NAUTOBOT_IMAGE_TAG}"
elif [[ -f "$ENV_FILE" ]]; then
    # Append to an existing .env that predates this scheme.
    printf '\nNAUTOBOT_VERSION=%s\n' "$NAUTOBOT_IMAGE_TAG" >> "$ENV_FILE"
    echo "  .env: NAUTOBOT_VERSION appended (${NAUTOBOT_IMAGE_TAG})"
fi

# Backward-compat: older .env files won't have NAUTOBOT_ENV.  Append it as
# 'lab' so destructive scripts have something to read.  Never overwrite a
# value the user has set — they may already have NAUTOBOT_ENV=production.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^NAUTOBOT_ENV=' "$ENV_FILE"; then
    printf '\nNAUTOBOT_ENV=lab\n' >> "$ENV_FILE"
    echo "  .env: NAUTOBOT_ENV appended (lab) — change to staging/production for non-lab use"
fi

# Backward-compat: older .env files predate the optional firmware server, and a
# hand-created .env ("cp env.example .env") ships the block but with the admin
# password commented out.  Handle both cases without duplicating the block or
# reverting values the user may have customised.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_BIND_ADDRESS=' "$ENV_FILE"; then
    # No firmware block present at all — append the whole thing.
    FW_ADMIN_PW="$(generate_alphanum 24)"
    cat >> "$ENV_FILE" <<EOF

# ---------------------------------------------------------------------------
# Firmware Server (optional add-on — Compose profile: firmware)
# See env.example for documentation on each variable.
# ---------------------------------------------------------------------------
FIRMWARE_BIND_ADDRESS=0.0.0.0
FIRMWARE_FILEBROWSER_PORT=8088
FIRMWARE_HTTPS_PORT=9443
FIRMWARE_HTTP_PORT=9080
FIRMWARE_SERVER_NAME=localhost
FIRMWARE_ALLOWED_CIDRS=0.0.0.0/0
FIRMWARE_ADMIN_USER=admin
FIRMWARE_ADMIN_PASSWORD=${FW_ADMIN_PW}
EOF
    echo "  .env: firmware-server block appended (admin password generated)"
    echo "        Firmware UI admin password: ${FW_ADMIN_PW}  (user: see FIRMWARE_ADMIN_USER)"
elif [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_ADMIN_PASSWORD=' "$ENV_FILE"; then
    # Firmware block exists but the admin password is still unset/commented —
    # add just the active password line.
    FW_ADMIN_PW="$(generate_alphanum 24)"
    printf '\nFIRMWARE_ADMIN_PASSWORD=%s\n' "$FW_ADMIN_PW" >> "$ENV_FILE"
    echo "  .env: FIRMWARE_ADMIN_PASSWORD generated and appended"
    echo "        Firmware UI admin password: ${FW_ADMIN_PW}  (user: see FIRMWARE_ADMIN_USER)"
fi

# Echo the active environment tier so the user sees what they're operating on.
CURRENT_ENV="$(grep -E '^NAUTOBOT_ENV=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
CURRENT_ENV="${CURRENT_ENV:-lab}"
echo "  .env: NAUTOBOT_ENV is '${CURRENT_ENV}'"
# If .env was just created above, NAUTOBOT_VERSION is already in it via
# the heredoc (see [3/6]).

# Select the version-specific requirements file based on the major version.
# requirements-2.x.txt and requirements-3.x.txt contain compatible App pins
# for their respective Nautobot major versions.
#
# Use a symlink rather than `cp` so that edits to the source file (e.g.
# adding a new App for testing) are picked up on the next build without
# re-running setup.sh.  Docker COPY follows symlinks within the build
# context and copies the resolved file content, so this works cleanly.
MAJOR_VERSION="${NAUTOBOT_VERSION%%.*}"
REQUIREMENTS_SRC="requirements-${MAJOR_VERSION}.x.txt"
REQUIREMENTS_DEST="${SCRIPT_DIR}/requirements.txt"

if [[ ! -f "${SCRIPT_DIR}/${REQUIREMENTS_SRC}" ]]; then
    echo "  WARNING: No requirements file found for Nautobot ${MAJOR_VERSION}.x" >&2
    echo "           Expected: ${SCRIPT_DIR}/${REQUIREMENTS_SRC}" >&2
    echo "           requirements.txt symlink was not (re)created." >&2
else
    # -s symbolic, -f overwrite if it exists, -n treat dest as plain file
    # (don't follow if it's already a symlink to a directory).  Relative
    # target so the symlink stays valid regardless of where the project
    # is cloned to.
    ln -sfn "$REQUIREMENTS_SRC" "$REQUIREMENTS_DEST"
    echo "  requirements.txt → ${REQUIREMENTS_SRC} (symlink)"
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
    alpine sh -c "
        mkdir -p ${MKDIR_ARGS}
        chown -R ${NAUTOBOT_UID}:${NAUTOBOT_GID} /media /git
    "

# Ensure the bind-mounted jobs/ directory exists and is owned by the
# nautobot user inside the container.  On macOS/Docker Desktop the
# chown is cosmetic (virtualized file sharing handles permissions);
# on Linux it is required so the container can read job files.
mkdir -p "${JOBS_HOST_DIR}"
docker run --rm \
    -v "${JOBS_HOST_DIR}:/jobs" \
    alpine chown -R "${NAUTOBOT_UID}:${NAUTOBOT_GID}" /jobs

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
    -v "${JOBS_HOST_DIR}:/jobs" \
    alpine sh -c "
        echo '  ${MEDIA_VOLUME}  owner='\$(stat -c '%u:%g' /media);
        for d in /media/*/; do
            echo '    '\$(basename \$d)'/  owner='\$(stat -c '%u:%g' \$d);
        done;
        echo '  ${GIT_VOLUME}  owner='\$(stat -c '%u:%g' /git);
        echo '  ./jobs (bind mount)  owner='\$(stat -c '%u:%g' /jobs);
    "

echo ""
echo "Setup complete."

# ---------------------------------------------------------------------------
# Optional build / start / wait phases
# ---------------------------------------------------------------------------

if [[ "$DO_BUILD" == true ]]; then
    echo ""
    echo "Building the Nautobot image (docker compose build)..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" build
fi

if [[ "$DO_START" == true ]]; then
    echo ""
    echo "Starting the stack (docker compose up -d)..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d
fi

if [[ "$DO_WAIT" == true ]]; then
    echo ""
    echo "Waiting for the nautobot container to report healthy..."
    echo "  (15-minute timeout — first-boot migrations can be slow)"

    # Poll Docker's healthcheck status.  This works whether the user
    # specified `container_name: nautobot` (current default) or relies
    # on Compose's auto-naming.  We resolve the container by service
    # name through Compose, then ask Docker for its current health.
    deadline=$(($(date +%s) + 900))
    last_status=""
    while true; do
        cid="$(docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps -q nautobot 2>/dev/null || true)"
        if [[ -z "$cid" ]]; then
            echo "  ERROR: nautobot container not found — did 'compose up -d' succeed?" >&2
            exit 1
        fi

        status="$(docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
        if [[ "$status" != "$last_status" ]]; then
            # Newline before the first status, then carriage return for updates.
            [[ -n "$last_status" ]] && echo
            printf '  status: %s' "$status"
            last_status="$status"
        else
            printf '.'
        fi

        case "$status" in
            healthy)
                echo
                echo "  nautobot is healthy."
                break
                ;;
            unhealthy)
                echo
                echo "  ERROR: nautobot reported unhealthy.  Recent logs:" >&2
                docker compose -f "${SCRIPT_DIR}/docker-compose.yml" logs --tail 50 nautobot >&2
                exit 1
                ;;
        esac

        if [[ $(date +%s) -ge $deadline ]]; then
            echo
            echo "  ERROR: timed out after 15 minutes.  Recent logs:" >&2
            docker compose -f "${SCRIPT_DIR}/docker-compose.yml" logs --tail 50 nautobot >&2
            exit 1
        fi
        sleep 5
    done
fi

# ---------------------------------------------------------------------------
# Final next-steps message
# ---------------------------------------------------------------------------

echo ""
if [[ "$DO_START" == true ]]; then
    echo "Stack is running.  Verify with:"
    echo "  docker compose ps"
    echo "  curl -fsSL http://localhost/health/"
else
    echo "Next steps:"
    echo "  1. Review .env and adjust NAUTOBOT_ALLOWED_HOSTS for production."
    echo "  2. Build:    docker compose build"
    echo "  3. Start:    docker compose up -d"
    echo "  Or rerun:    ./setup.sh --build --start --wait"
fi
echo ""
