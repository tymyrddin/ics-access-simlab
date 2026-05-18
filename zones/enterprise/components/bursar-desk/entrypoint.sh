#!/usr/bin/env bash
# bursar-desk entrypoint
set -e

# --- SSH ---
mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
PrintMotd no
EOF

PROFILE="/opt/win10/C/Users/bursardesk"

# Careless copy left in /tmp, someone needed the conf outside the profile.
cp "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf" /tmp/ops-access.conf.bak
chmod 644 /tmp/ops-access.conf.bak

# Fix ownership and tighten permissions on sensitive files.
chown -R bursardesk:bursardesk /opt/win10
chmod 700 "$PROFILE/.ssh"
chmod 600 "$PROFILE/.ssh/known_hosts"
chmod 600 "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf"

# Wire the real Linux home .ssh so the ssh command picks up known_hosts.
mkdir -p /home/bursardesk/.ssh
cp "$PROFILE/.ssh/known_hosts" /home/bursardesk/.ssh/known_hosts
chown -R bursardesk:bursardesk /home/bursardesk/.ssh
chmod 700 /home/bursardesk/.ssh
chmod 600 /home/bursardesk/.ssh/known_hosts

# Dual-homed (enterprise + operational); only non-adjacent zones need explicit routes.

/usr/sbin/sshd -D
