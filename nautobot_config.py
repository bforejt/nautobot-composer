"""Nautobot Configuration — Docker Compose Deployment.

This file overrides settings from nautobot.core.settings.  Most values are
pulled from environment variables so the same image can be deployed across
dev / staging / production without modification.

Reference: https://docs.nautobot.com/projects/core/en/stable/user-guide/administration/configuration/
"""

import os
import sys

from nautobot.core.settings import *  # noqa: F403  pylint: disable=wildcard-import,unused-wildcard-import
from nautobot.core.settings_funcs import is_truthy, parse_redis_connection

# ---------------------------------------------------------------------------
# Debug & Testing
# ---------------------------------------------------------------------------
DEBUG = is_truthy(os.getenv("NAUTOBOT_DEBUG", "False"))
TESTING = len(sys.argv) > 1 and sys.argv[1] == "test"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_LEVEL = os.getenv("NAUTOBOT_LOG_LEVEL", "INFO")

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------
ALLOWED_HOSTS = os.getenv("NAUTOBOT_ALLOWED_HOSTS", "*").split(",")
SECRET_KEY = os.getenv("NAUTOBOT_SECRET_KEY")

# Session and CSRF security — uncomment when behind a TLS-terminating proxy:
# CSRF_TRUSTED_ORIGINS = ["https://nautobot.example.com"]
# SESSION_COOKIE_SECURE = True
# CSRF_COOKIE_SECURE = True

# ---------------------------------------------------------------------------
# Database — PostgreSQL
# ---------------------------------------------------------------------------
DATABASES = {
    "default": {
        "NAME": os.getenv("NAUTOBOT_DB_NAME", "nautobot"),
        "USER": os.getenv("NAUTOBOT_DB_USER", "nautobot"),
        "PASSWORD": os.getenv("NAUTOBOT_DB_PASSWORD", ""),
        "HOST": os.getenv("NAUTOBOT_DB_HOST", "db"),
        "PORT": os.getenv("NAUTOBOT_DB_PORT", "5432"),
        "CONN_MAX_AGE": int(os.getenv("NAUTOBOT_DB_CONN_MAX_AGE", "300")),
        "ENGINE": os.getenv("NAUTOBOT_DB_ENGINE", "django.db.backends.postgresql"),
    }
}

# ---------------------------------------------------------------------------
# Redis — Caching & Celery Broker
# ---------------------------------------------------------------------------
CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": parse_redis_connection(redis_database=0),
        "TIMEOUT": 300,
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
        },
    }
}

CACHEOPS_REDIS = parse_redis_connection(redis_database=1)

# Celery settings are driven by environment variables by default.
# They use CACHES["default"]["LOCATION"] unless overridden.

# ---------------------------------------------------------------------------
# Nautobot Application Settings
# ---------------------------------------------------------------------------

# Metrics endpoint (/metrics) for Prometheus scraping.
METRICS_ENABLED = is_truthy(os.getenv("NAUTOBOT_METRICS_ENABLED", "True"))

# Maximum page size for REST API list endpoints (0 = unlimited).
MAX_PAGE_SIZE = int(os.getenv("NAUTOBOT_MAX_PAGE_SIZE", "0"))

# Hide restricted UI elements from users who lack permissions.
HIDE_RESTRICTED_UI = is_truthy(os.getenv("NAUTOBOT_HIDE_RESTRICTED_UI", "True"))

# Opt out of anonymous installation metrics.
INSTALLATION_METRICS_ENABLED = is_truthy(
    os.getenv("NAUTOBOT_INSTALLATION_METRICS_ENABLED", "False")
)

# Branding — uncomment and customise to white-label the UI:
# BRANDING_TITLE = "My Network SoT"
# BRANDING_PREPENDED_FILENAME = "mysot"

# External authentication (REMOTE_AUTH / SSO / LDAP) — configure as needed.
# See: https://docs.nautobot.com/projects/core/en/stable/user-guide/administration/configuration/authentication/

# ---------------------------------------------------------------------------
# NAPALM (optional) — used by some Apps for device interaction
# ---------------------------------------------------------------------------
NAPALM_USERNAME = os.getenv("NAPALM_USERNAME", "")
NAPALM_PASSWORD = os.getenv("NAPALM_PASSWORD", "")
NAPALM_TIMEOUT = int(os.getenv("NAPALM_TIMEOUT", "30"))

# ---------------------------------------------------------------------------
# Apps (Plugins)
# ---------------------------------------------------------------------------
# Each App listed in PLUGINS must also be pip-installed (see requirements.txt).
# App-specific configuration goes into PLUGINS_CONFIG.

PLUGINS = [
    "nautobot_device_lifecycle_mgmt",
    "nautobot_ssot",
    "nautobot_golden_config",
    "nautobot_chatops",
    "nautobot_circuit_maintenance",
    "nautobot_firewall_models",
    "nautobot_bgp_models",
    "nautobot_design_builder",
    "nautobot_welcome_wizard",
]

PLUGINS_CONFIG = {
    #Example configuration for an App:
    
    "nautobot_ssot": {
        "hide_example_jobs": True,
    },
    
    "nautobot_golden_config": {
        "per_feature_bar_width": 0.3,
        "per_feature_width": 13,
        "per_feature_height": 4,
        "enable_backup": True,
        "enable_compliance": True,
        "enable_intended": True,
        "enable_sotagg": True,
        "sot_agg_transposer": None,
        "platform_slug_map": {},
    },
}
