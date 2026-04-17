# engineering-workstation
#
# Used to configure, update, and reprogram PLCs and IEDs in the control zone.
# Has direct network access to both the operational zone and the control zone.
# This is not an accident — it is required for the job. The access controls
# are the credentials in the config files and "asking Ponder first."
#
# Presents a Windows 10 Enterprise LTSC facade over SSH.
# Virtual C: drive lives at /opt/win10/C with a realistic Windows user profile.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    python3 \
    python3-venv \
    cron \
    net-tools \
    iproute2 \
    iputils-ping \
    nmap \
    curl \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"

RUN pip install --no-cache-dir pymodbus==3.6.8 paho-mqtt

COPY entrypoint.sh /entrypoint.sh
COPY win10ltsc_shell.sh /usr/local/bin/win10ltsc_shell.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/win10ltsc_shell.sh

RUN useradd -m -s /usr/local/bin/win10ltsc_shell.sh engineer
RUN echo "engineer:spanner99" | chpasswd

# ICS_PROCESS and CONTROL_SUBNET are set by the orchestrator.
ENV ICS_PROCESS=intelligent_electronic_device
ENV CONTROL_SUBNET=10.10.3.0/24

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
