#!/usr/bin/env python3
"""Supervisor for the tacacs container.

One container, two responsibilities, one process tree:
  * run tac_plus-ng in the foreground (spawnd `background = no`)
  * run the Nautobot render loop, which validates every candidate config
    with `tac_plus-ng -P` and SIGHUPs the daemon only on a good change

The renderer lives in-container (not a sidecar) deliberately: SIGHUP and -P
validation both need the daemon's binary and PID namespace, and sharing those
across containers costs more machinery than it saves.

Availability contract: the daemon never waits for Nautobot.  Boot order is
last-good config if present, else a freshly rendered seed (empty inventory —
accepts only the loopback healthcheck user).  Renders that fail leave the
last-good config serving.
"""

import os
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, "/usr/local/lib/tacacs")
import render  # noqa: E402

DAEMON = "/usr/local/sbin/tac_plus-ng"
PID_FILE = os.path.join(render.STATE_DIR, "daemon.pid")


def log(msg):
    print(f"tacacs-entrypoint: {msg}", flush=True)


def _int_env(name, default):
    """Parse an int env var, falling back with a WARNING rather than raising —
    a bad value must not kill the thread that guards against 'silently stale'."""
    raw = os.environ.get(name, str(default)).strip()
    try:
        return int(raw)
    except ValueError:
        log(f"WARNING: {name}='{raw}' is not an integer — using {default}")
        return default


LOG_DIR = os.path.join(render.STATE_DIR, "log")


def prune_logs():
    """Delete date-bucketed log files older than TACACS_LOG_RETENTION_DAYS.
    0 disables pruning (keep everything)."""
    days = _int_env("TACACS_LOG_RETENTION_DAYS", 30)
    if days <= 0:
        return
    cutoff = time.time() - days * 86400
    for sub in ("acct", "access"):
        d = os.path.join(LOG_DIR, sub)
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        for fname in entries:
            fpath = os.path.join(d, fname)
            try:
                if os.path.isfile(fpath) and os.path.getmtime(fpath) < cutoff:
                    os.unlink(fpath)
                    log(f"pruned old log {fpath}")
            except OSError:
                pass


CA_FILE_DEFAULT = "/secrets/tacacs/ad-ca.pem"


def ad_tls_kwargs():
    """ldap3.Tls keyword arguments for the AD connection, from TACACS_AD_TLS_*.

    Returns None when certificate validation is off (or AD is not configured).
    Fails closed: validation is on unless TACACS_AD_TLS_VERIFY is exactly
    "false", and an explicitly named CA file that is missing is still passed
    through, so every AD login fails visibly instead of silently trusting less.
    """
    import ssl
    if not os.environ.get("TACACS_AD_URLS", "").strip():
        return None
    verify = os.environ.get("TACACS_AD_TLS_VERIFY", "true").strip().lower() or "true"
    if verify == "false":
        log("WARNING: TACACS_AD_TLS_VERIFY=false: the DC certificate is NOT "
            "validated, so anything that can intercept the LDAPS connection can "
            "collect users' AD passwords")
        return None
    if verify != "true":
        log(f"WARNING: TACACS_AD_TLS_VERIFY='{verify}' is not true/false; validating")
    kwargs = {"validate": ssl.CERT_REQUIRED}
    ca = os.environ.get("TACACS_AD_CA_FILE", "").strip()
    if ca:
        if not os.path.isfile(ca):
            log(f"ERROR: TACACS_AD_CA_FILE={ca} does not exist; every AD login will fail")
        kwargs["ca_certs_file"] = ca
    elif os.path.isfile(CA_FILE_DEFAULT):
        kwargs["ca_certs_file"] = CA_FILE_DEFAULT
    else:
        log(f"no AD CA file ({CA_FILE_DEFAULT} absent, TACACS_AD_CA_FILE unset): "
            "trusting the system CA store only")
    names = os.environ.get("TACACS_AD_TLS_NAME", "").split()
    if names:
        kwargs["valid_names"] = names
    return kwargs


def configure_ad_tls():
    """Export TLS_OPTIONS for the MAVIS LDAP module (inherited by the daemon's
    MAVIS children).  The module eval()s the value, so it is built only from
    repr()-quoted strings and the ssl.CERT_REQUIRED constant, never from raw
    .env text."""
    os.environ.pop("TLS_OPTIONS", None)
    kwargs = ad_tls_kwargs()
    if kwargs is None:
        return None
    parts = ["validate=ssl.CERT_REQUIRED"]
    parts += [f"{k}={v!r}" for k, v in kwargs.items() if k != "validate"]
    os.environ["TLS_OPTIONS"] = ", ".join(parts)
    log("AD LDAPS certificate validation ON (" +
        ", ".join(f"{k}={v}" for k, v in kwargs.items() if k != "validate") + ")")
    return kwargs


def probe_ad_tls(kwargs):
    """One TLS handshake per ldaps:// URL with the module's exact settings, so
    a certificate problem is named in the log.  The MAVIS module itself
    reports every failure as "No answer from LDAP backend."  Runs in a
    thread: the daemon never waits for AD."""
    import ldap3
    for url in os.environ.get("TACACS_AD_URLS", "").split():
        if not url.lower().startswith("ldaps://"):
            log(f"AD TLS check {url}: not ldaps://, skipped")
            continue
        try:
            server = ldap3.Server(url, tls=ldap3.Tls(**kwargs), connect_timeout=5)
            conn = ldap3.Connection(server, receive_timeout=5)
            conn.open()
            conn.unbind()
            log(f"AD TLS check {url}: certificate OK")
        except Exception as exc:  # report, never crash the supervisor
            log(f"AD TLS check {url}: FAILED ({exc}); AD logins via this URL "
                "will fail with 'No answer from LDAP backend.'")


def render_loop(get_pid):
    interval = max(30, _int_env("TACACS_RENDER_INTERVAL", 300))
    have_token = bool(os.environ.get("TACACS_NAUTOBOT_TOKEN", "").strip())
    if have_token:
        log(f"render loop active — reconciling with Nautobot every {interval}s")
    else:
        log("TACACS_NAUTOBOT_TOKEN unset — render loop idle (static seed config); "
            "set the token in .env to activate Nautobot-driven rendering. "
            "Log pruning still runs.")
    while True:
        time.sleep(interval)
        try:
            prune_logs()
            if have_token:
                render.render_once(get_pid())
        except Exception as exc:  # never let the loop die and go silently stale
            log(f"render/prune cycle crashed ({exc}) — will retry in {interval}s")


def main():
    # Create the date-bucket parents the daemon writes into (it expands the
    # strftime path but does not mkdir -p the directory tree itself).
    for sub in ("log/acct", "log/access"):
        os.makedirs(os.path.join(render.STATE_DIR, sub), exist_ok=True)

    # First boot: materialise a config before the daemon starts.  With
    # Nautobot reachable this is already the real inventory; otherwise it is
    # the safe seed (healthcheck user only).  A failed render with an existing
    # last-good config is fine — we serve last-good.
    if not render.render_once(None) and not os.path.exists(render.CURRENT_CFG):
        log("FATAL: no last-good config and the seed render failed")
        sys.exit(1)

    tls_kwargs = configure_ad_tls()

    daemon = subprocess.Popen([DAEMON, render.CURRENT_CFG])
    with open(PID_FILE, "w") as fh:
        fh.write(str(daemon.pid))
    log(f"tac_plus-ng started (pid {daemon.pid})")

    # Forward termination signals so `docker stop` is graceful.
    def forward(signum, _frame):
        try:
            daemon.send_signal(signum)
        except OSError:
            pass
    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)

    threading.Thread(
        target=render_loop, args=(lambda: daemon.pid,), daemon=True
    ).start()
    if tls_kwargs is not None:
        threading.Thread(target=probe_ad_tls, args=(tls_kwargs,), daemon=True).start()

    # The daemon is the container's reason to exist: if it dies, exit with its
    # status and let `restart: unless-stopped` bring the pair back up.
    sys.exit(daemon.wait())


if __name__ == "__main__":
    main()
