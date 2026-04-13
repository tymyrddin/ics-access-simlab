FROM debian:12.0
# debian:12.0 ships openssh-server 9.2p1-2 — vulnerable to CVE-2024-6387 (regreSSHion).
# Primary attack surface: PermitRootLogin yes + weak root password.
# rsyslog forwards auth events (login failures, sessions) to scribes-post at 10.10.5.32:514.
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server rsyslog && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY rsyslog-forward.conf /etc/rsyslog.d/50-forward.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
