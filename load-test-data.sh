#!/usr/bin/env bash
# =============================================================================
# load-test-data.sh — Populate Nautobot with synthetic test data
#
# Wraps the built-in `nautobot-server generate_test_data` management command
# to populate a fresh Nautobot database with synthetic devices, sites, IPs,
# etc. for demos, labs, and development against a non-empty dataset.
#
# THIS IS A FRESH-INSTALL ONLY OPERATION.
#
#   - Run it once, immediately after `./setup.sh && docker compose up -d`.
#   - It will FAIL on a database that already contains data — the seed
#     produces deterministic IDs, so a second run hits unique-constraint
#     errors on the very first table it tries to populate.
#   - Recovery from a failed second run requires dropping and recreating
#     the database (Django's flush does NOT handle Nautobot's full schema
#     reliably).  This script does not attempt that.
#
# THIS COMMAND IS NOT FOR PRODUCTION DATABASES.
#
# Usage:
#   ./load-test-data.sh                    Default seed (nautobot-lab)
#   ./load-test-data.sh --seed my-lab      Custom seed
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

SEED="nautobot-lab"

usage() {
    cat <<EOF
Usage: $0 [--seed STRING] [-h|--help]

  --seed STRING   Random seed for reproducible output (default: nautobot-lab).
                  The same seed always produces the same generated dataset,
                  but you can only load it ONCE per database.
  -h, --help      Show this help message.

This script is intended to be run a single time, immediately after a
fresh ./setup.sh + docker compose up -d.  Running it twice on the same
database will fail with unique-constraint errors.  See the script
header for details.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: --seed requires a non-empty value." >&2
                exit 1
            fi
            SEED="$2"
            shift 2
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

echo "[1/4] Preflight checks..."

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
#
# NOTE: We capture the service list and test with pure bash rather than
# piping into `grep -qx`.  Under `set -o pipefail`, a `cmd | grep -qx`
# pipeline returns SIGPIPE (141) when grep matches and exits early — the
# leading `!` then flipped 141 to 0, falsely triggering this branch even
# though the service WAS in the list.  Same root cause as the SIGPIPE
# fixes already applied to setup.sh and restore.sh.
SERVICES="$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null || true)"
if [[ $'\n'"$SERVICES"$'\n' != *$'\n'"$NAUTOBOT_SERVICE"$'\n'* ]]; then
    echo "  ERROR: service '$NAUTOBOT_SERVICE' not found in docker-compose.yml." >&2
    echo "         Available services:" >&2
    if [[ -n "$SERVICES" ]]; then
        printf '           %s\n' $SERVICES >&2
    fi
    exit 1
fi

# Verify the service is actually running.  generate_test_data needs the web
# container (with Django settings + migrations applied), not just the DB.
RUNNING="$(docker compose -f "$COMPOSE_FILE" ps --services --status=running 2>/dev/null || true)"
if [[ $'\n'"$RUNNING"$'\n' != *$'\n'"$NAUTOBOT_SERVICE"$'\n'* ]]; then
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
# Confirmation
# ---------------------------------------------------------------------------

echo ""
echo "========================================"
echo "  NAUTOBOT TEST DATA LOAD"
echo "========================================"
echo ""
echo "About to populate the database with synthetic test data:"
echo "  Compose project:  $PROJECT_NAME"
echo "  Database:         $DB_NAME"
echo "  Service:          $NAUTOBOT_SERVICE"
echo "  Seed:             $SEED"
echo ""
echo "WARNING: This is a FRESH-INSTALL OPERATION.  It must be run on a"
echo "database that has never had test data loaded into it.  Running it"
echo "a second time will fail with unique-constraint errors and leave"
echo "the database in a partially-populated state."
echo ""
echo "If this database already has data, abort now and start over with"
echo "a fresh ./reset.sh && ./setup.sh."
echo ""
read -rp "Type 'load' to confirm: " confirm
if [[ "$confirm" != "load" ]]; then
    echo "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Workaround: prune orphaned nautobot_ssot.ssotconfig content-type
# ---------------------------------------------------------------------------
# nautobot-ssot 4.2.2 (the latest release on PyPI as of this writing)
# ships an `SSoTConfig` model that registers a Django ContentType but
# whose database table is never created by any migration.  When
# generate_test_data iterates ContentType.objects.all() and calls
# .exists() on each, it crashes with:
#
#     django.db.utils.ProgrammingError: relation
#     "nautobot_ssot_ssotconfig" does not exist
#
# Django's migrate also auto-creates `auth_permission` rows (the
# default view/add/change/delete permissions) for the orphan model,
# which FK back to django_content_type.  Both must be removed in
# dependency order: permissions first, then the content-type.
#
# All deletes are scoped by a NOT EXISTS guard against the missing
# table, so if upstream eventually creates the table OR removes the
# model entirely, every WHERE clause here matches nothing and this
# block becomes a no-op.  Self-healing.  REMOVE this block once
# nautobot-ssot ships a fix and we've bumped the pin in
# requirements-3.x.txt.

echo ""
echo "[2/4] Pruning known-stale nautobot-ssot content-type (4.2.2 workaround)..."

docker compose -f "$COMPOSE_FILE" exec -T db \
    psql -U nautobot -d nautobot -v ON_ERROR_STOP=1 -q <<'SQL'
-- Capture the orphan's id (if any) and clean up dependents first.
WITH orphan AS (
    SELECT id
    FROM django_content_type
    WHERE app_label = 'nautobot_ssot'
      AND model = 'ssotconfig'
      AND NOT EXISTS (
          SELECT 1
          FROM information_schema.tables
          WHERE table_schema = 'public'
            AND table_name = 'nautobot_ssot_ssotconfig'
      )
)
DELETE FROM auth_permission
WHERE content_type_id IN (SELECT id FROM orphan);

DELETE FROM django_content_type
WHERE app_label = 'nautobot_ssot'
  AND model = 'ssotconfig'
  AND NOT EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = 'nautobot_ssot_ssotconfig'
  );
SQL

# ---------------------------------------------------------------------------
# Run generate_test_data
# ---------------------------------------------------------------------------

echo ""
echo "[3/4] Running nautobot-server generate_test_data..."

# -T disables TTY allocation so the command works in non-interactive contexts.
# --no-input is the Django-side flag that suppresses the management command's
# own internal prompts (independent of our wrapper-level prompt above).
docker compose -f "$COMPOSE_FILE" exec -T "$NAUTOBOT_SERVICE" \
    nautobot-server generate_test_data --no-input --seed "$SEED"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "[4/4] Done."
echo ""
echo "  Test data loaded successfully."
echo "  Seed used: $SEED"
