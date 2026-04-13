FROM atmoz/sftp:debian
# User: anonymous / password: anonymous
# Upload directory: /home/anonymous/upload (world-writable)
# No chroot jail — directory traversal via ../ is possible.
COPY users.conf /etc/sftp/users.conf
EXPOSE 22
