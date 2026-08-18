# ---------------------------------------------------------------------------
# tac_plus-ng TACACS+ server for the Nautobot stack (profile: tacacs)
#
# Builds Marc Huber's event-driven-servers from a PINNED commit — upstream
# publishes no release tags or official images, so the SHA below is the
# reproducibility anchor.  Bump it deliberately, never track master.
#
# What lands in the image:
#   * tac_plus-ng            — the TACACS+ daemon (RFC 8907)
#   * mavis_tacplus_ldap.py  — upstream's OWN Python MAVIS backend for
#                              LDAP/Active Directory (autodetects AD, binds as
#                              the user so AD lockout/expiry policy applies,
#                              returns nested-group membership as TACMEMBER)
#   * mavis.py               — upstream's Python MAVIS protocol binding
#   * entrypoint.py/render.py — our supervisor + Nautobot config renderer
#
# This product includes software developed by Marc Huber (Marc.Huber@web.de);
# see https://github.com/MarcJHuber/event-driven-servers (LICENSE: BSD-style
# with acknowledgment clause — the acknowledgment also appears in README.md).
# ---------------------------------------------------------------------------
FROM alpine:3.22

# Pinned upstream commit (master @ 2026-08-11).
ARG EDS_COMMIT=bc14cb9b7f1694e0fb6881012bbc1d3e361a723e

# Build deps are removed in the same layer to keep the image lean.  Runtime
# keeps: pcre2/openssl/c-ares (daemon links them), python3 + ldap3 (MAVIS
# backend and our renderer — the renderer itself is stdlib-only on purpose).
# NOTE: upstream's ./configure is a Perl script — perl is a build-time dep.
# The explicit test -x / -s guards exist because a partially-successful
# upstream build must fail the image build loudly, not surface at runtime.
RUN apk add --no-cache pcre2 openssl c-ares python3 py3-ldap3 \
    && apk add --no-cache --virtual .build \
        build-base pcre2-dev openssl-dev c-ares-dev curl perl \
    && curl -fsSL "https://github.com/MarcJHuber/event-driven-servers/archive/${EDS_COMMIT}.tar.gz" \
        | tar -xz -C /tmp \
    && cd "/tmp/event-driven-servers-${EDS_COMMIT}" \
    && ./configure tac_plus-ng mavis \
    && make \
    && make install \
    && test -x /usr/local/sbin/tac_plus-ng \
    && mkdir -p /usr/local/lib/mavis \
    && install -m 0755 mavis/python/mavis.py /usr/local/lib/mavis/mavis.py \
    && install -m 0755 mavis/python/mavis_tacplus_ldap.py /usr/local/lib/mavis/mavis_tacplus_ldap.py \
    && test -s /usr/local/lib/mavis/mavis_tacplus_ldap.py \
    && cd / \
    && rm -rf /tmp/event-driven-servers-* \
    && apk del .build

# Upstream's MAVIS Python binding must be importable by the LDAP module.
ENV PYTHONPATH=/usr/local/lib/mavis

COPY entrypoint.py /usr/local/bin/tacacs-entrypoint.py
COPY render.py     /usr/local/lib/tacacs/render.py
COPY healthcheck.py /usr/local/bin/tacacs-healthcheck.py

# Rendered config, last-good state, and accounting logs live here (volume).
RUN mkdir -p /var/lib/tac_plus-ng/log

EXPOSE 49
ENTRYPOINT ["python3", "/usr/local/bin/tacacs-entrypoint.py"]
