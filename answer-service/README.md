# NFV Answer Service (profile: `answer-service`)

The SoT-backed engine of the [nautobot-proxmox](https://github.com/bforejt/nautobot-proxmox)
bare-metal install loop. An installing machine POSTs its identity (DMI serial,
NIC MACs); this service matches it against Nautobot's serial allowlist and
renders a per-node Proxmox answer file, then captures the node's firstboot
credential phone-home (per-node API token → text-file Secrets under
`../secrets/nodes/` + a SecretsGroup) and the post-install webhook. Full
architecture and runbook: `docs/baremetal-install.md` in the nautobot-proxmox
repo (built from that repo's `bmc/` directory — a sibling checkout by default).

## One-time setup

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

2. Set `ANSWER_NAUTOBOT_TOKEN` and `ANSWER_PUBLIC_URL` in `.env`
   (see `env.example`).

3. Root password hash for installed nodes:

   ```bash
   mkpasswd -m sha-512 > ../secrets/root_password_hash
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
