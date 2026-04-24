# enterprise-workstation — Windows 10 corporate desktop
#
# A workstation that accumulated access over time. Originally provisioned for
# the finance department. At some point given network access to operational
# systems for a "temporary" data pull that became permanent.
#
# Presents a Windows 10 PowerShell facade over SSH. The filesystem lives at
# /opt/win10/C with a realistic Windows user profile structure.
# The issues are not in the OS — they are in what was left in the profile
# by people who needed to get things done quickly.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    openssh-server \
    openssh-client \
    curl \
    wget \
    netcat-openbsd \
    net-tools \
    iputils-ping \
    nmap \
    ftp \
    python3 \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY win10shell.sh /usr/local/bin/win10shell.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/win10shell.sh

# The user account. Password set at provisioning and never changed.
RUN useradd -m -s /usr/local/bin/win10shell.sh bursardesk
RUN echo "bursardesk:Octavo1" | chpasswd

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
