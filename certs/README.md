# Nautobot web TLS certificate

Nautobot's web UI is served over HTTPS (port 443 → container 8443) by uWSGI,
which reads its certificate and key from two files bind-mounted from this
directory:

| File | Mounted into the container as | Purpose |
|------|-------------------------------|---------|
| `nautobot.crt` | `/opt/nautobot/nautobot.crt` | Server certificate (PEM) |
| `nautobot.key` | `/opt/nautobot/nautobot.key` | Private key (PEM) |

`setup.sh` generates a **self-signed** pair here if none exists, so the stack
always has a working certificate (browsers will still warn — it isn't trusted).
To remove the browser warning, replace both files with a certificate issued by
a CA your browsers trust, then restart the web service:

```bash
cp /path/to/your.crt certs/nautobot.crt
cp /path/to/your.key certs/nautobot.key
docker compose restart nautobot
```

Requirements for the files you drop in:

- **PEM format.** `nautobot.crt` should contain the **full chain** — your leaf
  certificate first, followed by any intermediate CA certificates — or browsers
  may report an incomplete chain.
- **Unencrypted key.** uWSGI starts non-interactively and cannot prompt for a
  passphrase; decrypt the key first if it is protected
  (`openssl rsa -in enc.key -out nautobot.key`).
- **Matching hostname.** The certificate's Common Name / Subject Alternative
  Names must cover the hostname you browse to (and that hostname must be in
  `NAUTOBOT_ALLOWED_HOSTS` in `.env`).

Everything in this directory except this README is git-ignored — private keys
and certificates are never committed. `setup.sh` sets ownership so the Nautobot
container (UID/GID 999) can read the key while the host user can still edit it.

The change takes effect on `docker compose restart nautobot` (or the next
`up -d`); uWSGI reads the certificate once at startup.
