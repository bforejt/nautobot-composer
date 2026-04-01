ARG NAUTOBOT_VERSION=3.0-py3.12
FROM networktocode/nautobot:${NAUTOBOT_VERSION}

# Switch to root for package installation and file operations.
USER root

# Install any additional OS-level dependencies needed by Apps.
# Uncomment and add packages as required by specific Apps:
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     libxml2-dev \
#     libxslt-dev \
#  && rm -rf /var/lib/apt/lists/*

# Install Nautobot Apps and additional Python dependencies.
# The requirements.txt file lists pip packages (one per line) to install
# into the Nautobot container image.
COPY requirements.txt /tmp/requirements.txt
RUN if grep -qvE '^\s*(#|$)' /tmp/requirements.txt; then \
        pip install --no-cache-dir -r /tmp/requirements.txt; \
    fi && \
    rm /tmp/requirements.txt

# Copy the Nautobot configuration file into the image.
COPY nautobot_config.py /opt/nautobot/nautobot_config.py
RUN chown nautobot:nautobot /opt/nautobot/nautobot_config.py

# Drop back to the nautobot user for runtime.
USER nautobot
