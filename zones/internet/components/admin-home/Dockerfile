FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    iputils-ping \
    net-tools \
    curl \
    wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

# Remote administrator account — weak password is the vulnerability
RUN useradd -m -s /bin/bash rincewind && \
    echo "rincewind:wizzard" | chpasswd

# SSH: password auth allowed (deliberately weak)
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Flask status app (default admin:admin credentials — never rotated)
RUN python3 -m venv /opt/status-env && \
    /opt/status-env/bin/pip install --no-cache-dir flask
COPY app/status.py /opt/status.py

# Loot: VPN config, SSH key for engineering workstation, notes
COPY loot/vpn/   /home/rincewind/.vpn/
COPY loot/ssh/   /home/rincewind/.ssh-keys/
COPY loot/notes.txt /home/rincewind/notes.txt

RUN chown -R rincewind:rincewind /home/rincewind/ && \
    chmod 600 /home/rincewind/.ssh-keys/uupl_eng_key && \
    chmod 644 /home/rincewind/.ssh-keys/uupl_eng_key.pub && \
    chmod 700 /home/rincewind/.vpn /home/rincewind/.ssh-keys

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 80
ENTRYPOINT ["/entrypoint.sh"]
