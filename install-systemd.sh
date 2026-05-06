#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — Install (or uninstall) the Nautobot Compose stack
# as a systemd service on Linux.
#
# This is opt-in.  The Compose stack already survives reboots on its own
# via `restart: unless-stopped` in docker-compose.yml.  Use this script
# only if you want `systemctl` ergonomics: unified start/stop, journald
# integration for wrapper-level events, and ordering against other system
# units.
#
# Renders the template at systemd/nautobot-composer.service with the
# correct WorkingDirectory and installs it to /etc/systemd/system/.
#
# Usage:
#   sudo ./install-systemd.sh                 Install pointing at the
#                                             script's own directory.
#   sudo ./install-systemd.sh --path /opt/nautobot-composer
#                                             Install pointing somewhere
#                                             else (must contain
#                                             docker-compose.yml).
#   sudo ./install-systemd.sh --no-enable     Install but don't
#                                             enable --now.
#   sudo ./install-systemd.sh --uninstall     Stop, disable, remove unit.
#   ./install-systemd.sh -h | --help          Usage.
# =============================================================================

set -euo pipefail

trap 'echo "ERROR: Script failed at line $LINENO.  Exit code: $?" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/systemd/nautobot-composer.service"

UNIT_NAME="nautobot-composer.service"
UNIT_DEST="/etc/systemd/system/${UNIT_NAME}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

INSTALL_PATH="$SCRIPT_DIR"
ACTION="install"
ENABLE_NOW=true

usage() {
    cat <<EOF
Usage: sudo $0 [--path PATH] [--no-enable] [--uninstall] [-h|--help]

  --path PATH    Directory the unit's WorkingDirectory should point to.
                 Must contain docker-compose.yml.  Default: the script's
                 own directory ($SCRIPT_DIR).
  --no-enable    Install the unit but do not 'systemctl enable --now'.
                 Use this if you want to inspect before activating.
  --uninstall    Stop, disable, and remove the unit from
                 /etc/systemd/system/.  --path is ignored.
  -h, --help     Show this help message.

Examples:
  # Install the unit pointing at the current project directory
  sudo $0

  # Copy the project to /opt first, then install pointing there
  sudo cp -r . /opt/nautobot-composer
  cd /opt/nautobot-composer
  sudo ./install-systemd.sh

  # Remove the unit
  sudo $0 --uninstall
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: --path requires a non-empty value." >&2
                exit 1
            fi
            INSTALL_PATH="$(cd "$2" && pwd)" || {
                echo "ERROR: --path '$2' does not exist or is not readable." >&2
                exit 1
            }
            shift 2
            ;;
        --no-enable)
            ENABLE_NOW=false
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
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
# Preflight checks (apply to both install and uninstall)
# ---------------------------------------------------------------------------

echo "[1/3] Preflight checks..."

# OS
case "$(uname -s)" in
    Linux) ;;
    *)
        echo "  ERROR: this installer is Linux-only." >&2
        echo "         macOS / Windows users should rely on Docker Desktop's" >&2
        echo "         'Start when you sign in' setting instead." >&2
        exit 1
        ;;
esac

# systemd present
if ! command -v systemctl &>/dev/null; then
    echo "  ERROR: systemctl not found.  This system does not appear to use systemd." >&2
    exit 1
fi
if [[ ! -d /run/systemd/system ]]; then
    echo "  ERROR: /run/systemd/system not present.  This system does not appear to" >&2
    echo "         be running systemd as PID 1." >&2
    exit 1
fi

# Root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "  ERROR: must be run as root.  Re-run with sudo:" >&2
    echo "           sudo $0 $*" >&2
    exit 1
fi

echo "  os:       Linux + systemd"
echo "  user:     root"
echo "  action:   $ACTION"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ "$ACTION" == "uninstall" ]]; then
    echo ""
    echo "[2/3] Removing systemd unit..."

    if systemctl is-active --quiet "$UNIT_NAME"; then
        echo "  Stopping  $UNIT_NAME"
        systemctl stop "$UNIT_NAME"
    else
        echo "  $UNIT_NAME is not active (skip stop)."
    fi

    if systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
        echo "  Disabling $UNIT_NAME"
        systemctl disable "$UNIT_NAME"
    else
        echo "  $UNIT_NAME is not enabled (skip disable)."
    fi

    if [[ -f "$UNIT_DEST" ]]; then
        echo "  Removing  $UNIT_DEST"
        rm -f "$UNIT_DEST"
    else
        echo "  $UNIT_DEST does not exist (skip remove)."
    fi

    systemctl daemon-reload

    echo ""
    echo "[3/3] Done.  Unit fully removed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install — additional preflight specific to install
# ---------------------------------------------------------------------------

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    echo "  ERROR: unit template not found at $TEMPLATE_PATH" >&2
    echo "         Run from a clone of the nautobot-composer repository." >&2
    exit 1
fi

if [[ ! -f "${INSTALL_PATH}/docker-compose.yml" ]]; then
    echo "  ERROR: docker-compose.yml not found in --path target:" >&2
    echo "           $INSTALL_PATH" >&2
    echo "         Pass --path PATH or run from a directory that contains" >&2
    echo "         the project's docker-compose.yml." >&2
    exit 1
fi

echo "  template: $TEMPLATE_PATH"
echo "  path:     $INSTALL_PATH"

# ---------------------------------------------------------------------------
# Install — render the template, install, daemon-reload, optionally enable
# ---------------------------------------------------------------------------

echo ""
echo "[2/3] Installing systemd unit..."

# Render: substitute the WorkingDirectory line.  Using a delimiter that
# can't appear in a Linux path (#) so we don't have to escape slashes.
# The template ships with a `/opt/nautobot-composer` placeholder; we
# rewrite it to whatever --path resolved to.
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

sed -E "s#^(WorkingDirectory=).*#\\1${INSTALL_PATH}#" "$TEMPLATE_PATH" > "$TMPFILE"

# Sanity-check the substitution actually wrote our path.
if ! grep -qxF "WorkingDirectory=${INSTALL_PATH}" "$TMPFILE"; then
    echo "  ERROR: failed to substitute WorkingDirectory in the rendered unit." >&2
    echo "         Inspect the template at $TEMPLATE_PATH" >&2
    exit 1
fi

install -m 0644 "$TMPFILE" "$UNIT_DEST"
echo "  Wrote     $UNIT_DEST  (mode 0644)"

systemctl daemon-reload
echo "  daemon-reload complete"

if [[ "$ENABLE_NOW" == true ]]; then
    systemctl enable --now "$UNIT_NAME"
    echo "  Enabled and started $UNIT_NAME"
else
    echo "  Skipping enable --now (use 'sudo systemctl enable --now $UNIT_NAME' to activate)."
fi

# ---------------------------------------------------------------------------
# Done — show status
# ---------------------------------------------------------------------------

echo ""
echo "[3/3] Done."
echo ""
echo "  systemctl status $UNIT_NAME"
echo "  ----------------------------------------"
# Don't fail the script on systemctl status's non-zero exit (it returns
# 3 for active(exited), which is the correct state for our oneshot unit).
systemctl status "$UNIT_NAME" --no-pager --lines 0 || true
