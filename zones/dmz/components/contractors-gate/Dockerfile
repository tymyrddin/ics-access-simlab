FROM debian:12.0
# debian:12.0 ships openssh-server 9.2p1-2, vulnerable to CVE-2024-6387 (regreSSHion).
# Primary attack surface: PermitRootLogin yes + weak root password.
# rsyslog forwards auth events (login failures, sessions) to scribes-post at 10.10.5.32:514.
#
# Recon tooling (nmap, ftp, netcat-openbsd, curl, smbclient): a real DMZ-edge
# bastion that doubles as an ops health-check host carries these. Without them
# the ssh-bastion-rce runbook's Stage 3 lateral-movement commands fail with
# `command not found` on every line.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iproute2 \
        openssh-server \
        rsyslog \
        ntp \
        nmap \
        ftp \
        netcat-openbsd \
        curl \
        smbclient \
        && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd /var/lib/ntp
COPY sshd_config /etc/ssh/sshd_config
COPY rsyslog-forward.conf /etc/rsyslog.d/50-forward.conf
COPY ntp.conf /etc/ntp.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
