#!/bin/sh
set -e

# Set root password (CTF vulnerability, weak credential)
echo "root:uupl2015" | chpasswd

# Generate host keys if not already present
ssh-keygen -A

# Populate known_hosts and leave a /tmp nmap artefact once the enterprise
# interface is up and bursar-desk is accepting SSH connections. clab's exec:
# block sets the eth2 IP after the entrypoint hands off to sshd, so both
# commands run in a background loop. Waiting for bursar-desk:22 rather than
# sleeping a fixed interval makes the artefacts reliable regardless of
# container startup order. nmap uses TCP SYN (-PS22,23) because ICMP is
# not available inside the container.
(
    i=0
    while [ $i -lt 30 ]; do
        ip addr show dev eth2 2>/dev/null | grep -q '10\.10\.1\.' && break
        sleep 1; i=$((i+1))
    done
    # Wait up to 60 s for bursar-desk sshd to be ready before keyscanning
    j=0
    while [ $j -lt 60 ]; do
        nc -z 10.10.1.20 22 2>/dev/null && break
        sleep 1; j=$((j+1))
    done
    ssh-keyscan -T 5 10.10.1.20 10.10.1.10 10.10.1.3 >> /root/.ssh/known_hosts 2>/dev/null || true
    chmod 600 /root/.ssh/known_hosts
    nmap -sn -PS22,23 10.10.1.0/24 -oG /tmp/enterprise-sweep.txt 2>/dev/null || true
) &

# Start rsyslog to forward auth events to scribes-post (10.10.5.32:514)
rsyslogd
sleep 1

# Send a startup entry to the syslog relay
logger -t sshd "Unseen University Power & Light Co. bastion gateway (contractors-gate) starting. Auth logging active."

exec /usr/sbin/sshd -D -e
