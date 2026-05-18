#!/usr/bin/env bash
# hex-legacy-1 entrypoint
# Configures and starts services as they would have been in a 1990s Windows shop.
# Nothing here is intentionally broken, it's intentionally correct for its era.
set -e

# --- Samba ---
# Guest/null session access was the default. Share-level security.
# "security = share" was deprecated but was standard through Windows 98.
cat > /etc/samba/smb.conf << 'EOF'
[global]
    workgroup = UUPL
    server string = UU P&L Inventory Server
    security = user
    map to guest = Bad User
    guest account = nobody
    log level = 0
    # NTLMv1 was the norm. LAN Manager hashes in the wild.
    lanman auth = yes
    ntlm auth = yes
    client lanman auth = yes
    min protocol = CORE
    max protocol = NT1

[public]
    path = /srv/smb/public
    browseable = yes
    read only = yes
    guest ok = yes
    comment = UU P&L Public Documents

[private]
    path = /srv/smb/private
    browseable = no
    read only = no
    valid users = Administrator
    comment = Administration
EOF

# Local user, password set at build time in the realistic weak way
# (short, dictionary word, matches what's on a sticky note somewhere)
useradd -M -s /bin/false Administrator 2>/dev/null || true
echo "Administrator:hex123" | chpasswd
(echo "hex123"; echo "hex123") | smbpasswd -a Administrator -s

# --- FTP ---
# vsftpd with anonymous access. Read-only anonymous was considered safe.
cat > /etc/vsftpd.conf << 'EOF'
listen=YES
anonymous_enable=YES
local_enable=YES
write_enable=NO
anon_root=/srv/smb/public
anon_upload_enable=NO
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=NO
connect_from_port_20=YES
ftpd_banner=UU P&L FTP Service
EOF

# --- SSH ---
# SSH was added later. PasswordAuthentication left on, root login permitted
# because the sysadmin needed to get in remotely.
mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
PrintMotd yes
EOF
echo "root:hex123" | chpasswd

# --- Telnet ---
# Still running. Nobody turned it off.
cat > /etc/xinetd.d/telnet << 'EOF'
service telnet
{
    flags           = REUSE
    socket_type     = stream
    protocol        = tcp
    port            = 23
    wait            = no
    user            = root
    server          = /usr/sbin/telnetd
    log_on_failure  += USERID
    disable         = no
}
EOF

# Set root's login shell to the DOS emulator.
usermod -s /usr/local/bin/win95shell.sh root

# Private share: tighten permissions. COPY sets 644; Samba valid users = Administrator.
chmod 640 /srv/smb/private/plc-access.conf
chmod 640 /srv/smb/private/old-backup.bak
chmod 644 /opt/legacy/data/engineering-logbook.txt

# --- /etc/motd ---
cat > /etc/motd << 'EOF'

  UU P&L Network Inventory System v2.3
  Hex Computing Division

  Authorised users only. Contact Ponder Stibbons for access issues.

EOF

# Start services
service smbd start
service nmbd start
mkdir -p /var/run/vsftpd/empty
vsftpd &
service xinetd start
/usr/sbin/sshd -D
