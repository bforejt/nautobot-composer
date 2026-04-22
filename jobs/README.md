# Custom Nautobot Jobs

This directory is bind-mounted into all Nautobot containers at `/opt/nautobot/jobs` (the default `JOBS_ROOT`). Drop Python files here to make them available as Nautobot Jobs.

## Adding a Job

1. Create a Python file in this directory (e.g., `hello_world.py`).
2. Restart Nautobot so it picks up the new file:
   ```bash
   docker compose restart nautobot celery_worker celery_beat
   ```
3. In the Nautobot UI, go to **Jobs → Jobs** and click **Refresh** if the job doesn't appear immediately.
4. Enable the job (set it to **Enabled** and **Installed**) from the Jobs admin page.

## Minimal Example

```python
# jobs/hello_world.py
from nautobot.apps.jobs import Job, StringVar, register_jobs


class HelloWorld(Job):
    class Meta:
        name = "Hello World"
        description = "A minimal example job."

    name = StringVar(description="Who should we greet?", default="World")

    def run(self, name):
        self.logger.info("Hello, %s!", name)


register_jobs(HelloWorld)
```

See the [Nautobot Jobs documentation](https://docs.nautobot.com/projects/core/en/stable/user-guide/platform-functionality/jobs/) for the full API, including `ObjectVar`, `MultiObjectVar`, `JobButtonReceiver`, and scheduling.

## Notes

- **File ownership (Linux):** The Nautobot container runs as UID/GID `999:999`. If you're on Linux and hit permission errors reading job files, run `sudo chown -R 999:999 ./jobs`. Not an issue on macOS/Docker Desktop.
- **Git tracking:** Python cache files (`__pycache__/`, `*.pyc`) are already gitignored. The jobs themselves are tracked.
- **Subdirectories:** You can organize jobs into subpackages. Each subdirectory needs an `__init__.py`.
