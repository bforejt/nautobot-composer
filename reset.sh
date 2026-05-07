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
ALLOW_PROD_DESTROY=false
# Forwarded to setup.sh on --rebuild.  Empty arrays = use setup.sh defaults.
SETUP_VERSION_ARGS=()
SETUP_PYTHON_ARGS=()

usage() {
    cat <<EOF
Usage: $0 [--force] [--allow-production-destroy] [--rebuild [-v VERSION] [-p PYTHON]]

  --force                       Skip the standard 'type "reset" to confirm'
                                prompt.  Has NO effect on the production
                                env-name prompt — that one is unconditional.
  --allow-production-destroy    Permit reset when NAUTOBOT_ENV is 'staging' or
                                'production'.  Even with this flag, you must
                                type the env name to confirm.  Without this
                                flag, reset.sh refuses on non-lab tiers.
  --rebuild                     After reset, run 'setup.sh --build --start --wait'
                                to bring the stack back up automatically
  -v, --version VERSION         Nautobot version to rebuild against (passed to
                                setup.sh).  Only valid with --rebuild.
  -p, --python  PYTHON          Python version suffix (passed to setup.sh).
                                Only valid with --rebuild.
  -h, --help                    Show this help message

Examples:
  ./reset.sh                                   # lab: confirm, then reset
  ./reset.sh --force                           # lab: silent reset
  ./reset.sh --force --rebuild                 # lab: silent nuke + rebuild
  ./reset.sh --rebuild -v 2.4                  # lab: confirm, rebuild on 2.4
  ./reset.sh --allow-production-destroy        # production: type env-name to confirm
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
        --allow-production-destroy)
            ALLOW_PROD_DESTROY=true
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
# Read NAUTOBOT_ENV from .env (default: lab) for the environment-tier guard
# ---------------------------------------------------------------------------

NAUTOBOT_ENV_VALUE="$(grep -E '^NAUTOBOT_ENV=' "$ENV_FILE" 2>/dev/null \
    | tail -1 \
    | cut -d= -f2- \
    | tr -d '"' \
    || true)"
NAUTOBOT_ENV_VALUE="${NAUTOBOT_ENV_VALUE:-MISSING}"

case "$NAUTOBOT_ENV_VALUE" in
    lab)
        # Lab tier — proceed with the existing confirmation flow below.
        ;;
    staging|production)
        # Non-lab tier — refuse outright unless the operator passed the
        # explicit override flag.  No --force shortcut here on purpose.
        if [[ "$ALLOW_PROD_DESTROY" != true ]]; then
            echo "REFUSING: NAUTOBOT_ENV=$NAUTOBOT_ENV_VALUE — destructive operations" >&2
            echo "  blocked by default for non-lab deployments." >&2
            echo "" >&2
            echo "  If you really mean to destroy this deployment:" >&2
            echo "    1. Back up first:    ./backup.sh" >&2
            echo "    2. Re-run with:      --allow-production-destroy" >&2
            echo "       (you'll be prompted to type '$NAUTOBOT_ENV_VALUE' to confirm)" >&2
            exit 1
        fi
        # Override given.  Replace the standard 'type "reset"' prompt with a
        # stricter env-name prompt.  --force does NOT skip this — production
        # destruction is never fully non-interactive by design.
        echo "==========================================="
        echo "  WARNING: $NAUTOBOT_ENV_VALUE TIER"
        echo "==========================================="
        echo ""
        echo "All Nautobot data and the .env file will be permanently destroyed."
        echo ""
        printf 'Type %q to confirm: ' "$NAUTOBOT_ENV_VALUE"
        read -r confirm
        if [[ "$confirm" != "$NAUTOBOT_ENV_VALUE" ]]; then
            echo "Aborted."
            exit 0
        fi
        echo ""
        # Skip the standard prompt below; the env-name prompt replaces it.
        FORCE=true
        ;;
    MISSING|"")
        echo "WARNING: NAUTOBOT_ENV not set in .env — treating as 'lab'." >&2
        echo "  Set NAUTOBOT_ENV=lab|staging|production explicitly to silence." >&2
        ;;
    *)
        echo "ERROR: NAUTOBOT_ENV='$NAUTOBOT_ENV_VALUE' is not one of lab|staging|production." >&2
        exit 1
        ;;
esac

# Catch the nonsensical case of --allow-production-destroy on a lab (or
# missing) tier — the flag is only meaningful for staging/production.
# Don't error out (it's a no-op, not a hazard), but warn so the operator
# knows the flag had no effect.
if [[ "$ALLOW_PROD_DESTROY" == true && "$NAUTOBOT_ENV_VALUE" != "staging" && "$NAUTOBOT_ENV_VALUE" != "production" ]]; then
    echo "  Note: --allow-production-destroy ignored for NAUTOBOT_ENV='$NAUTOBOT_ENV_VALUE'."
fi

# ---------------------------------------------------------------------------
# Confirmation (lab tier only — non-lab uses the env-name prompt above)
# ---------------------------------------------------------------------------

if [[ "$FORCE" != true ]]; then
    echo "========================================"
    echo "  NAUTOBOT FULL RESET"
    echo "========================================"
    echo ""
    echo "This will permanently destroy:"
    echo "  - All running Nautobot containers"
    echo "  - Any container still attached to this project's volumes —"
    echo "    even from a different Compose project (force-removed)"
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

# Try the standard Compose-managed cleanup first.  Note: we deliberately do
# NOT silence stderr — if `down` hits a real error (daemon issues, etc.),
# the user should see it.  We do tolerate non-zero exit so the orphan-cleanup
# below still runs.
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down --remove-orphans || true
echo "  docker compose down complete."

# `compose down` only stops containers Docker considers part of the current
# Compose project (auto-derived from directory name or COMPOSE_PROJECT_NAME).
# Our volumes are external (intentional — they outlive `down` so data
# survives normal stack restarts).  But that same property means the volumes
# can be held by phantom containers from a previous project context: a
# different worktree, a renamed parent dir, a different shell with
# COMPOSE_PROJECT_NAME set, an older clone that's since been removed.
# Detect those phantoms before phase 2 tries to delete the volumes — that's
# what produces the otherwise-mysterious "volume is in use" error.

ORPHAN_CONTAINERS=()
for vol in "${ALL_VOLUMES[@]}"; do
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        ORPHAN_CONTAINERS+=( "$cid" )
    done < <(docker ps -aq --filter "volume=$vol" 2>/dev/null || true)
done

if [[ ${#ORPHAN_CONTAINERS[@]} -gt 0 ]]; then
    # Deduplicate (a container can mount more than one of our volumes).
    UNIQUE_ORPHANS=()
    while IFS= read -r cid; do
        [[ -n "$cid" ]] && UNIQUE_ORPHANS+=( "$cid" )
    done < <(printf '%s\n' "${ORPHAN_CONTAINERS[@]}" | sort -u)

    echo ""
    echo "  Found ${#UNIQUE_ORPHANS[@]} container(s) still attached to project volumes:"
    for cid in "${UNIQUE_ORPHANS[@]}"; do
        info="$(docker inspect "$cid" \
            --format '{{.Name}} (project={{index .Config.Labels "com.docker.compose.project"}}, image={{.Config.Image}})' \
            2>/dev/null || echo "$cid (inspect failed)")"
        echo "    $info"
    done

    if [[ "$FORCE" != true ]]; then
        echo ""
        echo "  These containers must be force-removed before the volumes can be deleted."
        printf "  Proceed? [y/N] "
        read -r orphan_confirm
        if [[ ! "$orphan_confirm" =~ ^[Yy]$ ]]; then
            echo "  Aborted by user — volumes left in place." >&2
            exit 1
        fi
    fi

    docker rm -f "${UNIQUE_ORPHANS[@]}" >/dev/null
    echo "  Force-removed ${#UNIQUE_ORPHANS[@]} container(s)."
else
    echo "  No phantom containers found on project volumes."
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
