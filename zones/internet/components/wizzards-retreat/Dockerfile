FROM debian:bookworm-slim

# deb.debian.org is fronted by Fastly; specific POPs degraded from this host.
# Pin to a direct NL mirror.
RUN sed -i 's|deb.debian.org|ftp.nl.debian.org|g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    openssh-server \
    openssh-client \
    iputils-ping \
    net-tools \
    curl \
    rpcbind \
    netbase \
    nfs-ganesha \
    nfs-ganesha-vfs \
    nmap \
    ftp \
    smbclient \
    mosquitto-clients \
    chrony \
    python3 \
    python3-flask \
    python3-venv \
    telnet \
    tree \
    cron \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Patch nmap-service-probes: add a match for hex-legacy-1's telnet IAC sequence
# so nmap labels the service rather than emitting a fingerprint blob.
COPY patch-nmap-probes.py /tmp/patch-nmap-probes.py
RUN python3 /tmp/patch-nmap-probes.py && rm /tmp/patch-nmap-probes.py

# Rincewind's admin Python venv. Plausible kit for a UU P&L sysadmin who
# pokes at OPC-UA servers from home over the VPN. Modbus tooling stays on
# eng-ws, not here.
RUN python3 -m venv /opt/admin-env && \
    /opt/admin-env/bin/pip install --no-cache-dir opcua

# Remote administrator account, weak password is the vulnerability
RUN useradd -m -s /bin/bash rincewind && \
    echo "rincewind:wizzard" | chpasswd

# SSH: password auth allowed (deliberately weak)
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Rincewind's home directory files
COPY vpn/uupl-vpn.conf /home/rincewind/.vpn/uupl-vpn.conf
COPY work/notes.txt /home/rincewind/notes.txt
# Loot: SSH key for engineering workstation, world-readable via NFS (the vulnerability)
COPY loot/ssh/   /home/rincewind/.ssh-keys/
# Bash history: accumulated admin activity, not placed deliberately
RUN printf '%s\n' \
    'ls -la' \
    'cat notes.txt' \
    'ssh -i ~/.ssh-keys/uupl_eng_key engineer@10.10.2.30' \
    'curl -s http://10.10.2.10:8080/assets' \
    'ssh hist_admin@10.10.2.10' \
    'ls -la ~/.ssh-keys/' \
    'nmap -sn 10.10.1.0/24' \
    'ftp 10.10.1.10' \
    'curl -s http://10.10.2.20:8080/ -u admin:admin' \
    'ping 10.10.2.30' \
    'ssh -i ~/.ssh-keys/uupl_eng_key engineer@10.10.2.30' \
    'curl -s "http://10.10.2.10:8080/report?asset=turbine_rpm&from=2024-01-01&to=2024-02-01"' \
    'nmap -sn 10.10.2.0/24' \
    'curl -s http://10.10.2.10:8080/assets' \
    'cat notes.txt' \
    > /home/rincewind/.bash_history

# NFS work share, world-readable, no auth required (misconfiguration)
RUN mkdir -p /home/rincewind/work
COPY work/notes.txt /home/rincewind/work/notes.txt
RUN chmod 755 /home/rincewind/work && \
    chmod 644 /home/rincewind/work/notes.txt

# Rincewind's SSH keypair. Public key goes into authorized_keys so key login works.
# Private key copy left in work/, the entrypoint stages work/ to the NFS export with
# 644 permissions, making the key world-readable to anyone who mounts the share.
RUN ssh-keygen -t ed25519 -f /home/rincewind/work/rincewind_id_ed25519 -N '' \
        -C 'rincewind@wizzards-retreat' && \
    mkdir -p /home/rincewind/.ssh && \
    cat /home/rincewind/work/rincewind_id_ed25519.pub \
        >> /home/rincewind/.ssh/authorized_keys && \
    rm /home/rincewind/work/rincewind_id_ed25519.pub

RUN chown -R rincewind:rincewind /home/rincewind/ && \
    chmod 600 /home/rincewind/.ssh-keys/uupl_eng_key && \
    chmod 644 /home/rincewind/.ssh-keys/uupl_eng_key.pub && \
    chmod 700 /home/rincewind/.vpn /home/rincewind/.ssh-keys \
              /home/rincewind/.ssh && \
    chmod 600 /home/rincewind/.ssh/authorized_keys

# Allow smbclient to negotiate legacy SMB1/NT1 as used by hex-legacy-1
RUN printf '\n[global]\n    client min protocol = NT1\n' >> /etc/samba/smb.conf

# NFS-Ganesha config (user-space NFS server, no kernel modules required)
RUN mkdir -p /etc/ganesha /var/run/ganesha /var/log/ganesha
COPY ganesha.conf /etc/ganesha/ganesha.conf

COPY status-server.py /usr/local/bin/status-server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/status-server.py

EXPOSE 22 80 111 2049 20048
ENTRYPOINT ["/entrypoint.sh"]
