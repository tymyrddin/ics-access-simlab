# scada-server — city-wide distribution SCADA
#
# Aggregates plant state from the historian and presents it as an operator
# dashboard. Added when the Archchancellor asked for "something he could look at
# without having to talk to Ponder every time."
#
# Web interface on :8080. SSH on :22 presents a Windows Server 2016 facade.
# The web credentials were set at installation and documented in the network
# inventory on hex-legacy-1.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    openssh-server \
    openssh-client \
    curl \
    net-tools \
    iputils-ping \
    nmap \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv
ENV PATH="/venv/bin:$PATH"

WORKDIR /opt/scada

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY entrypoint.sh /entrypoint.sh
COPY winserver2016_shell.sh /usr/local/bin/winserver2016_shell.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/winserver2016_shell.sh

RUN useradd -m -s /usr/local/bin/winserver2016_shell.sh scada_admin
RUN echo "scada_admin:W1nd0ws@2016" | chpasswd

ENV HISTORIAN_IP=10.10.2.10
ENV WEB_PORT=8080

EXPOSE 22 8080

ENTRYPOINT ["/entrypoint.sh"]
