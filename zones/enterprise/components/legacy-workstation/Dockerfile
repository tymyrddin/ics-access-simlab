# legacy-workstation — Win95-era service stack
#
# Simulates a workstation running software from an era when network services
# were designed for connectivity, not security. Samba, FTP, and Telnet are
# configured as they would have been in the late 1990s: openly, with the
# assumption that anyone on the network belongs there.
#
# The attack surface here is not a misconfiguration — it's correct operation
# for the era. Nobody changed it because it kept working.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-common-bin \
    vsftpd \
    telnetd \
    telnet \
    xinetd \
    openssh-server \
    openssh-client \
    netcat-openbsd \
    ftp \
    rsh-client \
    net-tools \
    iputils-ping \
    nmap \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/legacy

COPY config/ /opt/legacy/config/
COPY data/   /opt/legacy/data/
COPY entrypoint.sh /entrypoint.sh
COPY win95shell.sh /usr/local/bin/win95shell.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/win95shell.sh

# Samba shares land here
RUN mkdir -p /srv/smb/public /srv/smb/private

# Populate with realistic operational documents
COPY data/shares/ /srv/smb/public/

EXPOSE 21 22 23 139 445

ENTRYPOINT ["/entrypoint.sh"]