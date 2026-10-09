#!/usr/bin/env python3
"""Build-time patches to upstream's mavis_tacplus_ldap.py (AD review, 2026-10).

Each patch replaces an exact upstream snippet that must occur exactly once;
anything else fails the image build, so an EDS_COMMIT bump forces a re-check
of every patch instead of silently shipping an unpatched module.

  1. search-as-service: upstream re-binds the service account only if the
     connection's last bind failed.  After a user's password check
     (conn.rebind(user=<user DN>, password=<their password>)) the next
     request in that MAVIS child re-binds AS THAT USER, so every failed login
     costs the victim a SECOND bad-password count (lockout at half the
     threshold), every child holding an old password fails a bind after a
     password change, and searches run with the last user's rights.  Always
     re-bind as the service account at the start of each request; on failure
     drop the connection so the next request reconnects instead of crashing.
  2. escape-filter: the username is .format()ed into the LDAP filter
     unescaped (wildcards/filter injection; tac_plus-ng's username ACL blocks
     most metacharacters end to end, this is defense in depth).
  3. ad-skip-disabled: the AD user filter matched disabled accounts, so
     authorization-only (INFO) lookups returned group membership, i.e.
     priv 15, for a disabled NetAdmins user.
  4. bounded-pool: ServerPool(active=True) retries forever when every DC is
     down, so MAVIS never answers and devices only fall back to `local` after
     their own timeout.  One cycle, then a fast ERROR; an unreachable server
     is skipped for 10 s.
  5. pool-loop-timeout: ldap3 sleeps POOLING_LOOP_TIMEOUT (10 s) after a
     failed pool cycle before giving up; 1 s keeps the error prompt
     (render.py's `authentication fallback = deny` turns it into a TACACS
     ERROR, on which devices fall through to `local`).
"""
import sys

PATH = sys.argv[1]
src = open(PATH).read()

PATCHES = [
    ("search-as-service",
     "\tif not conn.bind():\n"
     "\t\tconn.rebind(user=LDAP_USER, password=LDAP_PASSWD)\n"
     "\n"
     "\tif not conn.bind():\n"
     "\t\tD.write(MAVIS_FINAL, AV_V_RESULT_ERROR, \"LDAP bind failure.\")\n"
     "\t\tcontinue\n",
     "\ttry:\n"
     "\t\tbound = conn.rebind(user=LDAP_USER, password=LDAP_PASSWD)\n"
     "\texcept Exception:\n"
     "\t\tbound = False\n"
     "\tif not bound:\n"
     "\t\tconn = None\n"
     "\t\tD.write(MAVIS_FINAL, AV_V_RESULT_ERROR, \"LDAP bind failure.\")\n"
     "\t\tcontinue\n"),
    ("escape-filter-import",
     "import os, sys, re, ldap3, time, calendar, socket\n",
     "import os, sys, re, ldap3, time, calendar, socket\n"
     "from ldap3.utils.conv import escape_filter_chars\n"),
    ("escape-filter",
     "search_filter=LDAP_FILTER.format(D.user),",
     "search_filter=LDAP_FILTER.format(escape_filter_chars(D.user)),"),
    ("ad-skip-disabled",
     "LDAP_FILTER = '(&(objectclass=user)(sAMAccountName={}))'",
     "LDAP_FILTER = '(&(objectclass=user)(sAMAccountName={})"
     "(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'"),
    ("pool-loop-timeout",
     '#ldap3.set_config_parameter("POOLING_LOOP_TIMEOUT", LDAP_CONNECT_TIMEOUT)',
     'ldap3.set_config_parameter("POOLING_LOOP_TIMEOUT", 1)'),
    ("bounded-pool",
     "ldap3.ServerPool(None, ldap3.FIRST, active=True)",
     "ldap3.ServerPool(None, ldap3.FIRST, active=1, exhaust=10)"),
]

for name, old, new in PATCHES:
    n = src.count(old)
    if n != 1:
        sys.exit(f"patch_mavis: '{name}': anchor found {n} times (expected 1); "
                 "upstream changed, re-check this patch")
    src = src.replace(old, new)
    print(f"patch_mavis: applied {name}")

open(PATH, "w").write(src)
