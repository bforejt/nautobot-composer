#!/usr/bin/env bash
# =============================================================================
# reset.sh — Fully reset the Nautobot Docker Compose project
#
# Stops all containers, removes external volumes (including the PostgreSQL
# database), deletes the .env file, and removes built images.
#
# THIS IS DESTRUCTIVE — all Nautobot data will be lost.
#
# Usage:
#   ./reset.sh            Interactive — prompts for confirmation
#   ./reset.sh --force    Skip confirmation prompt
#   ./reset.sh --rebuild  Reset and immediately re-run setup.sh
# =============================================================================

set -euo pipefail

trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Volume names — must match setup.sh and docker-compose.yml.
ALL_VOLUMES=(
    "nautobot_media"
    "nautobot_git"
    "nautobot_jobs"
    "nautobot_postgres_data"
    "nautobot_redis_data"
)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

FORCE=false
REBUILD=false
# Forwarded to setup.sh on --rebuild.  Empty arrays = use setup.sh defaults.
SETUP_VERSION_ARGS=()
SETUP_PYTHON_ARGS=()

usage() {
    cat <<EOF
Usage: $0 [--force] [--rebuild [-v VERSION] [-p PYTHON]]

  --force                 Skip confirmation prompt
  --rebuild               After reset, run 'setup.sh --build --start --wait'
                          to bring the stack back up automatically
  -v, --version VERSION   Nautobot version to rebuild against (passed to
                          setup.sh).  Only valid with --rebuild.
  -p, --python  PYTHON    Python version suffix (passed to setup.sh).
                          Only valid with --rebuild.
  -h, --help              Show this help message

Examples:
  ./reset.sh                              # confirm, then reset only
  ./reset.sh --force                      # silent reset
  ./reset.sh --force --rebuild            # silent nuke + rebuild on default version
  ./reset.sh --rebuild -v 2.4             # confirm, then rebuild on Nautobot 2.4
  ./reset.sh --force --rebuild -v 3.0     # silent nuke + rebuild on 3.0
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        --rebuild)
            REBUILD=true
            shift
            ;;
        -v|--version)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: $1 requires a non-empty value." >&2
                exit 1
            fi
            SETUP_VERSION_ARGS=( -v "$2" )
            shift 2
            ;;
        -p|--python)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: $1 requires a non-empty value." >&2
                exit 1
            fi
            SETUP_PYTHON_ARGS=( -p "$2" )
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# -v / -p only make sense when we're going to invoke setup.sh.  Catch the
# nonsensical combo early rather than silently ignoring the flags.
if [[ "$REBUILD" != true ]]; then
    if [[ ${#SETUP_VERSION_ARGS[@]} -gt 0 || ${#SETUP_PYTHON_ARGS[@]} -gt 0 ]]; then
        echo "ERROR: -v and -p are only meaningful with --rebuild." >&2
        usage >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed or not in PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ "$FORCE" != true ]]; then
    echo "========================================"
    echo "  NAUTOBOT FULL RESET"
    echo "========================================"
    echo ""
    echo "This will permanently destroy:"
    echo "  - All running Nautobot containers"
    echo "  - All Docker volumes (DATABASE, Redis, media, git, jobs)"
    echo "  - The .env file (secrets, passwords, API tokens)"
    echo "  - Locally built Nautobot images"
    echo ""
    echo "ALL NAUTOBOT DATA WILL BE LOST."
    echo ""
    read -rp "Type 'reset' to confirm: " confirm
    if [[ "$confirm" != "reset" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Stop and remove containers
# ---------------------------------------------------------------------------

echo "[1/4] Stopping containers..."

if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps -q &>/dev/null; then
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
    echo "  Containers stopped and removed."
else
    echo "  No running containers found."
fi

# ---------------------------------------------------------------------------
# Remove external volumes
# ---------------------------------------------------------------------------

echo ""
echo "[2/4] Removing Docker volumes..."

for vol in "${ALL_VOLUMES[@]}"; do
    if docker volume inspect "$vol" &>/dev/null; then
        docker volume rm "$vol" >/dev/null
        echo "  $vol — removed"
    else
        echo "  $vol — not found (skipped)"
    fi
done

# ---------------------------------------------------------------------------
# Remove .env file
# ---------------------------------------------------------------------------

echo ""
echo "[3/4] Removing .env file..."

if [[ -f "$ENV_FILE" ]]; then
    rm "$ENV_FILE"
    echo "  $ENV_FILE — removed"
else
    echo "  .env not found (skipped)"
fi

# ---------------------------------------------------------------------------
# Remove built images
# ---------------------------------------------------------------------------

echo ""
echo "[4/4] Removing built images..."

# Compose-built images follow the pattern: <project>-<service>
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

IMAGES=$(docker images --filter "reference=${PROJECT_NAME}-*" -q 2>/dev/null || true)
if [[ -n "$IMAGES" ]]; then
    docker rmi $IMAGES 2>/dev/null || true
    echo "  Removed images for project: $PROJECT_NAME"
else
    echo "  No project images found (skipped)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Reset complete."

if [[ "$REBUILD" == true ]]; then
    echo ""
    echo "Running setup.sh ${SETUP_VERSION_ARGS[*]} ${SETUP_PYTHON_ARGS[*]} --build --start --wait..."
    echo ""
    exec "${SCRIPT_DIR}/setup.sh" \
        "${SETUP_VERSION_ARGS[@]}" \
        "${SETUP_PYTHON_ARGS[@]}" \
        --build --start --wait
else
    echo ""
    echo "To reinitialize:"
    echo "  ./setup.sh --build --start --wait"
fi
