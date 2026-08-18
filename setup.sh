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
# 7. Verifies bind-mounted files are readable by the container user, and
#    repairs permissions if they aren't.
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
# Profile switches: empty = leave the .env value untouched; on/off = add or
# remove that profile from COMPOSE_PROFILES in .env (see [4/7]).
PROFILE_GITLAB=""
PROFILE_FIRMWARE=""
PROFILE_ANSWER_SERVICE=""
PROFILE_TACACS=""
# Explicit device-facing firmware base URL (--firmware-url).  Empty = derive
# from the host's primary IP where needed (see FIRMWARE_BASE_URL handling).
FIRMWARE_URL=""

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
        --with-gitlab|--without-gitlab)
            new=$([[ "$1" == --without-* ]] && echo off || echo on)
            if [[ -n "$PROFILE_GITLAB" && "$PROFILE_GITLAB" != "$new" ]]; then
                echo "ERROR: --with-gitlab and --without-gitlab are contradictory." >&2
                exit 1
            fi
            PROFILE_GITLAB="$new"
            shift
            ;;
        --with-firmware|--without-firmware)
            new=$([[ "$1" == --without-* ]] && echo off || echo on)
            if [[ -n "$PROFILE_FIRMWARE" && "$PROFILE_FIRMWARE" != "$new" ]]; then
                echo "ERROR: --with-firmware and --without-firmware are contradictory." >&2
                exit 1
            fi
            PROFILE_FIRMWARE="$new"
            shift
            ;;
        --with-answer-service|--without-answer-service)
            new=$([[ "$1" == --without-* ]] && echo off || echo on)
            if [[ -n "$PROFILE_ANSWER_SERVICE" && "$PROFILE_ANSWER_SERVICE" != "$new" ]]; then
                echo "ERROR: --with-answer-service and --without-answer-service are contradictory." >&2
                exit 1
            fi
            PROFILE_ANSWER_SERVICE="$new"
            shift
            ;;
        --with-tacacs|--without-tacacs)
            new=$([[ "$1" == --without-* ]] && echo off || echo on)
            if [[ -n "$PROFILE_TACACS" && "$PROFILE_TACACS" != "$new" ]]; then
                echo "ERROR: --with-tacacs and --without-tacacs are contradictory." >&2
                exit 1
            fi
            PROFILE_TACACS="$new"
            shift
            ;;
        --firmware-url)
            FIRMWARE_URL="${2:-}"
            if [[ ! "$FIRMWARE_URL" =~ ^https?:// ]]; then
                echo "ERROR: --firmware-url must be a full base URL starting with http:// or https://" >&2
                echo "       e.g. --firmware-url https://192.0.2.10:9443/images/" >&2
                exit 1
            fi
            if [[ "$FIRMWARE_URL" != *"/images"* ]]; then
                echo "WARNING: --firmware-url has no /images path — the download endpoint serves" >&2
                echo "         files under /images/, so device URLs built from this base will 404" >&2
                echo "         unless you have customised the nginx config." >&2
            fi
            shift 2
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            cat <<'HELP'
Usage: ./setup.sh [-v VERSION] [-p PYTHON] [--with-gitlab] [--with-firmware]
                  [--with-answer-service] [--with-tacacs] [--firmware-url URL]
                  [--build] [--start] [--wait] [--debug]

Options:
  -v, --version VERSION   Nautobot version (default: 3.1)
  -p, --python  PYTHON    Python version suffix (default: 3.12)
      --with-gitlab       Enable the GitLab add-on: adds 'gitlab' to
                          COMPOSE_PROFILES in .env, so it starts with the
                          stack ('up -d', reboot, systemd unit)
      --without-gitlab    Disable the GitLab add-on (removes the profile
                          from .env; does not stop a running container)
      --with-firmware     Enable the firmware-server add-on (see README)
      --without-firmware  Disable the firmware-server add-on
      --with-answer-service
                          Enable the NFV answer-service add-on (bare-metal
                          Proxmox install engine; needs the sibling
                          nautobot-proxmox checkout — see README)
      --without-answer-service
                          Disable the answer-service add-on
      --with-tacacs       Enable the TACACS+ device-AAA add-on (tac_plus-ng +
                          Active Directory users + Nautobot-rendered device
                          inventory — see README)
      --without-tacacs    Disable the TACACS+ add-on
      --firmware-url URL  Device-facing firmware download base URL, written
                          to .env as FIRMWARE_BASE_URL and passed through to
                          the Nautobot worker (used by the nautobot-upgrades
                          Register Image job to build download URLs), e.g.
                          http://192.0.2.10/images/
                          Default: plain-HTTP URL derived from the host's
                          primary IP (routing table — never DNS or hostname).
                          HTTP is the default because device TLS clients
                          reject the self-signed cert; the HTTPS variant is
                          kept alongside in FIRMWARE_BASE_URL_HTTPS for the
                          Register job's per-run opt-in
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

  # Same, with the GitLab add-on enabled persistently (starts on boot too).
  ./setup.sh --with-gitlab --build --start --wait

  # Enable the firmware server on an existing install and start it.
  ./setup.sh --with-firmware --start

  # Same, but pin the device-facing download URL instead of auto-detecting
  # the host IP (multi-homed host, or a CA-certified DNS name).
  ./setup.sh --with-firmware --firmware-url http://192.0.2.10/images/ --start

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

echo "[1/7] Loading configuration..."

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

# Secret files for Nautobot's built-in "text file" secrets provider,
# bind-mounted read-only to /opt/nautobot/secrets (see secrets/README.md).
SECRETS_HOST_DIR="${SCRIPT_DIR}/secrets"

# Web TLS cert/key served by uWSGI, bind-mounted over the image's self-signed
# pair (see certs/README.md).  setup.sh generates a self-signed fallback here
# if the files are absent, so the bind mount source always exists.
CERTS_HOST_DIR="${SCRIPT_DIR}/certs"
CERT_FILE="${CERTS_HOST_DIR}/nautobot.crt"
CERT_KEY="${CERTS_HOST_DIR}/nautobot.key"

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
# Helper: firmware base URLs (FIRMWARE_BASE_URL / FIRMWARE_BASE_URL_HTTPS)
#
# The firmware add-on needs an EXTERNAL, device-reachable address to build
# the download URLs stored in Nautobot (SoftwareImageFile.download_url, via
# the nautobot-upgrades Register Image job reading FIRMWARE_BASE_URL from
# the worker environment).  The host's DNS name / `hostname` output is
# deliberately NOT used: lab devices dial back by IP and rarely resolve lab
# names.  Instead the primary IP comes from the routing table — the address
# this host actually uses to reach the network — and --firmware-url
# overrides it for multi-homed hosts or CA-certified DNS names.
#
# The DEFAULT base URL uses plain HTTP: device HTTPS clients (e.g. IOS-XE
# `copy https:`) validate the server certificate against their trustpoints
# and reject the self-signed cert the download endpoint generates, so HTTPS
# URLs only work once a CA-issued cert the devices trust is installed.  The
# HTTPS variant is still written alongside (FIRMWARE_BASE_URL_HTTPS) so the
# Register Image job can opt in per run.
# ---------------------------------------------------------------------------

detect_primary_ip() {
    case "$(uname -s)" in
        Darwin)
            local iface
            iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')" || true
            [[ -n "$iface" ]] && ipconfig getifaddr "$iface" 2>/dev/null
            ;;
        *)
            ip -4 route get 1.1.1.1 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
            ;;
    esac
}
PRIMARY_IP="$(detect_primary_ip || true)"

# Host part of a URL: strips scheme, path, and port.  (No IPv6-literal
# handling — lab URLs here are IPv4 or DNS names.)
host_of_url() {
    local host="${1#*://}"
    host="${host%%/*}"
    echo "${host%%:*}"
}

# Host part of the --firmware-url override (for FIRMWARE_SERVER_NAME, so the
# nginx server_name and the self-signed cert SAN match the stored URLs).
FIRMWARE_URL_HOST=""
if [[ -n "$FIRMWARE_URL" ]]; then
    FIRMWARE_URL_HOST="$(host_of_url "$FIRMWARE_URL")"
fi

# The resolved DEFAULT (HTTP) base URL for a given HTTP port: the explicit
# --firmware-url override wins verbatim (whatever scheme the user chose),
# else it is built from the detected primary IP.  Empty when neither is
# available — the Register job treats an empty FIRMWARE_BASE_URL as unset
# and asks for a per-run URL rather than storing one devices can't reach.
firmware_base_url_for_port() {
    local port="$1"
    if [[ -n "$FIRMWARE_URL" ]]; then
        echo "$FIRMWARE_URL"
    elif [[ -n "$PRIMARY_IP" ]]; then
        # Omit the port when it is the scheme default (80) — some HTTP
        # consumers of these URLs cannot handle an explicit port at all.
        if [[ "$port" == "80" ]]; then
            echo "http://${PRIMARY_IP}/images/"
        else
            echo "http://${PRIMARY_IP}:${port}/images/"
        fi
    fi
}

# The HTTPS variant for a given HTTPS port.  Host precedence: an explicit
# --firmware-url on this run, then the caller-supplied fallback host ($2 —
# used to follow the host of an existing customised FIRMWARE_BASE_URL, so a
# CA-certified DNS name is never replaced with a fabricated IP URL), then
# the detected primary IP.
firmware_https_url_for_port() {
    local port="$1" host="${FIRMWARE_URL_HOST:-${2:-$PRIMARY_IP}}"
    if [[ -n "$host" ]]; then
        if [[ "$port" == "443" ]]; then
            echo "https://${host}/images/"
        else
            echo "https://${host}:${port}/images/"
        fi
    fi
}

# Replace VAR=... in .env (BSD/GNU sed compatible).  Values here are URLs,
# IPs, and hostnames — no '|' or '&', the two characters special to this
# sed expression.
set_env_var() {
    sed -i.bak "s|^$1=.*|$1=$2|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
}

# Read a variable out of .env the way Compose's dotenv parser resolves it.
# A naive `cut | tr -d '" '` disagrees with Compose on four spellings that
# occur in real files — single quotes, a trailing CR from a CRLF-saved
# file, tabs, and inline `# comments` — and every such disagreement makes
# the decisions below (migrate? append?) fire against the wrong value.
env_value() {
    local v
    v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    v="${v%$'\r'}"                                  # CRLF-saved .env
    v="${v#"${v%%[![:space:]]*}"}"                  # trim leading blanks
    case "$v" in
        \"*\"*|\'*\'*)
            # Quoted: take what is inside the first matching pair (a '#'
            # inside quotes is data, not a comment).
            local q="${v:0:1}" rest
            rest="${v:1}"
            v="${rest%%${q}*}"
            ;;
        *)
            v="${v%%[[:space:]]#*}"                 # inline comment
            v="${v%"${v##*[![:space:]]}"}"          # trim trailing blanks
            ;;
    esac
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo ""
echo "[2/7] Preflight checks..."

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

# --- Warn when running as root ---
# Nothing here needs root (volume operations go through helper containers),
# and running under sudo leaves every file this script or a root git clone
# creates owned by root.  That has two failure modes later:
#   1. A non-root 'docker compose up' cannot read a root-owned .env (mode 600).
#   2. A root-owned nautobot_config.py without world-read crashes every
#      Nautobot container at startup, because the containers run as UID 999
#      and bind mounts pass host permissions through verbatim.
# Step [7/7] detects and repairs case 2, but flag the root cause up front.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "  WARNING: Running as root.  This script does not need root — volume" >&2
    echo "           operations use helper containers.  Files created now will be" >&2
    echo "           root-owned; if you later run 'docker compose' as a non-root" >&2
    echo "           user, it will not be able to read the root-owned .env." >&2
    echo "           Recommended: re-run as a regular user in the docker group." >&2
fi

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
echo "[3/7] Environment file..."

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

    # Default TACACS+ shared key for the optional tacacs add-on.  32 chars:
    # RFC 8907 §10.5.1 requires servers to support keys of at least that
    # length, and there is no reason to generate anything weaker.
    TACACS_KEY="$(generate_alphanum 32)"
    echo "    TACACS_DEFAULT_KEY: generated (${#TACACS_KEY} chars)"

    # Device-facing firmware URLs + matching server name (cert SAN).  80 /
    # 9443 are the FIRMWARE_HTTP_PORT / FIRMWARE_HTTPS_PORT defaults written
    # into the block below.  HTTP is the default URL (device TLS clients
    # reject the self-signed cert); the HTTPS variant is written alongside
    # for the Register Image job's per-run opt-in.
    FW_BASE_URL="$(firmware_base_url_for_port 80)"
    FW_HTTPS_URL="$(firmware_https_url_for_port 9443)"
    if [[ -n "$FIRMWARE_URL_HOST" ]]; then
        FW_SERVER_NAME="$FIRMWARE_URL_HOST"
    elif [[ -n "$FW_BASE_URL" ]]; then
        FW_SERVER_NAME="$PRIMARY_IP"
    else
        FW_SERVER_NAME="localhost"
    fi
    if [[ -n "$FW_BASE_URL" ]]; then
        echo "    FIRMWARE_BASE_URL:  ${FW_BASE_URL}"
        [[ -z "$FIRMWARE_URL" ]] && \
            echo "                        (host primary IP auto-detected — override with --firmware-url)"
        echo "    FIRMWARE_BASE_URL_HTTPS:  ${FW_HTTPS_URL}"
    else
        echo "    FIRMWARE_BASE_URL:  left empty — could not detect the host's primary IP."
        echo "                        Set it in .env or re-run with --firmware-url <url>."
    fi

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

# Comma-separated Compose profiles to activate persistently.  Compose reads
# this file for every 'docker compose' command run in this directory, so
# profiles listed here start with a plain 'up -d', come back after reboot,
# and are covered by the optional systemd unit.  Available: gitlab, firmware,
# answer-service, tacacs.
# Manage with './setup.sh --with-<profile>' (or --without-<profile>),
# or edit directly, e.g.:  COMPOSE_PROFILES=gitlab,firmware
COMPOSE_PROFILES=

# Image tag for the upstream Nautobot base image.  Read at build time as
# a docker compose build-arg.  Set or changed via 'setup.sh -v <version>'.
NAUTOBOT_VERSION=${NAUTOBOT_IMAGE_TAG}

NAUTOBOT_SECRET_KEY=${SECRET_KEY}
NAUTOBOT_ALLOWED_HOSTS=*
# Docker network subnet for this project (see env.example / README: Networking).
# 192.0.2.0/24 is RFC 5737 TEST-NET-1 — reserved, so it won't clash with real
# company routing the way Docker's default 172.x pool can.
NAUTOBOT_NETWORK_SUBNET=192.0.2.0/24
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
FIRMWARE_HTTP_PORT=80
FIRMWARE_HTTP_LEGACY_PORT=9080
FIRMWARE_SERVER_NAME=${FW_SERVER_NAME}
FIRMWARE_ALLOWED_CIDRS=0.0.0.0/0
FIRMWARE_ADMIN_USER=admin
FIRMWARE_ADMIN_PASSWORD=${FIRMWARE_ADMIN_PASSWORD}

# Device-facing base URL for firmware downloads — passed through this
# env_file to the Nautobot Celery worker, where the nautobot-upgrades
# "Register IOS-XE Image" job builds download_url as <base>/<filename>.
# Plain HTTP by default: device HTTPS clients validate the server cert
# against their trustpoints and reject the self-signed one.  The HTTPS
# variant below is used when the job's "use HTTPS URL" option is selected
# (needs a CA-issued cert the devices trust — see README: TLS).
# Keep the host in sync with FIRMWARE_SERVER_NAME (cert SAN / server_name).
FIRMWARE_BASE_URL=${FW_BASE_URL}
FIRMWARE_BASE_URL_HTTPS=${FW_HTTPS_URL}

# ---------------------------------------------------------------------------
# TACACS+ Server (optional add-on — Compose profile: tacacs)
# See env.example for documentation on each variable.  AD and Nautobot
# settings are left empty for field configuration; until they are set the
# daemon serves a safe seed config (no device can authenticate).
# ---------------------------------------------------------------------------
TACACS_DEFAULT_KEY=${TACACS_KEY}
TACACS_OPEN_DEFAULT=true
TACACS_AD_URLS=
TACACS_AD_BASE_DN=
TACACS_AD_BIND_DN=
TACACS_AD_BIND_PASSWORD=
TACACS_ADMIN_GROUP=
TACACS_READONLY_GROUP=
TACACS_NAUTOBOT_TOKEN=
TACACS_DEVICE_TAG=tacacs
TACACS_RENDER_INTERVAL=300
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
echo "[4/7] Configuring Nautobot version..."

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

# Backward-compat: older .env files predate the pinned Docker network subnet.
# Append the default; the compose file also defaults it via :- so this is just
# for discoverability.  Never overwrite a subnet the user has customised.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^NAUTOBOT_NETWORK_SUBNET=' "$ENV_FILE"; then
    printf '\nNAUTOBOT_NETWORK_SUBNET=192.0.2.0/24\n' >> "$ENV_FILE"
    echo "  .env: NAUTOBOT_NETWORK_SUBNET appended (192.0.2.0/24)"
    echo "        Applying to a RUNNING stack needs: docker compose down && docker compose up -d"
fi

# Backward-compat: older .env files predate the optional firmware server, and a
# hand-created .env ("cp env.example .env") ships the block but with the admin
# password commented out.  Handle both cases without duplicating the block or
# reverting values the user may have customised.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_BIND_ADDRESS=' "$ENV_FILE"; then
    # No firmware block present at all — append the whole thing.
    FW_ADMIN_PW="$(generate_alphanum 24)"
    FW_BASE_URL="$(firmware_base_url_for_port 80)"
    FW_HTTPS_URL="$(firmware_https_url_for_port 9443)"
    if [[ -n "$FIRMWARE_URL_HOST" ]]; then
        FW_SERVER_NAME="$FIRMWARE_URL_HOST"
    elif [[ -n "$FW_BASE_URL" ]]; then
        FW_SERVER_NAME="$PRIMARY_IP"
    else
        FW_SERVER_NAME="localhost"
    fi
    cat >> "$ENV_FILE" <<EOF

# ---------------------------------------------------------------------------
# Firmware Server (optional add-on — Compose profile: firmware)
# See env.example for documentation on each variable.
# ---------------------------------------------------------------------------
FIRMWARE_BIND_ADDRESS=0.0.0.0
FIRMWARE_FILEBROWSER_PORT=8088
FIRMWARE_HTTPS_PORT=9443
FIRMWARE_HTTP_PORT=80
FIRMWARE_HTTP_LEGACY_PORT=9080
FIRMWARE_SERVER_NAME=${FW_SERVER_NAME}
FIRMWARE_ALLOWED_CIDRS=0.0.0.0/0
FIRMWARE_ADMIN_USER=admin
FIRMWARE_ADMIN_PASSWORD=${FW_ADMIN_PW}

# Device-facing base URL for firmware downloads — passed through this
# env_file to the Nautobot Celery worker, where the nautobot-upgrades
# "Register IOS-XE Image" job builds download_url as <base>/<filename>.
# Plain HTTP by default (device TLS clients reject the self-signed cert);
# the HTTPS variant is used when the job's "use HTTPS URL" option is
# selected.  Keep hosts in sync with FIRMWARE_SERVER_NAME (cert SAN).
FIRMWARE_BASE_URL=${FW_BASE_URL}
FIRMWARE_BASE_URL_HTTPS=${FW_HTTPS_URL}
EOF
    echo "  .env: firmware-server block appended (admin password generated)"
    echo "        Firmware UI admin password: ${FW_ADMIN_PW}  (user: see FIRMWARE_ADMIN_USER)"
    echo "        FIRMWARE_BASE_URL: ${FW_BASE_URL:-<empty — set manually or re-run with --firmware-url>}"
elif [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_ADMIN_PASSWORD=' "$ENV_FILE"; then
    # Firmware block exists but the admin password is still unset/commented —
    # add just the active password line.
    FW_ADMIN_PW="$(generate_alphanum 24)"
    printf '\nFIRMWARE_ADMIN_PASSWORD=%s\n' "$FW_ADMIN_PW" >> "$ENV_FILE"
    echo "  .env: FIRMWARE_ADMIN_PASSWORD generated and appended"
    echo "        Firmware UI admin password: ${FW_ADMIN_PW}  (user: see FIRMWARE_ADMIN_USER)"
fi

# Backward-compat: older .env files predate the optional TACACS+ add-on, and a
# hand-created .env ("cp env.example .env") ships the block with the default
# key commented out.  Same two-tier pattern as the firmware block above.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^TACACS_OPEN_DEFAULT=' "$ENV_FILE"; then
    # No tacacs block at all — append the whole thing with a generated key.
    TACACS_KEY="$(generate_alphanum 32)"
    cat >> "$ENV_FILE" <<EOF

# ---------------------------------------------------------------------------
# TACACS+ Server (optional add-on — Compose profile: tacacs)
# See env.example for documentation on each variable.  AD and Nautobot
# settings are left empty for field configuration; until they are set the
# daemon serves a safe seed config (no device can authenticate).
# ---------------------------------------------------------------------------
TACACS_DEFAULT_KEY=${TACACS_KEY}
TACACS_OPEN_DEFAULT=true
TACACS_AD_URLS=
TACACS_AD_BASE_DN=
TACACS_AD_BIND_DN=
TACACS_AD_BIND_PASSWORD=
TACACS_ADMIN_GROUP=
TACACS_READONLY_GROUP=
TACACS_NAUTOBOT_TOKEN=
TACACS_DEVICE_TAG=tacacs
TACACS_RENDER_INTERVAL=300
EOF
    echo "  .env: tacacs block appended (default device key generated, 32 chars)"
elif [[ -f "$ENV_FILE" ]] && ! grep -qE '^TACACS_DEFAULT_KEY=' "$ENV_FILE"; then
    # Block exists but the key is still unset/commented — add just the key.
    TACACS_KEY="$(generate_alphanum 32)"
    printf '\nTACACS_DEFAULT_KEY=%s\n' "$TACACS_KEY" >> "$ENV_FILE"
    echo "  .env: TACACS_DEFAULT_KEY generated and appended (32 chars)"
fi

# Backward-compat / override: FIRMWARE_BASE_URL — the device-facing download
# URL, passed through .env (env_file) to the Celery worker where the
# nautobot-upgrades "Register IOS-XE Image" job reads it.  Cases:
#   * line missing (block pre-dates it) — append with the resolved value
#   * line present and --firmware-url given — update it
#   * line present holding the https URL a PREVIOUS setup.sh auto-generated
#     (exactly https://<current primary IP>:<FIRMWARE_HTTPS_PORT>/images/) —
#     migrate it to the new http default; a value that doesn't match that
#     pattern byte-for-byte was customised and is never touched.  ONE-SHOT:
#     the migration only fires while FIRMWARE_BASE_URL_HTTPS is absent (the
#     pre-http-default script never wrote that var, and this script appends
#     it right below), so re-pinning https via --firmware-url or a hand
#     edit sticks on every later run.
#   * line present, no flag, not the old auto value — leave it alone
# Then FIRMWARE_BASE_URL_HTTPS: append if missing (or refresh on an explicit
# --firmware-url, or backfill a value left empty when IP detection failed)
# so the Register job's per-run HTTPS opt-in has a value.  Its host follows
# the existing FIRMWARE_BASE_URL so a customised DNS name is never replaced
# with a fabricated IP URL.
FW_HTTP_PORT="$(env_value FIRMWARE_HTTP_PORT)"
FW_HTTPS_PORT="$(env_value FIRMWARE_HTTPS_PORT)"
FW_URL_TOUCHED=false
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_BASE_URL=' "$ENV_FILE"; then
    FW_BASE_URL="$(firmware_base_url_for_port "${FW_HTTP_PORT:-80}")"
    cat >> "$ENV_FILE" <<EOF

# Device-facing base URL for firmware downloads (see env.example) — read by
# the Nautobot Celery worker for the nautobot-upgrades Register Image job.
FIRMWARE_BASE_URL=${FW_BASE_URL}
EOF
    FW_URL_TOUCHED=true
    if [[ -n "$FW_BASE_URL" ]]; then
        echo "  .env: FIRMWARE_BASE_URL appended (${FW_BASE_URL})"
        [[ -z "$FIRMWARE_URL" ]] && \
            echo "        (host primary IP auto-detected — override with --firmware-url)"
    else
        echo "  .env: FIRMWARE_BASE_URL appended EMPTY — could not detect the host's primary IP."
        echo "        Set it manually or re-run with --firmware-url <url>."
    fi
elif [[ -f "$ENV_FILE" && -n "$FIRMWARE_URL" ]]; then
    set_env_var FIRMWARE_BASE_URL "$FIRMWARE_URL"
    FW_URL_TOUCHED=true
    echo "  .env: FIRMWARE_BASE_URL → ${FIRMWARE_URL}"
elif [[ -f "$ENV_FILE" && -n "$PRIMARY_IP" ]] \
    && ! grep -qE '^FIRMWARE_BASE_URL_HTTPS=' "$ENV_FILE"; then
    # One-shot migration: flip a provably auto-generated https default to
    # the new http default (device TLS clients reject the self-signed
    # cert).  Gated on FIRMWARE_BASE_URL_HTTPS being absent — only a .env
    # written before the http-default change lacks it, and it is appended
    # right below, so this can never fire twice: an https URL re-pinned
    # later (via --firmware-url or a hand edit) is left alone.
    CURRENT_BASE_URL="$(env_value FIRMWARE_BASE_URL)"
    OLD_AUTO_HTTPS="https://${PRIMARY_IP}:${FW_HTTPS_PORT:-9443}/images/"
    if [[ "$CURRENT_BASE_URL" == "$OLD_AUTO_HTTPS" ]]; then
        NEW_HTTP_URL="$(firmware_base_url_for_port "${FW_HTTP_PORT:-80}")"
        set_env_var FIRMWARE_BASE_URL "$NEW_HTTP_URL"
        FW_URL_TOUCHED=true
        echo "  .env: FIRMWARE_BASE_URL → ${NEW_HTTP_URL}"
        echo "        (one-shot migration from the auto-generated https default: device TLS"
        echo "         clients reject the self-signed cert; https stays available per run via"
        echo "         the Register job's 'use HTTPS URL' option and FIRMWARE_BASE_URL_HTTPS."
        echo "         To keep https as the default, edit FIRMWARE_BASE_URL back — this"
        echo "         migration never runs again once FIRMWARE_BASE_URL_HTTPS exists.)"
    fi
fi

# FIRMWARE_BASE_URL_HTTPS — the per-run HTTPS alternative for the Register
# job.  Follow the host of the existing FIRMWARE_BASE_URL (a customised DNS
# name or multi-homed IP) rather than fabricating one from the primary IP.
FW_BASE_HOST=""
if [[ -f "$ENV_FILE" ]]; then
    EXISTING_BASE_URL="$(env_value FIRMWARE_BASE_URL)"
    [[ -n "$EXISTING_BASE_URL" ]] && FW_BASE_HOST="$(host_of_url "$EXISTING_BASE_URL")"
fi
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_BASE_URL_HTTPS=' "$ENV_FILE"; then
    FW_HTTPS_URL="$(firmware_https_url_for_port "${FW_HTTPS_PORT:-9443}" "$FW_BASE_HOST")"
    cat >> "$ENV_FILE" <<EOF

# HTTPS variant of FIRMWARE_BASE_URL — stored per image only when the
# Register job's "use HTTPS URL" option is selected (see env.example).
FIRMWARE_BASE_URL_HTTPS=${FW_HTTPS_URL}
EOF
    echo "  .env: FIRMWARE_BASE_URL_HTTPS appended (${FW_HTTPS_URL:-<empty>})"
elif [[ -f "$ENV_FILE" ]]; then
    CURRENT_HTTPS_URL="$(env_value FIRMWARE_BASE_URL_HTTPS)"
    if [[ -n "$FIRMWARE_URL" || -z "$CURRENT_HTTPS_URL" ]]; then
        # Refresh on an explicit --firmware-url, or backfill a line left
        # empty by an earlier run where IP detection failed.
        FW_HTTPS_URL="$(firmware_https_url_for_port "${FW_HTTPS_PORT:-9443}" "$FW_BASE_HOST")"
        if [[ -n "$FW_HTTPS_URL" && "$FW_HTTPS_URL" != "$CURRENT_HTTPS_URL" ]]; then
            set_env_var FIRMWARE_BASE_URL_HTTPS "$FW_HTTPS_URL"
            if [[ -n "$FIRMWARE_URL" ]]; then
                echo "  .env: FIRMWARE_BASE_URL_HTTPS → ${FW_HTTPS_URL} (host follows --firmware-url)"
            else
                echo "  .env: FIRMWARE_BASE_URL_HTTPS backfilled (${FW_HTTPS_URL})"
            fi
        fi
    fi
fi

# One-shot host-port migration: the firmware HTTP endpoint moved from host
# port 9080 to the protocol default 80 (a consumer in the upgrade pipeline
# cannot specify a port; the Nautobot web service gave up its plain-HTTP
# 80 mapping to free it).  Migrate only the provably untouched pairing:
# FIRMWARE_HTTP_PORT still the old 9080 default AND FIRMWARE_BASE_URL empty
# or exactly the auto-generated URL for that port.  Anything customised is
# left alone with a NOTE.  Naturally one-shot: after migration the port is
# 80, so the 9080 condition never matches again.
if [[ -f "$ENV_FILE" ]] \
    && [[ "$(env_value FIRMWARE_HTTP_PORT)" == "9080" ]]; then
    CURRENT_BASE_URL="$(env_value FIRMWARE_BASE_URL)"
    OLD_AUTO_HTTP=""
    [[ -n "$PRIMARY_IP" ]] && OLD_AUTO_HTTP="http://${PRIMARY_IP}:9080/images/"
    if [[ -z "$CURRENT_BASE_URL" || ( -n "$OLD_AUTO_HTTP" && "$CURRENT_BASE_URL" == "$OLD_AUTO_HTTP" ) ]]; then
        set_env_var FIRMWARE_HTTP_PORT 80
        echo "  .env: FIRMWARE_HTTP_PORT → 80 (one-shot migration from the old 9080 default:"
        echo "        a component consuming these URLs requires the protocol-default port;"
        echo "        the Nautobot web service no longer publishes host port 80)"
        if [[ -n "$CURRENT_BASE_URL" ]]; then
            NEW_HTTP_URL="http://${PRIMARY_IP}/images/"
            set_env_var FIRMWARE_BASE_URL "$NEW_HTTP_URL"
            echo "  .env: FIRMWARE_BASE_URL → ${NEW_HTTP_URL} (follows the port migration)"
        fi
        echo "        To keep 9080 as the ONLY published HTTP port, set FIRMWARE_HTTP_PORT"
        echo "        back to 9080 — note that host port 80 is then not published at all,"
        echo "        which is what a component requiring the default port needs."
        echo "        NOTE: images already registered in Nautobot keep their STORED"
        echo "        download_url; URLs embedding :9080 continue to work through the"
        echo "        legacy compatibility port (FIRMWARE_HTTP_LEGACY_PORT, published"
        echo "        alongside 80).  Re-register images at your leisure to converge on"
        echo "        the port-less form, then retire the legacy mapping (see README)."
    else
        echo "  NOTE: the firmware HTTP endpoint now defaults to host port 80, but this .env"
        echo "        pins FIRMWARE_HTTP_PORT=9080 with a customised FIRMWARE_BASE_URL — left"
        echo "        untouched.  Edit both in .env if you want the new default."
    fi
fi

# FIRMWARE_HTTP_LEGACY_PORT — the extra publish that keeps pre-move
# download_urls (which embed :9080) working.  Write it explicitly into any
# .env that predates it, so what gets published never depends on the
# compose default.  That default is 80 (a no-op that collapses onto the
# primary publish) specifically so an unmigrated .env can't end up with no
# port-80 publish at all; the real backward-compat value belongs here.
if [[ -f "$ENV_FILE" ]] && ! grep -qE '^FIRMWARE_HTTP_LEGACY_PORT=' "$ENV_FILE"; then
    # Written UNCONDITIONALLY, including when the primary port is itself
    # still 9080: the two publishes then collapse to one (9080 only), which
    # respects a deliberately pinned port instead of forcing an unwanted
    # host-80 bind on it.  Every setup.sh-managed .env therefore states both
    # ports explicitly, and the compose defaults decide nothing.
    cat >> "$ENV_FILE" <<'EOF'

# Legacy HTTP port published alongside FIRMWARE_HTTP_PORT so download_urls
# registered before the port-80 move (they embed :9080) keep working.
# Set equal to FIRMWARE_HTTP_PORT to disable the extra publish.
FIRMWARE_HTTP_LEGACY_PORT=9080
EOF
    echo "  .env: FIRMWARE_HTTP_LEGACY_PORT appended (9080 — keeps pre-move download_urls working)"
fi

# Keep FIRMWARE_SERVER_NAME (nginx server_name + self-signed cert SAN) aligned
# with the host in FIRMWARE_BASE_URL — but only on a run that actually set the
# URL, and never clobber a name the user customised: an explicit
# --firmware-url always wins; auto-detection only replaces the shipped
# default ('localhost').
if [[ "$FW_URL_TOUCHED" == true && -f "$ENV_FILE" ]]; then
    CURRENT_FW_NAME="$(env_value FIRMWARE_SERVER_NAME)"
    NEW_FW_NAME="${FIRMWARE_URL_HOST:-$PRIMARY_IP}"
    if [[ -n "$NEW_FW_NAME" && -n "$CURRENT_FW_NAME" && "$CURRENT_FW_NAME" != "$NEW_FW_NAME" ]] \
        && [[ -n "$FIRMWARE_URL" || "$CURRENT_FW_NAME" == "localhost" ]]; then
        set_env_var FIRMWARE_SERVER_NAME "$NEW_FW_NAME"
        echo "  .env: FIRMWARE_SERVER_NAME → ${NEW_FW_NAME} (matches FIRMWARE_BASE_URL host)"
        if [[ -s "${SCRIPT_DIR}/firmware/certs/server.crt" ]]; then
            echo "        NOTE: an existing TLS cert is present and is NOT regenerated."
            echo "        For a self-signed cert with the new name/IP in its SAN, remove it"
            echo "        and restart:  rm firmware/certs/server.crt firmware/certs/server.key"
            echo "                      docker compose --profile firmware up -d firmware-download"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Compose profiles (opt-in add-ons: gitlab, firmware, answer-service, tacacs)
# ---------------------------------------------------------------------------
# COMPOSE_PROFILES in .env is the persistent switch for the add-on services:
# Compose reads it for every command run in this directory, so profiles
# listed there start on 'docker compose up -d', come back after a reboot,
# and are handled by the optional systemd unit.  --with-X / --without-X
# add/remove entries; with neither flag the existing value is left alone.

# Current value (may be absent in .env files that predate this scheme).
CURRENT_PROFILES="$(env_value COMPOSE_PROFILES)"

# Apply the requested changes to the comma-separated list.
NEW_PROFILES="$CURRENT_PROFILES"
apply_profile_switch() {
    local name="$1" mode="$2" list="$NEW_PROFILES" out=()
    [[ -z "$mode" ]] && return 0
    local IFS=','
    for p in $list; do
        [[ -n "$p" && "$p" != "$name" ]] && out+=("$p")
    done
    [[ "$mode" == "on" ]] && out+=("$name")
    NEW_PROFILES="${out[*]-}"
}
apply_profile_switch gitlab         "$PROFILE_GITLAB"
apply_profile_switch firmware       "$PROFILE_FIRMWARE"
apply_profile_switch answer-service "$PROFILE_ANSWER_SERVICE"
apply_profile_switch tacacs         "$PROFILE_TACACS"

if [[ "$NEW_PROFILES" != "$CURRENT_PROFILES" ]] || ! grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE"; then
    if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE"; then
        sed -i.bak "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${NEW_PROFILES}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        # Backward-compat: append to an existing .env that predates profiles.
        cat >> "$ENV_FILE" <<EOF

# Comma-separated Compose profiles to activate persistently (gitlab, firmware,
# answer-service, tacacs).  Manage with './setup.sh --with-<profile> / --without-<profile>'.
COMPOSE_PROFILES=${NEW_PROFILES}
EOF
    fi
    echo "  .env: COMPOSE_PROFILES → '${NEW_PROFILES}'"
fi
echo "  .env: active profiles: '${NEW_PROFILES:-none}' (add-ons start with the stack: up -d, reboot, systemd)"

# Echo the active environment tier so the user sees what they're operating on.
CURRENT_ENV="$(env_value NAUTOBOT_ENV)"
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
echo "[5/7] Creating Docker volumes..."

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
echo "[6/7] Initializing Nautobot volumes (mkdir + chown ${NAUTOBOT_UID}:${NAUTOBOT_GID})..."

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

# Ensure the bind-mounted secrets/ directory exists with tight-but-usable
# permissions: owner = the invoking host user (so 'add-secret.sh' and plain
# editors work without sudo), group = the container GID with read-only
# access (so the Nautobot containers can read secret files), no world
# access.  Files: 640, directory: 750.  Ownership is applied through a
# helper container (root inside) so no host sudo is needed — same pattern
# as the volume chown above; on macOS/Docker Desktop it is cosmetic.
mkdir -p "${SECRETS_HOST_DIR}"
# ./secrets/tacacs holds the optional TACACS+ per-device key files and is the
# bind SOURCE for the tacacs service's scoped, read-only /secrets/tacacs mount
# — create it now so Compose doesn't materialise a root-owned empty dir on
# first `up`.
mkdir -p "${SECRETS_HOST_DIR}/tacacs"
docker run --rm \
    -v "${SECRETS_HOST_DIR}:/secrets" \
    alpine sh -c "
        chown -R ${EUID:-$(id -u)}:${NAUTOBOT_GID} /secrets
        chmod 750 /secrets
        find /secrets -type d -exec chmod 750 {} +
        find /secrets -type f -exec chmod 640 {} +
    "

# Web TLS certificate: the nautobot service bind-mounts ./certs/nautobot.crt
# and ./certs/nautobot.key over uWSGI's cert paths, so those two files MUST
# exist before the stack starts.  Generate a self-signed pair if the user has
# not supplied their own — the stack then serves HTTPS out of the box (with a
# browser warning) and the operator can drop in a CA-issued cert later and
# restart nautobot.  openssl is a setup.sh preflight requirement.
mkdir -p "${CERTS_HOST_DIR}"
if [[ -s "$CERT_FILE" && -s "$CERT_KEY" ]]; then
    echo "  Web TLS cert present (certs/nautobot.crt) — leaving it untouched."
else
    echo "  Generating a self-signed web TLS cert (certs/nautobot.crt) ..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_KEY" -out "$CERT_FILE" -days 825 \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    echo "    Self-signed — browsers will warn.  Replace certs/nautobot.crt and"
    echo "    certs/nautobot.key with a CA-issued cert, then: docker compose restart nautobot"
fi
# Ownership: host user can edit; container GID (999) can read the key via group
# (key 640, cert 644).  Same helper-container pattern as ./secrets above.
docker run --rm \
    -v "${CERTS_HOST_DIR}:/certs" \
    alpine sh -c "
        chown -R ${EUID:-$(id -u)}:${NAUTOBOT_GID} /certs
        chmod 750 /certs
        [ -f /certs/nautobot.crt ] && chmod 644 /certs/nautobot.crt
        [ -f /certs/nautobot.key ] && chmod 640 /certs/nautobot.key
        true
    "

# ---------------------------------------------------------------------------
# Answer service one-time setup — only when its profile is enabled.
#   (1) sibling nautobot-proxmox build context (warn only; can't clone it here)
#   (2) TLS keypair -> answer-service/certs + SHA256 fingerprint -> .env
#   (3) root password hash for installed nodes -> secrets/root_password_hash
# The answer service can't start without ANSWER_NAUTOBOT_TOKEN / ANSWER_PUBLIC_URL
# either — those are operator-supplied (a Nautobot token, a LAN URL), so we
# can't generate them, but we flag them if missing.
# ---------------------------------------------------------------------------
if [[ ",${NEW_PROFILES}," == *,answer-service,* ]]; then
    echo ""
    echo "  Answer service enabled — preparing its prerequisites..."

    # (1) Build context.  Default: the nautobot-proxmox repo fetched over git
    # at build time (BuildKit git context — no local checkout needed).  A git
    # URL can't be checked from here beyond noting it needs network at build
    # time; a LOCAL override (path) is checked so `up --build` doesn't fail
    # cryptically on a missing sibling checkout.
    ASVC_CTX="$(env_value ANSWER_SERVICE_BUILD_CONTEXT)"
    ASVC_CTX="${ASVC_CTX:-https://github.com/bforejt/nautobot-proxmox.git#main:bmc}"
    case "$ASVC_CTX" in
        http://*|https://*|git@*|ssh://*)
            echo "    build context: ${ASVC_CTX}"
            echo "      (fetched over git at build time — the docker daemon needs network;"
            echo "       set ANSWER_SERVICE_BUILD_CONTEXT=../nautobot-proxmox/bmc in .env to"
            echo "       build from a local checkout instead)"
            ;;
        *)
            case "$ASVC_CTX" in
                /*) ASVC_CTX_ABS="$ASVC_CTX" ;;
                *)  ASVC_CTX_ABS="${SCRIPT_DIR}/${ASVC_CTX}" ;;
            esac
            if [[ -f "${ASVC_CTX_ABS}/answer_service/Dockerfile" ]]; then
                echo "    build context OK: ${ASVC_CTX}"
            else
                echo "    WARNING: build context '${ASVC_CTX}' not found (expected a"
                echo "             nautobot-proxmox checkout with answer_service/Dockerfile)."
                echo "             'docker compose --profile answer-service up -d --build' will fail"
                echo "             until it exists — or unset ANSWER_SERVICE_BUILD_CONTEXT in .env"
                echo "             to use the default git-URL context (no checkout needed)."
            fi
            ;;
    esac

    # (2) TLS keypair (nodes pin it by fingerprint).  NEVER regenerate an
    # existing cert — its fingerprint is baked into any prepared installer media.
    ASVC_CERT_DIR="${SCRIPT_DIR}/answer-service/certs"
    mkdir -p "$ASVC_CERT_DIR"
    if [[ -s "${ASVC_CERT_DIR}/answer-service.crt" && -s "${ASVC_CERT_DIR}/answer-service.key" ]]; then
        echo "    answer-service TLS cert present — leaving it untouched."
    else
        echo "    Generating answer-service TLS keypair (answer-service/certs) ..."
        openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
            -subj "/CN=answer-service" \
            -keyout "${ASVC_CERT_DIR}/answer-service.key" \
            -out "${ASVC_CERT_DIR}/answer-service.crt" 2>/dev/null
    fi
    # Fingerprint (SHA256 of the DER cert) -> .env, always matching the cert on
    # disk.  Same hex `sha256sum` produces (what prepare-install-iso expects).
    # '|| ASVC_FP=""' keeps a failed pipeline (e.g. a corrupt cert) from
    # aborting the script under 'set -e' — the guard below handles the empty case.
    ASVC_FP="$(openssl x509 -in "${ASVC_CERT_DIR}/answer-service.crt" -outform der 2>/dev/null \
        | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')" || ASVC_FP=""
    if [[ -n "$ASVC_FP" ]]; then
        if grep -qE '^ANSWER_CERT_FINGERPRINT=' "$ENV_FILE"; then
            set_env_var ANSWER_CERT_FINGERPRINT "$ASVC_FP"
        else
            printf '\nANSWER_CERT_FINGERPRINT=%s\n' "$ASVC_FP" >> "$ENV_FILE"
        fi
        echo "    ANSWER_CERT_FINGERPRINT set in .env (${ASVC_FP:0:16}…)"
    fi

    # (3) Root password hash for installed bare-metal nodes.  Generate a strong
    # random one if absent (printed once below); replace the file to change it.
    # SHA-512 crypt via `openssl passwd -6` — but macOS ships LibreSSL as
    # /usr/bin/openssl, which lacks '-6', so probe first and fall back to a
    # helper container (OpenSSL).  Build the hash in a variable and only write
    # the file on success, so a failure never leaves a 0-byte hash that the
    # '-s' guard would then treat as "absent" and re-attempt forever.
    ROOT_HASH_FILE="${SECRETS_HOST_DIR}/root_password_hash"
    if [[ -s "$ROOT_HASH_FILE" ]]; then
        echo "    root password hash present (secrets/root_password_hash) — leaving it untouched."
    else
        ASVC_ROOT_PW="$(generate_alphanum 20)"
        if openssl passwd -6 "probe" >/dev/null 2>&1; then
            ASVC_ROOT_HASH="$(openssl passwd -6 "$ASVC_ROOT_PW" 2>/dev/null)" || ASVC_ROOT_HASH=""
        else
            # Host openssl (LibreSSL) can't do -6; hash inside an OpenSSL container.
            ASVC_ROOT_HASH="$(docker run --rm -e PW="$ASVC_ROOT_PW" alpine sh -c \
                'apk add --no-cache -q openssl >/dev/null 2>&1 && openssl passwd -6 "$PW"' 2>/dev/null)" \
                || ASVC_ROOT_HASH=""
        fi
        if [[ "$ASVC_ROOT_HASH" == \$6\$* ]]; then
            printf '%s\n' "$ASVC_ROOT_HASH" > "$ROOT_HASH_FILE"
            echo "    Generated a root password for INSTALLED NODES (hash in secrets/root_password_hash):"
            echo "      root password: ${ASVC_ROOT_PW}   <- save this; replace the hash file to change it"
        else
            echo "    WARNING: could not generate the node root password hash (openssl -6 unavailable)."
            echo "             Create it manually, e.g.:  openssl passwd -6 > secrets/root_password_hash"
        fi
    fi

    # Ownership: a non-root answer-service container in the stack GID can read
    # the key/hash (640) while the host user keeps edit access — like ./secrets.
    docker run --rm \
        -v "${ASVC_CERT_DIR}:/tls" \
        -v "${SECRETS_HOST_DIR}:/secrets" \
        alpine sh -c "
            chown -R ${EUID:-$(id -u)}:${NAUTOBOT_GID} /tls
            chmod 750 /tls
            [ -f /tls/answer-service.crt ] && chmod 644 /tls/answer-service.crt
            [ -f /tls/answer-service.key ] && chmod 640 /tls/answer-service.key
            if [ -f /secrets/root_password_hash ]; then
                chown ${EUID:-$(id -u)}:${NAUTOBOT_GID} /secrets/root_password_hash
                chmod 640 /secrets/root_password_hash
            fi
            true
        "

    # (4) ANSWER_PUBLIC_URL — derive a default from the host's primary IP,
    # exactly like FIRMWARE_BASE_URL does (routing table, never DNS).  Only
    # when empty: a value the operator set (multi-homed host, DNS name, or a
    # mgmt VLAN the nodes live on) is never touched.  NOTE: this URL gets
    # baked into prepared installer media, so a DHCP-ish host IP is a hazard —
    # the printed line says how to override.
    if [[ -z "$(env_value ANSWER_PUBLIC_URL)" ]]; then
        if [[ -n "$PRIMARY_IP" ]]; then
            ASVC_PORT="$(env_value ANSWER_PORT)"
            ASVC_URL="https://${PRIMARY_IP}:${ASVC_PORT:-8800}"
            if grep -qE '^ANSWER_PUBLIC_URL=' "$ENV_FILE"; then
                set_env_var ANSWER_PUBLIC_URL "$ASVC_URL"
            else
                printf '\nANSWER_PUBLIC_URL=%s\n' "$ASVC_URL" >> "$ENV_FILE"
            fi
            echo "    ANSWER_PUBLIC_URL auto-detected: ${ASVC_URL}"
            echo "      (host primary IP — override in .env for multi-homed hosts or a DNS"
            echo "       name; it is baked into prepared installer media, so prefer a"
            echo "       stable address)"
        else
            echo "    ACTION NEEDED: set ANSWER_PUBLIC_URL in .env (e.g. https://<host-ip>:8800)"
            echo "                   — could not detect the host's primary IP."
        fi
    fi

    # (5) ANSWER_NAUTOBOT_TOKEN — on the lab tier, default to the superuser
    # API token setup.sh already generated (it's in the same .env, so this
    # copies a value the operator can already see — no new exposure).  The
    # value is written visibly so swapping in a scoped service-account token
    # later is a one-line edit.  Non-lab tiers get no automatic admin token:
    # least-privilege is worth the manual step there.
    if [[ -z "$(env_value ANSWER_NAUTOBOT_TOKEN)" ]]; then
        ASVC_TIER="$(env_value NAUTOBOT_ENV)"
        ASVC_SU_TOKEN="$(env_value NAUTOBOT_SUPERUSER_API_TOKEN)"
        if [[ "${ASVC_TIER:-lab}" == "lab" && -n "$ASVC_SU_TOKEN" ]]; then
            if grep -qE '^ANSWER_NAUTOBOT_TOKEN=' "$ENV_FILE"; then
                set_env_var ANSWER_NAUTOBOT_TOKEN "$ASVC_SU_TOKEN"
            else
                printf '\nANSWER_NAUTOBOT_TOKEN=%s\n' "$ASVC_SU_TOKEN" >> "$ENV_FILE"
            fi
            echo "    ANSWER_NAUTOBOT_TOKEN defaulted to the superuser API token (lab tier)."
            echo "      For staging/production, replace it with a scoped service-account token."
        else
            echo "    ACTION NEEDED: set ANSWER_NAUTOBOT_TOKEN in .env (a Nautobot API token"
            echo "                   — not auto-filled on the '${ASVC_TIER:-lab}' tier)."
        fi
    fi
fi

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
    -v "${SECRETS_HOST_DIR}:/secrets" \
    alpine sh -c "
        echo '  ${MEDIA_VOLUME}  owner='\$(stat -c '%u:%g' /media);
        for d in /media/*/; do
            echo '    '\$(basename \$d)'/  owner='\$(stat -c '%u:%g' \$d);
        done;
        echo '  ${GIT_VOLUME}  owner='\$(stat -c '%u:%g' /git);
        echo '  ./jobs (bind mount)  owner='\$(stat -c '%u:%g' /jobs);
        echo '  ./secrets (bind mount)  owner='\$(stat -c '%u:%g' /secrets);
    "

# ---------------------------------------------------------------------------
# Verify bind-mounted files are readable by the container user
# ---------------------------------------------------------------------------

echo ""
echo "[7/7] Verifying container access to bind-mounted files..."

# docker-compose.yml bind-mounts ./nautobot_config.py into every Nautobot
# container, and those containers run as UID ${NAUTOBOT_UID}, not root.
# Bind mounts pass host ownership and permissions through verbatim, so a
# config file that is not world-readable (e.g. the repo was cloned as root
# with a restrictive umask) crashes every container at startup with:
#   PermissionError: [Errno 13] Permission denied: '/opt/nautobot/nautobot_config.py'
# Test readability AS the container UID from inside a container — that is
# the ground truth, and it also behaves correctly on macOS/Docker Desktop,
# where file sharing virtualizes ownership.  If unreadable, repair via a
# helper container (same no-sudo pattern as the volume chown above).
CONFIG_HOST_FILE="${SCRIPT_DIR}/nautobot_config.py"

check_bind_file_readable() {
    docker run --rm --user "${NAUTOBOT_UID}:${NAUTOBOT_GID}" \
        -v "$1:/check:ro" \
        alpine sh -c 'cat /check >/dev/null' &>/dev/null
}

if check_bind_file_readable "$CONFIG_HOST_FILE"; then
    echo "  nautobot_config.py — readable by container user (UID ${NAUTOBOT_UID})"
else
    echo "  nautobot_config.py — NOT readable by container user (UID ${NAUTOBOT_UID})"
    echo "  Repairing: adding world-read (chmod o+r) via helper container..."
    docker run --rm -v "${CONFIG_HOST_FILE}:/check" alpine chmod o+r /check || true
    if check_bind_file_readable "$CONFIG_HOST_FILE"; then
        echo "  Repaired — nautobot_config.py is now readable."
    else
        echo "  FAIL: nautobot_config.py is still not readable as UID ${NAUTOBOT_UID}." >&2
        echo "" >&2
        echo "  Current state:  $(ls -l "$CONFIG_HOST_FILE")" >&2
        echo "  Without this the nautobot, celery_worker, and celery_beat" >&2
        echo "  containers will crash-loop with:" >&2
        echo "    PermissionError: [Errno 13] Permission denied: '/opt/nautobot/nautobot_config.py'" >&2
        echo "" >&2
        echo "  Fix manually and re-run:" >&2
        echo "    sudo chmod 644 '${CONFIG_HOST_FILE}'" >&2
        echo "  On SELinux-enforcing hosts you may also need:" >&2
        echo "    sudo chcon -t container_file_t '${CONFIG_HOST_FILE}'" >&2
        exit 1
    fi
fi

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
    echo "  curl -fsSLk https://localhost/health/"
else
    echo "Next steps:"
    echo "  1. Review .env and adjust NAUTOBOT_ALLOWED_HOSTS for production."
    echo "  2. Build:    docker compose build"
    echo "  3. Start:    docker compose up -d"
    echo "  Or rerun:    ./setup.sh --build --start --wait"
fi
echo ""
