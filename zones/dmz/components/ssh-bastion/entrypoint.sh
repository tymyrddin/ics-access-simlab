#!/bin/sh
set -e

# Set root password (CTF vulnerability — weak credential)
echo "root:uupl2015" | chpasswd

# Generate host keys if not already present
ssh-keygen -A

# Start rsyslog to forward auth events to scribes-post (10.10.5.32:514)
rsyslogd
sleep 1

# Send a startup entry to the syslog relay
logger -t sshd "Unseen University Power & Light Co. bastion gateway (contractors-gate) starting. Auth logging active."

exec /usr/sbin/sshd -D -e
