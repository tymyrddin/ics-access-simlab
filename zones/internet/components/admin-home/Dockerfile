FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    iputils-ping \
    net-tools \
    curl \
    rpcbind \
    netbase \
    nfs-ganesha \
    nfs-ganesha-vfs \
    && rm -rf /var/lib/apt/lists/*

# Remote administrator account — weak password is the vulnerability
RUN useradd -m -s /bin/bash rincewind && \
    echo "rincewind:wizzard" | chpasswd

# SSH: password auth allowed (deliberately weak)
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Loot: VPN config, SSH key for engineering workstation, notes
COPY loot/vpn/   /home/rincewind/.vpn/
COPY loot/ssh/   /home/rincewind/.ssh-keys/
COPY loot/notes.txt /home/rincewind/notes.txt

# NFS work share — world-readable, no auth required (misconfiguration)
RUN mkdir -p /home/rincewind/work
COPY loot/notes.txt /home/rincewind/work/notes.txt
RUN chmod 755 /home/rincewind/work && \
    chmod 644 /home/rincewind/work/notes.txt

# Rincewind's SSH keypair. Public key goes into authorized_keys so key login works.
# Private key copy left in work/ — the entrypoint stages work/ to the NFS export with
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

# NFS-Ganesha config (user-space NFS server — no kernel modules required)
RUN mkdir -p /etc/ganesha /var/run/ganesha /var/log/ganesha
COPY ganesha.conf /etc/ganesha/ganesha.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 111 2049 20048
ENTRYPOINT ["/entrypoint.sh"]
