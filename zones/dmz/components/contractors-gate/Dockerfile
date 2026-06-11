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
        openssh-client \
        rsyslog \
        ntp \
        nmap \
        ftp \
        netcat-openbsd \
        curl \
        dnsutils \
        mosquitto-clients \
        smbclient \
        python3 \
        python3-venv \
        && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd /var/lib/ntp /root/.ssh && \
    chmod 700 /root/.ssh
# asyncua: OPC-UA client library for reaching guild-register (10.10.5.13:4840).
# Installed in /venv to match the eng-ws convention; run with /venv/bin/python3.
RUN python3 -m venv /venv && \
    /venv/bin/pip install --quiet asyncua
# Fixed contractor maintenance key pair. Private key is realistic loot on
# the image; the public half is authorized on uupl-eng-ws engineer account,
# enabling the ProxyJump path in ~/.ssh/config.
COPY contractor_key /root/.ssh/contractor_key
COPY contractor_key.pub /root/.ssh/contractor_key.pub
COPY contractor_key.pub /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys /root/.ssh/contractor_key /root/.ssh/contractor_key.pub
COPY bash_history /root/.bash_history
COPY ssh_config /root/.ssh/config
RUN chmod 600 /root/.ssh/config
COPY sshd_config /etc/ssh/sshd_config
# Remove Debian's default local-file logging rules so rsyslog only forwards
# to scribes-post (10.10.5.32:514). Without this, rsyslog throws chown errors
# trying to set ownership on /var/log/auth.log and /var/log/syslog inside the
# container, and auth events end up in neither place. Forward-only is also the
# realistic posture: a hardened bastion logs centrally, not locally.
RUN rm -f /etc/rsyslog.d/50-default.conf
COPY rsyslog-forward.conf /etc/rsyslog.d/50-forward.conf
COPY ntp.conf /etc/ntp.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
