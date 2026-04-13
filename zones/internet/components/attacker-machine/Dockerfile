FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    iputils-ping \
    net-tools \
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
    && rm -rf /var/lib/apt/lists/*

# Python attacker libs in a venv (bookworm enforces PEP 668)
RUN python3 -m venv /opt/attacker-env && \
    /opt/attacker-env/bin/pip install --no-cache-dir \
        pymodbus==3.6.9 \
        paramiko \
        impacket

# Five adversary accounts: UU research group — key-only auth enforced; keys mounted at runtime
RUN for u in ponder hex ridcully librarian dean; do \
        useradd -m -s /bin/bash "$u"; \
        mkdir -p /home/$u/.ssh; \
        chmod 700 /home/$u/.ssh; \
        chown $u:$u /home/$u/.ssh; \
    done

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
