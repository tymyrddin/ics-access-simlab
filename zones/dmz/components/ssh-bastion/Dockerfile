FROM debian:12.0
# debian:12.0 ships openssh-server 9.2p1-2 — vulnerable to CVE-2024-6387 (regreSSHion).
# Primary attack surface: PermitRootLogin yes + weak root password.
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
