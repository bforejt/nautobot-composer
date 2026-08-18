#!/usr/bin/env python3
"""Container healthcheck: prove the TACACS+ listener is accepting connections.

A plain TCP connect to 127.0.0.1:49 — deliberately protocol-free.  A full
authentication probe (tactester with the local healthcheck user) would be
stronger but couples liveness to config details; connection acceptance plus
the supervisor's exit-on-daemon-death behavior covers the real failure modes.
"""

import socket
import sys

try:
    with socket.create_connection(("127.0.0.1", 49), timeout=5):
        pass
except OSError as exc:
    print(f"unhealthy: {exc}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
