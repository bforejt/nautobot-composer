#!/bin/sh
# ---------------------------------------------------------------------------
# Generate a self-signed TLS certificate for the firmware device-download
# endpoint if none has been provided.  Runs before nginx starts (the official
# nginx entrypoint executes /docker-entrypoint.d/*.sh in lexical order).
#
# This only fills the gap so the HTTPS listener always has *a* certificate.
# For production IOS-XE `copy https:` pulls the device validates the server
# cert against its trustpoints — drop a CA-issued cert/key into
# ./firmware/certs/ as server.crt / server.key to replace this one, or use
# the HTTP listener on a locked-down management VLAN instead.
# ---------------------------------------------------------------------------
set -e

CERT_DIR=/etc/nginx/certs
CRT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

if [ -s "$CRT" ] && [ -s "$KEY" ]; then
    echo "firmware: TLS cert present at $CRT — leaving it untouched"
    exit 0
fi

SERVER_NAME="${FIRMWARE_SERVER_NAME:-localhost}"
echo "firmware: no TLS cert found — generating a self-signed cert for '$SERVER_NAME'"

# openssl is baked into the image (see firmware/nginx/Dockerfile), so this
# never needs the network.  If it is somehow missing, fail loudly with an
# actionable message rather than silently crash-looping nginx on a missing cert.
if ! command -v openssl >/dev/null 2>&1; then
    echo "firmware: ERROR — openssl is not available in this image; cannot generate a cert." >&2
    echo "firmware:   Mount a cert into ./firmware/certs (server.crt + server.key)," >&2
    echo "firmware:   or rebuild the image:  docker compose ... build firmware-download" >&2
    exit 1
fi

# Decide the SAN: a *valid* IPv4 literal goes in an IP SAN, everything else is
# treated as a DNS name.  A malformed all-numeric value (e.g. "10.0.0") would
# make openssl reject the IP SAN and abort, so validate strictly here.
# localhost / 127.0.0.1 are always added (so the healthcheck and local curl
# work) without being duplicated when the server name already is one of those.
is_ipv4() {
    case "$1" in
        ""|*[!0-9.]*) return 1 ;;
    esac
    oldifs="$IFS"; IFS=.; set -- $1; IFS="$oldifs"
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        [ -n "$octet" ] || return 1
        [ "$octet" -ge 0 ] 2>/dev/null && [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

if [ "$SERVER_NAME" = localhost ] || [ "$SERVER_NAME" = 127.0.0.1 ]; then
    SAN="DNS:localhost,IP:127.0.0.1"
elif is_ipv4 "$SERVER_NAME"; then
    SAN="IP:$SERVER_NAME,DNS:localhost,IP:127.0.0.1"
else
    SAN="DNS:$SERVER_NAME,DNS:localhost,IP:127.0.0.1"
fi

mkdir -p "$CERT_DIR"
gen_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$KEY" -out "$CRT" -days 825 \
        -subj "/CN=$1" \
        -addext "subjectAltName=$2"
}

# Belt-and-suspenders: if generation ever fails (e.g. an exotic server name),
# fall back to a localhost-only cert so the HTTPS listener still comes up
# instead of crash-looping.
if ! gen_cert "$SERVER_NAME" "$SAN"; then
    echo "firmware: cert generation with SAN '$SAN' failed — retrying with a localhost-only cert" >&2
    gen_cert localhost "DNS:localhost,IP:127.0.0.1"
fi
chmod 600 "$KEY"
echo "firmware: self-signed cert written to $CRT (SAN: $SAN)"
