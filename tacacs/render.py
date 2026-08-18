#!/usr/bin/env python3
"""Render the tac_plus-ng configuration from Nautobot.

Nautobot is the AUTHORING surface; this renderer is the only writer of the
daemon's config.  The rendered file is a derived cache: regenerated on every
change, validated with `tac_plus-ng -P` before it can replace the last-good
config, and never edited by hand.

Data sources (all authored in Nautobot / the stack's .env):
  * device inventory  — Nautobot GraphQL, devices carrying TACACS_DEVICE_TAG
  * per-device PSK    — /secrets/tacacs/<device-name>.key (the file a Nautobot
                        Secret object of provider "text file" points at); falls
                        back to TACACS_DEFAULT_KEY when absent
  * policy            — AD group names from env (TACACS_ADMIN_GROUP /
                        TACACS_READONLY_GROUP) mapped to priv-15 / priv-1
                        profiles in the rendered ruleset

Runs as a library for entrypoint.py, or standalone for field debugging:
    python3 render.py --oneshot          # render + validate + apply + SIGHUP
    python3 render.py --dry-run          # print the rendered config, touch nothing
"""

import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

STATE_DIR = "/var/lib/tac_plus-ng"
CURRENT_CFG = os.path.join(STATE_DIR, "current.cfg")
HEALTH_CREDS = os.path.join(STATE_DIR, "healthcheck.creds")
SECRETS_DIR = "/secrets/tacacs"
TAC_PLUS_NG = "/usr/local/sbin/tac_plus-ng"
MAVIS_LDAP = "/usr/local/lib/mavis/mavis_tacplus_ldap.py"


def env(name, default=""):
    return os.environ.get(name, default).strip()


def log(msg):
    print(f"tacacs-render: {msg}", flush=True)


# -- config text helpers ------------------------------------------------------

def cfg_quote(value):
    """Quote a string for the tac_plus-ng config grammar."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def safe_ident(name):
    """Device names become config identifiers; keep them unambiguous.

    Strips every character outside [A-Za-z0-9_.-] — importantly '/' and control
    characters — so the result is safe both as a tac_plus-ng identifier and as a
    single filesystem path component (no separators survive, so no traversal).
    """
    ident = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return ident or "unnamed"


def safe_comment(text):
    """Strip control characters so untrusted text can't break out of a
    tac_plus-ng '#' comment (which runs to end-of-line) into live config."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", text)


# tac_plus-ng device addresses are bare IPs/CIDRs (unquoted in the grammar), so
# a value that reaches that sink must be shape-validated, never interpolated raw.
_IP_RE = re.compile(r"^[0-9A-Fa-f:.]+(?:/\d{1,3})?$")


def valid_address(ip):
    return bool(ip) and bool(_IP_RE.match(ip))


# -- Nautobot inventory -------------------------------------------------------

def fetch_devices():
    """Return [(name, ip), ...] for devices tagged TACACS_DEVICE_TAG.

    Any error returns None (not []): the caller must treat 'Nautobot
    unavailable' as 'keep serving the last-good config', never as 'the
    device list is now empty'.
    """
    url = env("NAUTOBOT_URL", "http://nautobot:8080").rstrip("/") + "/api/graphql/"
    token = env("TACACS_NAUTOBOT_TOKEN")
    tag = env("TACACS_DEVICE_TAG", "tacacs")
    if not token:
        return None

    query = {
        "query": """
            query ($tag: [String]) {
              devices(tags: $tag) {
                name
                primary_ip4 { host }
              }
            }
        """,
        "variables": {"tag": [tag]},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(query).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Token {token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log(f"Nautobot query failed ({exc}) — keeping last-good config")
        return None

    if payload.get("errors"):
        log(f"Nautobot GraphQL errors: {payload['errors']} — keeping last-good config")
        return None

    devices = []
    for dev in payload.get("data", {}).get("devices", []):
        ip = (dev.get("primary_ip4") or {}).get("host")
        if not ip:
            log(f"device '{dev.get('name')}' has no primary IPv4 — skipped")
            continue
        devices.append((dev["name"], ip))
    return sorted(devices)


def device_key(name):
    """Per-device PSK from the secrets mount, else the stack default key.

    /secrets/tacacs/<name>.key is the file a Nautobot Secret (provider
    "text file") points at — the association is authored in Nautobot, the
    material never enters Nautobot's database.
    """
    # safe_ident() strips path separators, so an adversarial Nautobot device
    # name (e.g. "../nodes/foo") can never escape SECRETS_DIR to read another
    # secret in the shared mount.  Normal DNS-style names are unchanged.
    path = os.path.join(SECRETS_DIR, f"{safe_ident(name)}.key")
    try:
        with open(path) as fh:
            key = fh.read().strip()
        if key:
            return key, True
    except OSError:
        pass
    return env("TACACS_DEFAULT_KEY"), False


# -- healthcheck credentials --------------------------------------------------

def healthcheck_password(persist=True):
    """A local, container-lifetime password for the loopback healthcheck user.

    persist=False (used by --dry-run) never creates the creds file, keeping the
    dry run truly side-effect-free; it returns a throwaway placeholder since the
    value only appears in stdout text that is never loaded by the daemon.
    """
    try:
        with open(HEALTH_CREDS) as fh:
            pw = fh.read().strip()
        if pw:
            return pw
    except OSError:
        pass
    if not persist:
        return "DRY-RUN-PLACEHOLDER-NOT-PERSISTED"
    pw = secrets.token_urlsafe(24)
    fd = os.open(HEALTH_CREDS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(pw + "\n")
    return pw


# -- rendering ----------------------------------------------------------------

def build_config(devices, dry_run=False):
    """Produce the full tac_plus-ng config text.

    devices: [(name, ip)] or [] — the seed config is simply a render with an
    empty inventory, so first boot and steady state share one code path.
    dry_run: when True, no side effects (the healthcheck creds file is not
    created) — the emitted text is for human inspection only.
    """
    default_key = env("TACACS_DEFAULT_KEY")
    admin_group = env("TACACS_ADMIN_GROUP")
    readonly_group = env("TACACS_READONLY_GROUP")
    ad_urls = env("TACACS_AD_URLS")
    open_default = env("TACACS_OPEN_DEFAULT", "true").lower() == "true"
    # Break-glass: a single LOCAL priv-15 user whose password is a crypt hash.
    # It authenticates against that local hash regardless of AD/Nautobot state —
    # a standing emergency account, present in every render (seed included).
    # The hash lives in a FILE (secrets/tacacs/breakglass.hash), not .env: a
    # crypt hash is full of '$', which Compose would mangle as interpolation.
    # Only the (dollar-free) username comes from the environment.
    bg_user = env("TACACS_BREAKGLASS_USER", "breakglass")
    bg_hash = ""
    try:
        with open(os.path.join(SECRETS_DIR, "breakglass.hash")) as fh:
            bg_hash = fh.read().strip()
    except OSError:
        pass
    health_pw = healthcheck_password(persist=not dry_run)

    out = []
    out.append("# GENERATED by render.py — DO NOT EDIT.")
    out.append("# Authoring lives in Nautobot (device tag, secrets) and .env (policy).")
    out.append("")
    out.append("id = spawnd {")
    out.append("    background = no")
    out.append("    listen { port = 49 }")
    out.append("}")
    out.append("")
    out.append("id = tac_plus-ng {")
    # Accounting is durable data (the README lists it under what-to-back-up);
    # daemon diagnostics go to the container's stderr as usual.
    # Date-bucketed destinations (tac_plus-ng expands strftime) so the logs
    # don't grow as single unbounded files; entrypoint.py prunes old buckets.
    out.append(f"    log acct {{ destination = {STATE_DIR}/log/acct/%Y-%m-%d.log }}")
    out.append(f"    log access {{ destination = {STATE_DIR}/log/access/%Y-%m-%d.log }}")
    out.append("    accounting log = acct")
    out.append("    access log = access")
    out.append("")

    if ad_urls:
        # Upstream's own AD/LDAP backend.  Its LDAP_* configuration arrives
        # via process environment (compose env block) — never rendered into
        # this file, so bind credentials stay out of the config cache.
        out.append("    mavis module = external {")
        out.append(f"        exec = {MAVIS_LDAP}")
        out.append("    }")
        out.append("    user backend = mavis")
        out.append("    login backend = mavis")
        out.append("    pap backend = mavis")
    else:
        out.append("    # TACACS_AD_URLS is unset — no MAVIS/AD backend; only the")
        out.append("    # local loopback healthcheck user can authenticate.")
    out.append("")

    # --- devices -------------------------------------------------------------
    out.append("    device healthcheck-localhost {")
    out.append("        address = 127.0.0.1")
    out.append(f"        key = {cfg_quote(health_pw)}")
    out.append("    }")
    if open_default:
        out.append("    # Catch-all client with the stack default key.  Required when")
        out.append("    # Docker's NAT masks real device source IPs (always on Docker")
        out.append("    # Desktop).  Set TACACS_OPEN_DEFAULT=false on hosts where real")
        out.append("    # client IPs reach the container, for RFC 8907 §10.5.2 allow-listing.")
        out.append("    device world {")
        out.append("        address = 0.0.0.0/0")
        out.append(f"        key = {cfg_quote(default_key)}")
        out.append("    }")
    # Track rendered identifiers so two Nautobot names that sanitize to the
    # same token (e.g. "a/b" and "a b" -> "a_b") don't emit duplicate device
    # blocks and fail the whole -P validation — one bad name would otherwise
    # freeze the entire config.  Colliders get a numeric suffix, with a log.
    seen_idents = {}
    for name, ip in devices:
        if not valid_address(ip):
            log(f"device '{safe_comment(name)}' has a non-IP address '{safe_comment(str(ip))}' — skipped")
            continue
        ident = safe_ident(name)
        if ident in seen_idents:
            seen_idents[ident] += 1
            new_ident = f"{ident}-{seen_idents[ident]}"
            log(f"device name '{safe_comment(name)}' collides on identifier '{ident}' — rendering as '{new_ident}'")
            ident = new_ident
        else:
            seen_idents[ident] = 1
        key, dedicated = device_key(name)
        origin = "per-device secret" if dedicated else "stack default key"
        # safe_comment strips control chars so a crafted name cannot break out
        # of this end-of-line '#' comment into live config.
        out.append(f"    # {safe_comment(name)} ({origin})")
        out.append(f"    device {ident} {{")
        out.append(f"        address = {ip}")
        out.append(f"        key = {cfg_quote(key)}")
        out.append("    }")
    out.append("")

    # --- users / groups / profiles -------------------------------------------
    out.append("    user healthcheck {")
    out.append(f"        password login = clear {cfg_quote(health_pw)}")
    out.append("    }")
    out.append("")
    # Break-glass local admin.  Self-contained inline priv-15 profile so it does
    # NOT depend on the AD groups/ruleset or a reachable Nautobot — it works even
    # in the seed config.  The password is a crypt hash; tac_plus-ng does not
    # expand the '$' in a quoted crypt value.  Only 'safe_ident' chars are
    # allowed in the username so it can't inject config.
    if bg_hash:
        out.append("    # Break-glass local admin (always available; hash from secrets file).")
        out.append(f"    user {safe_ident(bg_user)} {{")
        out.append(f"        password login = crypt {cfg_quote(bg_hash)}")
        out.append("        password pap = login")
        out.append("        profile {")
        out.append("            enable 15 = login")
        out.append("            script {")
        out.append("                if (service == shell) {")
        out.append("                    if (cmd == \"\") { set priv-lvl = 15 permit }")
        out.append("                    permit")
        out.append("                }")
        out.append("                deny")
        out.append("            }")
        out.append("        }")
        out.append("    }")
        out.append("")
    # `member == X` in ruleset scripts requires X to be a DECLARED group even
    # though actual membership arrives dynamically from AD via MAVIS TACMEMBER.
    for group in (admin_group, readonly_group):
        if group:
            out.append(f"    group {cfg_quote(group)} {{ }}")
    out.append("")
    out.append("    profile admin {")
    out.append("        # Enable password = the user's AD login password.")
    out.append("        enable 15 = login")
    out.append("        script {")
    out.append("            if (service == shell) {")
    out.append("                if (cmd == \"\") { set priv-lvl = 15 permit }")
    out.append("                # No per-command authorization (yet) — permit all.")
    out.append("                permit")
    out.append("            }")
    out.append("            deny")
    out.append("        }")
    out.append("    }")
    out.append("    profile readonly {")
    out.append("        script {")
    out.append("            if (service == shell) {")
    out.append("                if (cmd == \"\") { set priv-lvl = 1 permit }")
    out.append("                permit")
    out.append("            }")
    out.append("            deny")
    out.append("        }")
    out.append("    }")
    out.append("    profile healthcheck {")
    out.append("        script {")
    out.append("            if (service == shell) {")
    out.append("                if (cmd == \"\") { set priv-lvl = 0 permit }")
    out.append("            }")
    out.append("            deny")
    out.append("        }")
    out.append("    }")
    out.append("")

    # --- ruleset -------------------------------------------------------------
    out.append("    ruleset {")
    out.append("        rule healthcheck {")
    out.append("            script {")
    out.append("                if (device == healthcheck-localhost && user == healthcheck) {")
    out.append("                    profile = healthcheck")
    out.append("                    permit")
    out.append("                }")
    out.append("            }")
    out.append("        }")
    if admin_group:
        out.append("        rule admins {")
        out.append("            script {")
        out.append(f"                if (member == {cfg_quote(admin_group)}) {{")
        out.append("                    profile = admin")
        out.append("                    permit")
        out.append("                }")
        out.append("            }")
        out.append("        }")
    if readonly_group:
        out.append("        rule readonly {")
        out.append("            script {")
        out.append(f"                if (member == {cfg_quote(readonly_group)}) {{")
        out.append("                    profile = readonly")
        out.append("                    permit")
        out.append("                }")
        out.append("            }")
        out.append("        }")
    out.append("    }")
    out.append("}")
    return "\n".join(out) + "\n"


# -- validate / apply ---------------------------------------------------------

def validate(cfg_text):
    """`tac_plus-ng -P` parse-check: a broken render must never reach the daemon."""
    with tempfile.NamedTemporaryFile(
        "w", dir=STATE_DIR, prefix=".candidate-", suffix=".cfg", delete=False
    ) as fh:
        fh.write(cfg_text)
        candidate = fh.name
    ok = False
    try:
        proc = subprocess.run(
            [TAC_PLUS_NG, "-P", candidate],
            capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            log(f"validation FAILED — keeping last-good config:\n{proc.stderr.strip()}")
            return None
        ok = True
        return candidate
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"validation error ({exc}) — keeping last-good config")
        return None
    finally:
        if not ok:
            try:
                os.unlink(candidate)
            except OSError:
                pass


def apply_config(cfg_text, daemon_pid=None):
    """Validate, atomically install, and SIGHUP the daemon.  True on success."""
    try:
        with open(CURRENT_CFG) as fh:
            if fh.read() == cfg_text:
                return True  # no change — no reload churn
    except OSError:
        pass

    candidate = validate(cfg_text)
    if candidate is None:
        return False
    os.replace(candidate, CURRENT_CFG)
    log(f"installed new config at {CURRENT_CFG}")
    if daemon_pid:
        try:
            os.kill(daemon_pid, __import__("signal").SIGHUP)
            log(f"sent SIGHUP to tac_plus-ng (pid {daemon_pid})")
        except OSError as exc:
            log(f"SIGHUP failed ({exc}) — daemon will pick the config up on restart")
    return True


def render_once(daemon_pid=None):
    """One render cycle.  Returns True if a valid config is in place."""
    devices = fetch_devices()
    if devices is None and env("TACACS_NAUTOBOT_TOKEN"):
        # Nautobot unreachable: leave last-good alone if we have one.
        if os.path.exists(CURRENT_CFG):
            return True
        devices = []  # first boot with Nautobot down — seed with empty inventory
    elif devices is None:
        devices = []  # renderer unconfigured — static/seed mode
    else:
        log(f"rendering for {len(devices)} device(s) from Nautobot")
    return apply_config(build_config(devices), daemon_pid)


if __name__ == "__main__":
    if "--dry-run" in sys.argv:
        devices = fetch_devices() or []
        sys.stdout.write(build_config(devices, dry_run=True))
    elif "--oneshot" in sys.argv:
        pid = None
        try:
            pid = int(open(os.path.join(STATE_DIR, "daemon.pid")).read().strip())
        except (OSError, ValueError):
            pass
        sys.exit(0 if render_once(pid) else 1)
    else:
        print("usage: render.py [--dry-run | --oneshot]", file=sys.stderr)
        sys.exit(2)
