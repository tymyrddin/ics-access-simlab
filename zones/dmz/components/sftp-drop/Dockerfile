FROM atmoz/sftp:debian
# User: anonymous / password: anonymous
# Upload directory: /home/anonymous/upload (world-writable)
# No chroot jail — directory traversal via ../ is possible.
# rsyslog forwards auth events (login failures, SFTP sessions) to scribes-post at 10.10.5.32:514.
RUN apt-get update && \
    apt-get install -y --no-install-recommends rsyslog && \
    rm -rf /var/lib/apt/lists/*
COPY users.conf /etc/sftp/users.conf
COPY rsyslog-forward.conf /etc/rsyslog.d/50-forward.conf
COPY entrypoint-wrapper.sh /entrypoint-wrapper.sh
RUN chmod +x /entrypoint-wrapper.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint-wrapper.sh"]
