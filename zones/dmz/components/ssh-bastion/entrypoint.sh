#!/bin/sh
set -e

# Set root password (CTF vulnerability — weak credential)
echo "root:uupl2015" | chpasswd

# Generate host keys if not already present
ssh-keygen -A

exec /usr/sbin/sshd -D -e
