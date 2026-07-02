#!/usr/bin/env bash
# =============================================================================
# add-secret.sh — Create or rotate a secret file for Nautobot's built-in
# "text file" secrets provider.
#
# The ./secrets directory is bind-mounted read-only into every Nautobot
# container at /opt/nautobot/secrets (see docker-compose.yml).  The provider
# reads the file at ACCESS time — job run or the UI's "Check Secret" — so a
# file written here is usable immediately: no restart, no rebuild.
#
# Usage:
#   ./add-secret.sh <name>              Prompt for the value (input hidden)
#   some-command | ./add-secret.sh <name>   Read the value from stdin
#                                            (trailing newlines stripped)
#
# Then, in Nautobot (once per secret, not per rotation):
#   Secrets > Add:  Provider = "Text File",
#                   Path = /opt/nautobot/secrets/<name>
#
# Rotation is just re-running this script — Secret records point at the
# path, so the next access picks up the new value.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SCRIPT_DIR}/secrets"
CONTAINER_PATH="/opt/nautobot/secrets"
NAUTOBOT_GID=999   # container group that gets read access (matches setup.sh)

usage() {
    cat <<'HELP'
Usage: ./add-secret.sh <name>
       some-command | ./add-secret.sh <name>

Creates (or rotates) ./secrets/<name> for Nautobot's "text file" secrets
provider.  Interactive runs prompt with hidden input; piped input is taken
as the value with trailing newlines stripped.

After creating a NEW secret, register it once in Nautobot:
  Secrets > Add:  Provider = "Text File",
                  Path = /opt/nautobot/secrets/<name>
Rotations need nothing further — the file is re-read on next access.
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

NAME="$1"

# The name becomes a filename inside the mounted directory — keep it to a
# safe character set and refuse anything path-like.
if [[ ! "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: secret name must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes, no leading dot)." >&2
    exit 1
fi

if [[ ! -d "$SECRETS_DIR" ]]; then
    echo "ERROR: ${SECRETS_DIR} does not exist — run ./setup.sh first." >&2
    exit 1
fi

TARGET="${SECRETS_DIR}/${NAME}"
ACTION="Created"
[[ -f "$TARGET" ]] && ACTION="Rotated"

# --- read the value ---------------------------------------------------------
if [[ -t 0 ]]; then
    # Interactive: hidden prompt, typed twice to catch typos you can't see.
    read -rs -p "Value for '${NAME}': " VALUE;  echo >&2
    read -rs -p "Confirm value:        " CONFIRM; echo >&2
    if [[ "$VALUE" != "$CONFIRM" ]]; then
        echo "ERROR: values do not match — nothing written." >&2
        exit 1
    fi
else
    # Piped (e.g. 'pass show lab/iosxe | ./add-secret.sh iosxe-password').
    # Strip trailing newlines: virtually every producer appends one, and it
    # is never part of the credential.
    VALUE="$(cat)"
    while [[ "$VALUE" == *$'\n' ]]; do VALUE="${VALUE%$'\n'}"; done
fi

if [[ -z "$VALUE" ]]; then
    echo "ERROR: empty value — nothing written." >&2
    exit 1
fi

# --- write the file ---------------------------------------------------------
# printf '%s' writes the value byte-for-byte (no trailing newline), so what
# Nautobot reads is exactly what was entered.  umask keeps the file private
# from the first byte; the temp file + mv makes the update atomic, so a job
# reading mid-rotation sees the old value or the new one, never a torn file.
umask 037
TMP="$(mktemp "${TARGET}.XXXXXX")"
printf '%s' "$VALUE" > "$TMP"
mv -f "$TMP" "$TARGET"

# Group ownership for the container user (GID 999).  Direct chgrp only works
# if the invoking user is a member of that group, which is rare on a host —
# fall back to the same helper-container pattern setup.sh uses (root inside
# the container may chown host files through the bind mount; no sudo needed).
if ! chgrp "$NAUTOBOT_GID" "$TARGET" 2>/dev/null; then
    docker run --rm -v "${SECRETS_DIR}:/secrets" \
        alpine chown "$(id -u):${NAUTOBOT_GID}" "/secrets/${NAME}"
fi
chmod 640 "$TARGET" 2>/dev/null || \
    docker run --rm -v "${SECRETS_DIR}:/secrets" alpine chmod 640 "/secrets/${NAME}"

echo "${ACTION}: ${TARGET}  (mode 640, group ${NAUTOBOT_GID})"
echo
if [[ "$ACTION" == "Created" ]]; then
    echo "Register it in Nautobot (once):"
    echo "  Secrets > Add"
    echo "    Provider: Text File"
    echo "    Path:     ${CONTAINER_PATH}/${NAME}"
    echo "Then attach it to a Secrets Group (e.g. as username/password) and"
    echo "assign that group to devices.  Verify with the 'Check Secret' button."
else
    echo "Nautobot Secret records point at ${CONTAINER_PATH}/${NAME} — the new"
    echo "value is live on the next access.  No restart needed."
fi
