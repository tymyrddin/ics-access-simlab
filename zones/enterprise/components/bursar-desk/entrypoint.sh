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

# Careless copy left in C:\Temp, someone needed the conf outside the profile.
mkdir -p /opt/win10/C/Temp
cp "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf" /opt/win10/C/Temp/ops-access.conf.bak
chmod 644 /opt/win10/C/Temp/ops-access.conf.bak

# Fix ownership and tighten permissions on sensitive files.
chown -R bursardesk:bursardesk /opt/win10
chmod 700 "$PROFILE/.ssh"
chmod 600 "$PROFILE/.ssh/known_hosts"
chmod 600 "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf"

# Wire the real Linux home .ssh so the ssh command picks up known_hosts.
# The display file (virtual C: drive) keeps plausible historical keys.
# The real known_hosts is populated from actual host keys at runtime so
# SSH connections do not hit a key-mismatch error.
mkdir -p /home/bursardesk/.ssh
touch /home/bursardesk/.ssh/known_hosts
chown -R bursardesk:bursardesk /home/bursardesk/.ssh
chmod 700 /home/bursardesk/.ssh
chmod 600 /home/bursardesk/.ssh/known_hosts
(for i in 1 2 3 4 5 6; do
    ssh-keyscan -t ed25519 10.10.2.10 10.10.2.20 10.10.2.30 2>/dev/null \
        > /home/bursardesk/.ssh/known_hosts
    [ -s /home/bursardesk/.ssh/known_hosts ] && break
    sleep 5
done) &

# Dual-homed (enterprise + operational); only non-adjacent zones need explicit routes.

/usr/sbin/sshd -D
