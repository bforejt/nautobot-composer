# NFV Answer Service (profile: `answer-service`)

The SoT-backed engine of the [nautobot-proxmox](https://github.com/bforejt/nautobot-proxmox)
bare-metal install loop. An installing machine POSTs its identity (DMI serial,
NIC MACs); this service matches it against Nautobot's serial allowlist and
renders a per-node Proxmox answer file, then captures the node's firstboot
credential phone-home (per-node API token → text-file Secrets under
`../secrets/nodes/` + a SecretsGroup) and the post-install webhook. Full
architecture and runbook: `docs/baremetal-install.md` in the nautobot-proxmox
repo (built from that repo's `bmc/` directory, fetched over git at build time
by default — set `ANSWER_SERVICE_BUILD_CONTEXT=../nautobot-proxmox/bmc` in
`.env` to build from a local sibling checkout instead).

## One-time setup

**The easy path:** `./setup.sh --with-answer-service` (from the project root)
does steps 1–3 for you — it generates the TLS keypair and writes its
`ANSWER_CERT_FINGERPRINT` into `.env`, generates a root password hash (and
prints the root password once), auto-fills `ANSWER_PUBLIC_URL` from the host's
primary IP and (on the lab tier) `ANSWER_NAUTOBOT_TOKEN` from the generated
superuser token, and reports the build context (the git-URL default needs no
local checkout; a local-path override is checked for existence). It never
overwrites values you've already set. Review the two auto-filled values
(override for multi-homed hosts / non-lab tokens), then start it (step 4).

Do it manually instead if you prefer:

1. Generate the TLS keypair (from this directory):

   ```bash
   mkdir -p certs
   openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
     -subj "/CN=answer-service" \
     -keyout certs/answer-service.key -out certs/answer-service.crt
   openssl x509 -in certs/answer-service.crt -outform der | sha256sum
   ```

   Put the printed SHA256 in `.env` as `ANSWER_CERT_FINGERPRINT`, and pass the
   same value to `prepare-install-iso.sh --fingerprint` when preparing
   installer media. **The fingerprint is baked into prepared ISOs/PXE
   artifacts — regenerating the cert means re-preparing them.**

2. Set `ANSWER_NAUTOBOT_TOKEN` (a Nautobot API token) and `ANSWER_PUBLIC_URL`
   (a LAN address nodes can reach, e.g. `https://<host-ip>:8800`) in `.env`
   (see `env.example`). The service refuses to start until both are set — the
   `answer-service-preflight` one-shot fails `up` with a clear message,
   without wedging `down`/`config` the way a `${VAR:?}` guard would.

3. Root password hash for installed nodes:

   ```bash
   mkpasswd -m sha-512 > ../secrets/root_password_hash   # or: openssl passwd -6
   ```

4. Start it:

   ```bash
   docker compose --profile answer-service up -d --build
   ```

## Notes

- **Boot persistence**: add `answer-service` to `COMPOSE_PROFILES` in `.env`
  (comma-separated with other profiles) so it starts with plain
  `docker compose up -d`, survives reboots, and is covered by the systemd
  unit — same pattern as the firmware profile.
- This service is the deliberate exception to the "nothing in the stack
  writes `./secrets`" rule: it writes only under `./secrets/nodes/`
  (firstboot-captured per-node Proxmox tokens). Nautobot's own mount of the
  directory stays read-only.
- `certs/` is git-ignored — the keypair never leaves this host.
- **Back up** `certs/` (fingerprint baked into prepared installer media),
  `../secrets/nodes/` (tokens recoverable only by node reinstall), and the
  `nautobot_answer_data` volume — none are covered by `backup.sh`. See the
  main README's Answer Service section.
