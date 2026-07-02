# Secret files — Nautobot "text file" provider

Every file in this directory (except this README) is a secret **value**,
readable by the Nautobot containers at `/opt/nautobot/secrets/<filename>`
via a read-only bind mount (see `x-nautobot-volumes` in
`docker-compose.yml`).

Nautobot's built-in **Text File** secrets provider reads the file at
*access* time — when a Job resolves a Secrets Group, or when you press
**Check Secret** in the UI. Adding or rotating a secret therefore needs
**no container restart, rebuild, or compose change**.

## Conventions

- **One secret per file.** Filename = the secret's name; file contents =
  the value, with no trailing newline.
- Create and rotate with the helper, which handles both plus permissions:

  ```bash
  ./add-secret.sh iosxe-password              # hidden prompt
  pass show lab/iosxe | ./add-secret.sh iosxe-password   # or from a manager
  ```

- Register each new file once in Nautobot: **Secrets → Add**, provider
  **Text File**, path `/opt/nautobot/secrets/<filename>`. Attach Secrets to
  a **Secrets Group** (e.g. username + password) and assign the group to
  devices — jobs like the *nautobot-upgrades* IOS-XE upgrade resolve
  credentials through the device's Secrets Group automatically.
- The provider's path field supports Jinja, e.g.
  `/opt/nautobot/secrets/{{ obj.location.name }}-password` — one Secret
  record can fan out to per-site files.

## Security notes

- Everything here except this README is **gitignored**. Never commit a
  secret value.
- `setup.sh` (and `add-secret.sh`) keep files at mode `640`, owner = you,
  group = `999` (the container user), directory `750` — you edit without
  sudo, containers read, others get nothing.
- Values are plaintext on the host — the same trust level as `.env`, which
  already holds the database and admin credentials.
- Nautobot-side exposure is governed by RBAC: anyone permitted to create
  Secrets and view their values can read any *container*-readable path, not
  just this directory. Restrict `extras | secret` permissions accordingly.
- `backup.sh` does **not** back up this directory; keep your secret source
  of truth (password manager, vault) elsewhere and treat these files as a
  cache you can repopulate.
