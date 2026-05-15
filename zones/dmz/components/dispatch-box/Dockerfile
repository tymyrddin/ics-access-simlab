# atmoz/sftp does not publish a `debian-bookworm` tag. The rolling
# `debian` tag is bookworm today; pinned by digest so the lab does not
# silently shift when upstream rolls forward.
FROM atmoz/sftp:debian@sha256:8b3a4d6d7535b85c840c669c2f19e1e23bbeda5458d215ff7273e67a2edc5bcf
# User: anonymous / password: anonymous
# Upload directory: /home/anonymous/upload (world-writable)
# No chroot jail, directory traversal via ../ is possible.
# rsyslog forwards auth events (login failures, SFTP sessions) to scribes-post at 10.10.5.32:514.
# sshd requires root (binds port 22, manages auth); root is justified here.
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends iproute2 rsyslog && \
    rm -rf /var/lib/apt/lists/*
COPY users.conf /etc/sftp/users.conf
COPY rsyslog-forward.conf /etc/rsyslog.d/50-forward.conf
COPY entrypoint-wrapper.sh /entrypoint-wrapper.sh
RUN chmod +x /entrypoint-wrapper.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint-wrapper.sh"]
