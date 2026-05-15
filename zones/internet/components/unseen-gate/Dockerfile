FROM debian:bookworm-slim

# deb.debian.org is fronted by Fastly; specific POPs degraded from this host.
# Pin to a direct NL mirror.
RUN sed -i 's|deb.debian.org|ftp.nl.debian.org|g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    iputils-ping \
    net-tools \
    netcat-openbsd \
    nmap \
    curl \
    wget \
    python3 \
    python3-pip \
    python3-venv \
    smbclient \
    hydra \
    tcpdump \
    socat \
    ftp \
    nfs-common \
    rpcbind \
    netbase \
    iproute2 \
    sudo \
    dnsutils \
    && rm -rf /var/lib/apt/lists/*

# /usr/sbin (showmount, mount.nfs) is not in non-root PATH on Debian bookworm
RUN echo 'export PATH="$PATH:/usr/sbin:/sbin"' > /etc/profile.d/sbin-path.sh

# CTF players need to mount NFS shares; sudo lets them do it without a root shell
RUN echo "ALL ALL=(root) NOPASSWD: /usr/bin/mount, /usr/bin/umount" \
    > /etc/sudoers.d/ctf-mount && chmod 440 /etc/sudoers.d/ctf-mount

# Python attacker libs in a venv (bookworm enforces PEP 668)
# Generic red-team kit only. ICS-protocol libraries (pymodbus, opcua) live
# on hosts where their presence is legitimate, not on a squatted gateway.
# dnslib is the small DNS library used by the cache-poisoning script in
# books/dns-recon-and-poison.md; sits naturally in a researcher's toolkit
# alongside paramiko/scapy/impacket.
RUN python3 -m venv /opt/attacker-env && \
    /opt/attacker-env/bin/pip install --no-cache-dir \
        paramiko \
        impacket \
        scapy \
        dnslib

# Five adversary accounts: UU research group, key-only auth enforced; keys mounted at runtime
RUN for u in ponder hex ridcully librarian dean; do \
        useradd -m -s /bin/bash "$u"; \
        mkdir -p /home/$u/.ssh; \
        chmod 700 /home/$u/.ssh; \
        chown $u:$u /home/$u/.ssh; \
    done

# Create wordlist directory
RUN mkdir -p /usr/share/wordlists

COPY common-passwords.txt /usr/share/wordlists/rockyou.txt

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
