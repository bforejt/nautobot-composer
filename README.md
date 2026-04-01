# Nautobot Docker Compose — Network Source of Truth

Production-ready Docker Compose deployment for [Nautobot 3.0](https://docs.nautobot.com/projects/core/en/stable/), the open-source Network Source of Truth and Automation Platform.

## Stack Components

| Component | Image | Purpose |
|-----------|-------|---------|
| **Nautobot** | Custom (based on `networktocode/nautobot:3.0-py3.12`) | Web UI, REST/GraphQL API, application server |
| **Celery Worker** | Same custom image | Background task execution (jobs, webhooks, Git sync) |
| **Celery Beat** | Same custom image | Scheduled task orchestration |
| **PostgreSQL 16** | `postgres:16-alpine` | Primary relational database |
| **Redis 7** | `redis:7-alpine` | Caching, Celery broker, and lock backend |

## Quick Start

```bash
# Clone and enter the project
git clone <your-repo-url> && cd nautobot-docker

# Generate a secret key and set credentials
cp env.example .env
python3 -c "from secrets import token_urlsafe; print(f'NAUTOBOT_SECRET_KEY={token_urlsafe(64)}')" >> .env
# Edit .env to set passwords and other site-specific values

# Build the custom Nautobot image (installs Apps from requirements.txt)
docker compose build

# Start the stack
docker compose up -d

# Verify all services are healthy
docker compose ps
```

Nautobot will be available at:
- **HTTP:** `http://localhost:8080`
- **HTTPS (self-signed):** `https://localhost:8443`

## Project Structure

```
nautobot-docker/
├── docker-compose.yml        # Service definitions
├── Dockerfile                # Custom Nautobot image with Apps
├── requirements.txt          # Nautobot Apps (pip packages)
├── nautobot_config.py        # Nautobot application configuration
├── env.example               # Template for .env (copy to .env)
├── .env                      # Local secrets and overrides (git-ignored)
├── .gitignore
└── README.md
```

## Installing Nautobot Apps

1. Add the pip package name to `requirements.txt`:
   ```
   nautobot-ssot
   nautobot-device-lifecycle-mgmt
   ```

2. Enable the app in `nautobot_config.py` under `PLUGINS` and optionally configure it under `PLUGINS_CONFIG`.

3. Rebuild and restart:
   ```bash
   docker compose build --no-cache
   docker compose up -d
   ```

Nautobot's entrypoint automatically runs database migrations on startup, so newly installed Apps will have their schemas applied.

## Configuration

### Environment Variables (.env)

All sensitive and deployment-specific values live in `.env`. See `env.example` for the full list with descriptions. Key variables:

| Variable | Purpose |
|----------|---------|
| `NAUTOBOT_SECRET_KEY` | Django secret key (required, generate unique per deployment) |
| `NAUTOBOT_ALLOWED_HOSTS` | Comma-separated hostnames/IPs allowed to reach Nautobot |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `NAUTOBOT_SUPERUSER_*` | Initial admin account credentials |

### nautobot_config.py

This file is bind-mounted into the container at `/opt/nautobot/nautobot_config.py`. It imports all defaults from `nautobot.core.settings` and overrides only what's needed. Most runtime settings are pulled from environment variables, keeping the config file portable across environments.

## Operations

### Backup PostgreSQL

```bash
docker compose exec -T db pg_dump -U nautobot nautobot | gzip > backup_$(date +%F_%H%M%S).sql.gz
```

### Restore PostgreSQL

```bash
gunzip -c backup_YYYY-MM-DD_HHMMSS.sql.gz | docker compose exec -T db psql -U nautobot nautobot
```

### Run Nautobot Management Commands

```bash
docker compose exec nautobot nautobot-server <command>

# Examples:
docker compose exec nautobot nautobot-server createsuperuser
docker compose exec nautobot nautobot-server nbshell
docker compose exec nautobot nautobot-server post_upgrade
```

### View Logs

```bash
docker compose logs -f nautobot
docker compose logs -f celery_worker
```

### Upgrade Nautobot

1. Update the `NAUTOBOT_VERSION` ARG in `Dockerfile` (or override at build time).
2. Review [release notes](https://docs.nautobot.com/projects/core/en/stable/release-notes/) for breaking changes.
3. Rebuild and restart:
   ```bash
   docker compose build --no-cache
   docker compose up -d
   ```

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `nautobot_postgres_data` | `/var/lib/postgresql/data` | Persistent database storage |
| `nautobot_redis_data` | `/data` | Redis persistence (optional, for cache durability) |
| `nautobot_media` | `/opt/nautobot/media` | Uploaded files (images, attachments) |
| `nautobot_git` | `/opt/nautobot/git` | Git repository clones |
| `nautobot_jobs` | `/opt/nautobot/jobs` | Custom job files |

## Production Considerations

- Replace the self-signed TLS cert with a proper certificate (or terminate TLS at a reverse proxy).
- Set `NAUTOBOT_ALLOWED_HOSTS` to your actual FQDN(s).
- Use strong, unique passwords for PostgreSQL and the superuser account.
- Place a reverse proxy (nginx, Caddy, Traefik) in front for TLS termination and rate limiting.
- Back up PostgreSQL regularly.
- Consider external Redis (ElastiCache, etc.) for HA deployments.

## License

This deployment configuration is provided under the [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) license, consistent with Nautobot itself.
# nautobot-composer
