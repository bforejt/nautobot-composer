# ---------------------------------------------------------------------------
# Custom nginx image for the firmware device-download endpoint.
#
# Why a build instead of plain nginx:1.30-alpine:
#   * The base image ships libssl but NOT the openssl CLI, which the first-run
#     self-signed-cert helper needs.  Installing it at container start would
#     require outbound network to the Alpine CDN — unavailable on exactly the
#     locked-down / air-gapped management networks this firmware host targets.
#     Baking it in means first start never needs the network.
#   * The first-run helper scripts are COPYed (not bind-mounted) with the exec
#     bit set here, so they always run regardless of the host file mode they
#     were checked out with.  (The official nginx entrypoint silently SKIPS
#     non-executable scripts, which would otherwise crash-loop the server with
#     no cert and no allow/deny rules.)
#
# Build context: ./firmware/nginx
# ---------------------------------------------------------------------------
FROM nginx:1.30-alpine

# openssl CLI for first-run self-signed certificate generation.
RUN apk add --no-cache openssl

# First-run helpers, executed by the official nginx entrypoint
# (/docker-entrypoint.sh) in lexical order before nginx starts.
COPY 10-gen-selfsigned.sh /docker-entrypoint.d/10-gen-selfsigned.sh
COPY 25-render-allow.sh   /docker-entrypoint.d/25-render-allow.sh
RUN chmod +x /docker-entrypoint.d/10-gen-selfsigned.sh \
             /docker-entrypoint.d/25-render-allow.sh
