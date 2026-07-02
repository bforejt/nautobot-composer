#!/bin/sh
# ---------------------------------------------------------------------------
# Render the nginx allow/deny include for the firmware device-download
# endpoint from FIRMWARE_ALLOWED_CIDRS.  Runs before nginx starts.
#
# FIRMWARE_ALLOWED_CIDRS is a comma- or whitespace-separated list of CIDRs:
#
#   FIRMWARE_ALLOWED_CIDRS="10.20.30.0/24,10.20.40.0/24"  -> only those subnets
#   FIRMWARE_ALLOWED_CIDRS="0.0.0.0/0"                    -> allow all (default)
#
# Restricting here is defense-in-depth.  Because Docker's published-port NAT
# can rewrite the client source IP (notably with userland-proxy enabled, and
# always on Docker Desktop), the authoritative control is your host firewall /
# VLAN ACL and/or binding the port to a specific management interface via
# FIRMWARE_BIND_ADDRESS.  See the README "Firmware Server" section.
# ---------------------------------------------------------------------------
set -e

OUT_DIR=/etc/nginx/firmware
OUT="$OUT_DIR/allow.conf"
mkdir -p "$OUT_DIR"

CIDRS="${FIRMWARE_ALLOWED_CIDRS:-0.0.0.0/0}"

{
    echo "# Generated from FIRMWARE_ALLOWED_CIDRS at container start. Do not edit."
    echo "$CIDRS" | tr ',' ' ' | xargs -n1 2>/dev/null | while read -r cidr; do
        [ -n "$cidr" ] && echo "allow $cidr;"
    done
    echo "deny all;"
} > "$OUT"

echo "firmware: rendered $OUT from FIRMWARE_ALLOWED_CIDRS='$CIDRS':"
sed 's/^/firmware:   /' "$OUT"
