#!/usr/bin/env bash
# =============================================================================
# load-test-data.sh — Populate Nautobot with synthetic test data
#
# Wraps the built-in `nautobot-server generate_test_data` management command.
# Uses a fixed seed by default so the generated dataset is reproducible.
#
# Without --flush, generated data is added on top of whatever already exists
# in the database.  With --flush, the database is wiped first.
#
# THIS COMMAND IS NOT FOR PRODUCTION DATABASES.  --flush will delete data.
#
# Usage:
#   ./load-test-data.sh                    Additive load with default seed
#   ./load-test-data.sh --flush            Wipe DB, prompt, then load
#   ./load-test-data.sh --flush --yes      Wipe DB, no prompt (CI/scripted)
#   ./load-test-data.sh --seed my-lab      Custom seed (any string)
# =============================================================================

set -euo pipefail

trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# Canonical name of the Nautobot web service in docker-compose.yml.  Verified
# at runtime against `docker compose config --services` so that renames are
# detected rather than silently misbehaving.
NAUTOBOT_SERVICE="nautobot"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

FLUSH=false
SKIP_CONFIRM=false
SEED="nautobot-lab"

usage() {
    cat <<EOF
Usage: $0 [--flush] [--seed STRING] [--yes] [-h|--help]

  --flush         Clear all existing data before generating.  DESTRUCTIVE.
  --seed STRING   Random seed for reproducible output (default: nautobot-lab).
                  Re-running with the same seed produces the same dataset.
  --yes           Skip the confirmation prompt (for non-interactive use).
                  Only meaningful with --flush.
  -h, --help      Show this help message.

Without --flush, the command runs ADDITIVELY against whatever data is
already in the database.  Repeated runs without --flush will accumulate
records — use --flush when you want a clean baseline.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flush)
            FLUSH=true
            shift
            ;;
        --seed)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: --seed requires a non-empty value." >&2
                exit 1
            fi
            SEED="$2"
            shift 2
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
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

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo "[1/3] Preflight checks..."

if ! command -v docker &>/dev/null; then
    echo "  ERROR: docker is not installed or not in PATH." >&2
    exit 1
fi
echo "  docker:   $(docker --version)"

if ! docker compose version &>/dev/null; then
    echo "  ERROR: 'docker compose' (Compose V2) is not available." >&2
    exit 1
fi
echo "  compose:  $(docker compose version --short)"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "  ERROR: .env not found at $ENV_FILE" >&2
    echo "         Run ./setup.sh first." >&2
    exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "  ERROR: docker-compose.yml not found at $COMPOSE_FILE" >&2
    exit 1
fi

# Verify the Nautobot service exists in the compose file.  Renaming the
# service in docker-compose.yml without updating this script would silently
# fail without this check.
if ! docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null \
        | grep -qx "$NAUTOBOT_SERVICE"; then
    echo "  ERROR: service '$NAUTOBOT_SERVICE' not found in docker-compose.yml." >&2
    echo "         Available services:" >&2
    docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null \
        | sed 's/^/           /' >&2 || true
    exit 1
fi

# Verify the service is actually running.  generate_test_data needs the web
# container (with Django settings + migrations applied), not just the DB.
if ! docker compose -f "$COMPOSE_FILE" ps --services --status=running 2>/dev/null \
        | grep -qx "$NAUTOBOT_SERVICE"; then
    echo "  ERROR: service '$NAUTOBOT_SERVICE' is not running." >&2
    echo "         Start the stack first:" >&2
    echo "           ./setup.sh    # if .env / volumes don't exist yet" >&2
    echo "           docker compose up -d" >&2
    exit 1
fi
echo "  service:  $NAUTOBOT_SERVICE (running)"

# ---------------------------------------------------------------------------
# Resolve project context for the confirmation prompt
# ---------------------------------------------------------------------------

# Compose project name — same derivation as setup.sh / reset.sh.
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"

# Database name from .env (NAUTOBOT_DB_NAME), falling back to the documented
# default if the variable isn't set.
DB_NAME="$(grep -E '^NAUTOBOT_DB_NAME=' "$ENV_FILE" 2>/dev/null \
    | tail -1 \
    | cut -d= -f2- \
    || true)"
DB_NAME="${DB_NAME:-nautobot}"

# ---------------------------------------------------------------------------
# Confirmation (only when --flush)
# ---------------------------------------------------------------------------

if [[ "$FLUSH" == true && "$SKIP_CONFIRM" != true ]]; then
    echo ""
    echo "========================================"
    echo "  NAUTOBOT TEST DATA — FLUSH AND LOAD"
    echo "========================================"
    echo ""
    echo "This will WIPE the following before loading test data:"
    echo "  Compose project:  $PROJECT_NAME"
    echo "  Database:         $DB_NAME"
    echo "  Service:          $NAUTOBOT_SERVICE"
    echo ""
    echo "Seed: $SEED"
    echo ""
    echo "ALL EXISTING NAUTOBOT DATA IN THIS DATABASE WILL BE LOST."
    echo ""
    read -rp "Type 'flush' to confirm: " confirm
    if [[ "$confirm" != "flush" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Run generate_test_data
# ---------------------------------------------------------------------------

echo ""
echo "[2/3] Running nautobot-server generate_test_data..."

ARGS=(generate_test_data --no-input --seed "$SEED")
if [[ "$FLUSH" == true ]]; then
    ARGS=(generate_test_data --flush --no-input --seed "$SEED")
fi

# -T disables TTY allocation so the command works in non-interactive contexts
# (CI, piping, etc.).  Stdout from the management command goes straight to the
# user's terminal so they see Nautobot's progress output in real time.
docker compose -f "$COMPOSE_FILE" exec -T "$NAUTOBOT_SERVICE" \
    nautobot-server "${ARGS[@]}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "[3/3] Done."
echo ""
if [[ "$FLUSH" == true ]]; then
    echo "  Database flushed and re-populated with test data."
else
    echo "  Test data added to existing database."
fi
echo "  Seed used: $SEED"
echo ""
echo "  Re-running with the same seed reproduces the same dataset:"
echo "    ./load-test-data.sh --flush --seed \"$SEED\""
