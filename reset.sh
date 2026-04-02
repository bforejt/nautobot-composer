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

for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --rebuild) REBUILD=true ;;
        --help|-h)
            echo "Usage: $0 [--force] [--rebuild]"
            echo ""
            echo "  --force    Skip confirmation prompt"
            echo "  --rebuild  After reset, run setup.sh to reinitialize"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--force] [--rebuild]" >&2
            exit 1
            ;;
    esac
done

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
    echo "Running setup.sh to reinitialize..."
    echo ""
    exec "${SCRIPT_DIR}/setup.sh"
else
    echo ""
    echo "To reinitialize:"
    echo "  ./setup.sh"
    echo "  docker compose build"
    echo "  docker compose up -d"
fi
