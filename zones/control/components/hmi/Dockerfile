FROM python:3.11-slim

WORKDIR /opt/hmi

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9 flask==3.0.3

# Copy files before creating the user so the shell exists when useradd validates it
COPY hmi_shell.py /opt/hmi/hmi_shell.py
COPY hmi_server.py /opt/hmi/hmi_server.py
COPY templates/ /opt/hmi/templates/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /opt/hmi/hmi_shell.py && \
    mkdir -p /var/run/sshd && \
    useradd -m -N -s /opt/hmi/hmi_shell.py operator && \
    echo "operator:operator" | chpasswd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config

EXPOSE 22 502 8080

ENTRYPOINT ["/entrypoint.sh"]
