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

# Pre-create volume mount points with correct ownership.
# When Docker mounts a named volume onto an empty directory, it copies the
# directory's ownership and contents from the image into the volume.  By
# creating these directories as nautobot:nautobot here, new named volumes
# will inherit the right permissions automatically.
RUN mkdir -p \
        /opt/nautobot/media/devicetype-images \
        /opt/nautobot/media/image-attachments \
        /opt/nautobot/git \
        /opt/nautobot/jobs \
    && chown -R nautobot:nautobot \
        /opt/nautobot/media \
        /opt/nautobot/git \
        /opt/nautobot/jobs

# Drop back to the nautobot user for runtime.
USER nautobot
