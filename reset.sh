#!/usr/bin/env bash
# =============================================================================
# reset.sh — Fully reset the Nautobot Docker Compose project
#
# Stops all containers, removes ALL project volumes — the core stack plus the
# opt-in GitLab, firmware, answer-service, and tacacs add-ons — deletes the
# .env file, and removes built images.  A full reset is the DEFAULT; use the
# --keep-* switches to exclude an add-on's containers/volumes or the .env file
# from the wipe.
#
# THIS IS DESTRUCTIVE — all Nautobot, GitLab, firmware, answer-service, and
# tacacs data will be lost (minus whatever --keep-* flags exclude).
#
# Usage:
#   ./reset.sh                  Interactive — prompts for confirmation
#   ./reset.sh --force          Skip confirmation prompt
#   ./reset.sh --rebuild        Reset and immediately re-run setup.sh
#   ./reset.sh --keep-gitlab    Reset, but leave GitLab containers + data
#   ./reset.sh --keep-firmware  Reset, but leave the firmware server + images
#   ./reset.sh --keep-answer-service
#                               Reset, but leave the answer service + data
#   ./reset.sh --keep-env       Reset, but keep .env (secrets, profiles)
#   ./reset.sh --dry-run        Show what would be removed/kept, change nothing
# =============================================================================

set -euo pipefail

trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Compose project name — used to name Compose-managed volumes/images and to
# scope the image cleanup below.  Mirrors setup.sh: honor COMPOSE_PROJECT_NAME
# if set, otherwise derive it from the directory name the same way Compose does.
# IMPORTANT: if you ran the stack with a custom COMPOSE_PROJECT_NAME, set the
# same value when running reset.sh, or the project-prefixed (firmware,
# answer-service) volumes below won't match and will be skipped.
PROJECT_DIR="$(basename "$SCRIPT_DIR")"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(echo "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')}"

# Every volume the project can create, grouped by what owns it, so a reset
# wipes the ENTIRE project by default and the --keep-* switches can exclude
# an add-on's group.  Two naming schemes are in play:
#   * external volumes (created by setup.sh) use their exact names, no prefix;
#   * Compose-managed volumes (the firmware and answer-service add-ons) are
#     project-prefixed by Compose, e.g. "<project>_nautobot_firmware".
# Volumes that don't exist are skipped (see phase [2/4]), so listing ones the
# user never created is harmless.
CORE_VOLUMES=(
    # Core stack (external).  Jobs are a bind mount (./jobs), not a volume.
    "nautobot_media"
    "nautobot_git"
    "nautobot_postgres_data"
    "nautobot_redis_data"
)
GITLAB_VOLUMES=(
    # GitLab — opt-in profile (external)
    "gitlab_config"
    "gitlab_logs"
    "gitlab_data"
)
FIRMWARE_VOLUMES=(
    # Firmware server — opt-in profile (Compose-managed, project-prefixed)
    "${PROJECT_NAME}_nautobot_firmware"
    "${PROJECT_NAME}_nautobot_firmware_db"
)
ANSWER_VOLUMES=(
    # NFV answer service — opt-in profile (Compose-managed, project-prefixed).
    # One-time install keys + archived install reports.  The service's other
    # durable state (./secrets/nodes/, ./answer-service/certs/) lives in host
    # bind mounts, which reset never touches.
    "${PROJECT_NAME}_nautobot_answer_data"
)
TACACS_VOLUMES=(
    # TACACS+ server — opt-in profile (Compose-managed, project-prefixed).
    # Rendered last-good config + accounting logs.  Per-device key files live
    # in the ./secrets bind mount, which reset never touches.
    "${PROJECT_NAME}_nautobot_tacacs"
)
# ALL_VOLUMES / KEPT_VOLUMES are assembled after argument parsing, once the
# --keep-* switches are known.

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

FORCE=false
REBUILD=false
ALLOW_PROD_DESTROY=false
KEEP_GITLAB=false
KEEP_FIRMWARE=false
KEEP_ANSWER_SERVICE=false
KEEP_TACACS=false
KEEP_ENV=false
DRY_RUN=false
# Forwarded to setup.sh on --rebuild.  Empty arrays = use setup.sh defaults.
SETUP_VERSION_ARGS=()
SETUP_PYTHON_ARGS=()

usage() {
    cat <<EOF
Usage: $0 [--force] [--keep-gitlab] [--keep-firmware] [--keep-answer-service]
          [--keep-tacacs] [--keep-env] [--dry-run]
          [--allow-production-destroy] [--rebuild [-v VERSION] [-p PYTHON]]

  --force                       Skip the standard 'type "reset" to confirm'
                                prompt.  Has NO effect on the production
                                env-name prompt — that one is unconditional.
  --keep-gitlab                 Leave the GitLab add-on alone: its container
                                keeps running and gitlab_config/logs/data
                                volumes are not removed.
  --keep-firmware               Leave the firmware add-on alone: its containers
                                keep running, the nautobot_firmware* volumes
                                and the built firmware-download image survive.
                                NOTE: unless you also pass --keep-env, the
                                regenerated .env gets a NEW firmware admin
                                password that the surviving Filebrowser DB
                                does not know — the OLD password stays valid.
  --keep-answer-service         Leave the answer-service add-on alone: its
                                container keeps running, the
                                nautobot_answer_data volume (one-time install
                                keys, install reports) and built image
                                survive.  Host bind mounts (./secrets,
                                ./answer-service/certs) are never touched by
                                reset either way.
                                NOTE: the core reset wipes Nautobot's DB, so
                                the kept container's ANSWER_NAUTOBOT_TOKEN is
                                stale — set a fresh token in .env and restart
                                the service after the rebuild.
  --keep-tacacs                 Leave the TACACS+ add-on alone: its container
                                keeps running, the nautobot_tacacs volume
                                (rendered config, accounting logs) and built
                                image survive.  Per-device key files live in
                                the ./secrets/tacacs bind mount, never touched
                                by reset either way.
                                NOTE: without --keep-env, the regenerated .env
                                gets a NEW TACACS_DEFAULT_KEY (the kept
                                container keeps serving the OLD key until it is
                                recreated — re-sync device configs first) AND a
                                stale TACACS_NAUTOBOT_TOKEN, since the core
                                reset wipes Nautobot's DB: set a fresh token in
                                .env and recreate the container to resume
                                Nautobot reconciliation.
  --keep-env                    Keep the .env file (secrets, passwords,
                                COMPOSE_PROFILES selection).
  --dry-run                     Print what would be stopped/removed/kept and
                                exit without changing anything.  Skips all
                                confirmation prompts; ignores --rebuild.
  --allow-production-destroy    Permit reset when NAUTOBOT_ENV is 'staging' or
                                'production'.  Even with this flag, you must
                                type the env name to confirm.  Without this
                                flag, reset.sh refuses on non-lab tiers.
  --rebuild                     After reset, run 'setup.sh --build --start --wait'
                                to bring the stack back up automatically.
                                Profiles enabled in the old .env are re-enabled
                                (forwarded to setup.sh as --with-* flags).
  -v, --version VERSION         Nautobot version to rebuild against (passed to
                                setup.sh).  Only valid with --rebuild.
  -p, --python  PYTHON          Python version suffix (passed to setup.sh).
                                Only valid with --rebuild.
  -h, --help                    Show this help message

Examples:
  ./reset.sh                                   # lab: confirm, then full reset
  ./reset.sh --force                           # lab: silent full reset
  ./reset.sh --force --rebuild                 # lab: silent nuke + rebuild
  ./reset.sh --rebuild -v 2.4                  # lab: confirm, rebuild on 2.4
  ./reset.sh --keep-firmware --keep-env        # reset core, keep firmware + secrets
  ./reset.sh --dry-run --keep-gitlab           # preview a GitLab-sparing reset
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
        --keep-gitlab)
            KEEP_GITLAB=true
            shift
            ;;
        --keep-firmware)
            KEEP_FIRMWARE=true
            shift
            ;;
        --keep-answer-service)
            KEEP_ANSWER_SERVICE=true
            shift
            ;;
        --keep-tacacs)
            KEEP_TACACS=true
            shift
            ;;
        --keep-env)
            KEEP_ENV=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
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
# Assemble the deletion scope from the --keep-* switches
# ---------------------------------------------------------------------------

# Volumes to remove (phase 2) — also drives the phantom-container sweep in
# phase 1: containers attached only to kept volumes are never scanned, so
# kept add-ons keep running through the reset.
ALL_VOLUMES=( "${CORE_VOLUMES[@]}" )
KEPT_SUMMARY=()

if [[ "$KEEP_GITLAB" == true ]]; then
    KEPT_SUMMARY+=( "GitLab add-on (container + volumes: ${GITLAB_VOLUMES[*]})" )
else
    ALL_VOLUMES+=( "${GITLAB_VOLUMES[@]}" )
fi

if [[ "$KEEP_FIRMWARE" == true ]]; then
    KEPT_SUMMARY+=( "Firmware add-on (containers, volumes: ${FIRMWARE_VOLUMES[*]}, built image)" )
else
    ALL_VOLUMES+=( "${FIRMWARE_VOLUMES[@]}" )
fi

if [[ "$KEEP_ANSWER_SERVICE" == true ]]; then
    KEPT_SUMMARY+=( "Answer-service add-on (container, volume: ${ANSWER_VOLUMES[*]}, built image)" )
else
    ALL_VOLUMES+=( "${ANSWER_VOLUMES[@]}" )
fi

if [[ "$KEEP_TACACS" == true ]]; then
    KEPT_SUMMARY+=( "TACACS+ add-on (container, volume: ${TACACS_VOLUMES[*]}, built image)" )
else
    ALL_VOLUMES+=( "${TACACS_VOLUMES[@]}" )
fi

if [[ "$KEEP_ENV" == true ]]; then
    KEPT_SUMMARY+=( ".env file (secrets, COMPOSE_PROFILES)" )
fi

# Profiles handed to `docker compose down` in phase 1.  Non-kept profiles are
# activated explicitly so their containers are stopped even if COMPOSE_PROFILES
# in .env doesn't list them (ad-hoc `--profile X up` starts).  Kept profiles
# are omitted — and because an explicit COMPOSE_PROFILES env var overrides the
# .env file, `down` won't touch them even when .env enables them.
DOWN_PROFILES=()
[[ "$KEEP_GITLAB"         != true ]] && DOWN_PROFILES+=( gitlab )
[[ "$KEEP_FIRMWARE"       != true ]] && DOWN_PROFILES+=( firmware )
[[ "$KEEP_ANSWER_SERVICE" != true ]] && DOWN_PROFILES+=( answer-service )
[[ "$KEEP_TACACS"         != true ]] && DOWN_PROFILES+=( tacacs )
DOWN_PROFILES_CSV="$(IFS=,; echo "${DOWN_PROFILES[*]-}")"

if [[ "$DRY_RUN" == true ]]; then
    echo "==========================================="
    echo "  DRY RUN — nothing will be changed"
    echo "==========================================="
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
        # Dry-run is read-only, so previewing is allowed on any tier.
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Note: NAUTOBOT_ENV=$NAUTOBOT_ENV_VALUE — a real reset requires --allow-production-destroy."
        # Non-lab tier — refuse outright unless the operator passed the
        # explicit override flag.  No --force shortcut here on purpose.
        elif [[ "$ALLOW_PROD_DESTROY" != true ]]; then
            echo "REFUSING: NAUTOBOT_ENV=$NAUTOBOT_ENV_VALUE — destructive operations" >&2
            echo "  blocked by default for non-lab deployments." >&2
            echo "" >&2
            echo "  If you really mean to destroy this deployment:" >&2
            echo "    1. Back up first:    ./backup.sh" >&2
            echo "    2. Re-run with:      --allow-production-destroy" >&2
            echo "       (you'll be prompted to type '$NAUTOBOT_ENV_VALUE' to confirm)" >&2
            exit 1
        else
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
        fi
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

if [[ "$FORCE" != true && "$DRY_RUN" != true ]]; then
    echo "========================================"
    echo "  NAUTOBOT FULL RESET"
    echo "========================================"
    echo ""
    echo "This will permanently destroy:"
    echo "  - All running Nautobot containers"
    echo "  - Any container still attached to this project's volumes —"
    echo "    even from a different Compose project (force-removed)"
    echo "  - These Docker volumes:"
    for vol in "${ALL_VOLUMES[@]}"; do
        echo "      $vol"
    done
    if [[ "$KEEP_ENV" != true ]]; then
        echo "  - The .env file (secrets, passwords, API tokens)"
    fi
    echo "  - Locally built Nautobot images"
    if [[ ${#KEPT_SUMMARY[@]} -gt 0 ]]; then
        echo ""
        echo "KEPT (per --keep-* flags):"
        for item in "${KEPT_SUMMARY[@]}"; do
            echo "  - $item"
        done
    fi
    echo ""
    echo "ALL OTHER NAUTOBOT DATA WILL BE LOST."
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
#
# COMPOSE_PROFILES is passed explicitly (overriding any value in .env) so
# that non-kept add-on profiles are always brought down, while kept ones are
# invisible to `down` even when .env enables them.  --remove-orphans (which
# would also remove kept-profile containers as strays) is only safe when
# nothing is being kept.
DOWN_ARGS=( -f "${SCRIPT_DIR}/docker-compose.yml" down )
if [[ "$KEEP_GITLAB" != true && "$KEEP_FIRMWARE" != true \
    && "$KEEP_ANSWER_SERVICE" != true && "$KEEP_TACACS" != true ]]; then
    DOWN_ARGS+=( --remove-orphans )
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "  (dry-run) would run: COMPOSE_PROFILES='${DOWN_PROFILES_CSV}' docker compose ${DOWN_ARGS[*]}"
else
    COMPOSE_PROFILES="$DOWN_PROFILES_CSV" docker compose "${DOWN_ARGS[@]}" || true
    echo "  docker compose down complete."
fi

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

    if [[ "$DRY_RUN" == true ]]; then
        echo "  (dry-run) would force-remove the ${#UNIQUE_ORPHANS[@]} container(s) above."
    else
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
    fi
else
    echo "  No phantom containers found on project volumes."
fi

# The Compose network can linger when `down` ran while opt-in profile
# containers (gitlab/firmware/answer-service) were still attached — `down` cannot remove an
# in-use network, and the orphan sweep above removes containers but not
# networks.  Now that all project containers are gone, remove it best-effort so
# nothing is left behind.  Harmless if it was already removed or never created;
# Compose recreates it on the next `up`.
NETWORK="${PROJECT_NAME}_default"
if docker network inspect "$NETWORK" &>/dev/null; then
    if [[ "$DRY_RUN" == true ]]; then
        echo "  (dry-run) would remove project network: $NETWORK (best-effort)"
    elif docker network rm "$NETWORK" &>/dev/null; then
        echo "  Removed project network: $NETWORK"
    else
        # Expected when --keep-* left add-on containers running on it.
        echo "  Note: could not remove network $NETWORK (still in use?) — skipped."
    fi
fi

# ---------------------------------------------------------------------------
# Remove project volumes (core + opt-in GitLab/firmware/answer-service/tacacs)
# ---------------------------------------------------------------------------

echo ""
echo "[2/4] Removing Docker volumes..."

for vol in "${ALL_VOLUMES[@]}"; do
    if docker volume inspect "$vol" &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "  $vol — would be removed"
        else
            docker volume rm "$vol" >/dev/null
            echo "  $vol — removed"
        fi
    else
        echo "  $vol — not found (skipped)"
    fi
done
if [[ "$KEEP_GITLAB" == true ]]; then
    for vol in "${GITLAB_VOLUMES[@]}"; do
        echo "  $vol — kept (--keep-gitlab)"
    done
fi
if [[ "$KEEP_FIRMWARE" == true ]]; then
    for vol in "${FIRMWARE_VOLUMES[@]}"; do
        echo "  $vol — kept (--keep-firmware)"
    done
fi
if [[ "$KEEP_ANSWER_SERVICE" == true ]]; then
    for vol in "${ANSWER_VOLUMES[@]}"; do
        echo "  $vol — kept (--keep-answer-service)"
    done
fi
if [[ "$KEEP_TACACS" == true ]]; then
    for vol in "${TACACS_VOLUMES[@]}"; do
        echo "  $vol — kept (--keep-tacacs)"
    done
fi

# ---------------------------------------------------------------------------
# Remove .env file
# ---------------------------------------------------------------------------

echo ""
echo "[3/4] Removing .env file..."

# Capture the profile selection BEFORE .env is deleted so --rebuild can
# re-enable the same add-ons via setup.sh --with-* flags.
PREV_PROFILES="$(grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '" ' || true)"
SETUP_PROFILE_ARGS=()
[[ ",${PREV_PROFILES}," == *,gitlab,*         ]] && SETUP_PROFILE_ARGS+=( --with-gitlab )
[[ ",${PREV_PROFILES}," == *,firmware,*       ]] && SETUP_PROFILE_ARGS+=( --with-firmware )
[[ ",${PREV_PROFILES}," == *,answer-service,* ]] && SETUP_PROFILE_ARGS+=( --with-answer-service )
[[ ",${PREV_PROFILES}," == *,tacacs,*         ]] && SETUP_PROFILE_ARGS+=( --with-tacacs )

if [[ "$KEEP_ENV" == true ]]; then
    echo "  $ENV_FILE — kept (--keep-env)"
elif [[ ! -f "$ENV_FILE" ]]; then
    echo "  .env not found (skipped)"
elif [[ "$DRY_RUN" == true ]]; then
    echo "  $ENV_FILE — would be removed"
else
    rm "$ENV_FILE"
    echo "  $ENV_FILE — removed"
    if [[ "$KEEP_FIRMWARE" == true ]]; then
        echo ""
        echo "  NOTE: --keep-firmware preserved the Filebrowser database, which still"
        echo "        holds the OLD firmware admin password.  The password in a freshly"
        echo "        generated .env will NOT be applied to the existing database."
        echo "        Keep using the old credentials, or remove the"
        echo "        ${PROJECT_NAME}_nautobot_firmware_db volume to re-bootstrap."
    fi
fi

# ---------------------------------------------------------------------------
# Remove built images
# ---------------------------------------------------------------------------

echo ""
echo "[4/4] Removing built images..."

# Compose-built images follow the pattern: <project>-<service>.  This includes
# the firmware-download and answer-service images (built from their in-repo
# Dockerfiles), which have no explicit image: name and so are tagged
# <project>-firmware-download / <project>-answer-service — each kept back from
# the sweep under its --keep-* flag, since a kept-but-imageless add-on couldn't
# restart after an image prune.  PROJECT_NAME is computed once at the top of
# this script.
IMAGE_IDS=()
while IFS=' ' read -r repo id; do
    [[ -z "$id" ]] && continue
    if [[ "$KEEP_FIRMWARE" == true && "$repo" == "${PROJECT_NAME}-firmware-download" ]]; then
        echo "  $repo — kept (--keep-firmware)"
        continue
    fi
    if [[ "$KEEP_ANSWER_SERVICE" == true && "$repo" == "${PROJECT_NAME}-answer-service" ]]; then
        echo "  $repo — kept (--keep-answer-service)"
        continue
    fi
    if [[ "$KEEP_TACACS" == true && "$repo" == "${PROJECT_NAME}-tacacs" ]]; then
        echo "  $repo — kept (--keep-tacacs)"
        continue
    fi
    IMAGE_IDS+=( "$id" )
done < <(docker images --filter "reference=${PROJECT_NAME}-*" --format '{{.Repository}} {{.ID}}' 2>/dev/null || true)

if [[ ${#IMAGE_IDS[@]} -gt 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        echo "  (dry-run) would remove ${#IMAGE_IDS[@]} image(s) for project: $PROJECT_NAME"
    else
        docker rmi "${IMAGE_IDS[@]}" 2>/dev/null || true
        echo "  Removed images for project: $PROJECT_NAME"
    fi
else
    echo "  No project images found (skipped)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete — nothing was changed."
    if [[ "$REBUILD" == true ]]; then
        echo "  Note: --rebuild ignored in dry-run mode."
    fi
    exit 0
fi
echo "Reset complete."

if [[ "$REBUILD" == true ]]; then
    echo ""
    # Use ${arr[*]:-} for the display, and the ${arr[@]+"${arr[@]}"} idiom for
    # the exec.  Older bash (e.g. macOS's bundled 3.2) treats expansion of an
    # empty array under `set -u` as an unbound-variable error; both forms above
    # are bash 3.2-safe and emit nothing when the array is empty.
    # SETUP_PROFILE_ARGS re-enables the profiles captured from the old .env
    # (harmlessly redundant with --keep-env, where .env still has them).
    echo "Running setup.sh ${SETUP_VERSION_ARGS[*]:-} ${SETUP_PYTHON_ARGS[*]:-} ${SETUP_PROFILE_ARGS[*]:-} --build --start --wait..."
    echo ""
    exec "${SCRIPT_DIR}/setup.sh" \
        ${SETUP_VERSION_ARGS[@]+"${SETUP_VERSION_ARGS[@]}"} \
        ${SETUP_PYTHON_ARGS[@]+"${SETUP_PYTHON_ARGS[@]}"} \
        ${SETUP_PROFILE_ARGS[@]+"${SETUP_PROFILE_ARGS[@]}"} \
        --build --start --wait
else
    echo ""
    echo "To reinitialize:"
    echo "  ./setup.sh --build --start --wait"
fi
