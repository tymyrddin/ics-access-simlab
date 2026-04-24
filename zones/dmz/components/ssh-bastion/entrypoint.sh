#!/bin/sh
set -e

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
# ssh-bastion is dual-homed (DMZ + enterprise); add specific routes only.
_add_route 10.10.0.0/24 10.10.5.200   # internet return path via inet-dmz-fw
_add_route 10.10.2.0/24 10.10.1.202

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
