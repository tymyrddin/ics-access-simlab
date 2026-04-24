# historian — process data logger
#
# Stores time-series data from ICS sensors and makes it available via a
# web interface for report generation and trend analysis.
#
# Installed in 1997. The web interface was added later when someone asked
# for remote access to reports. The database has been running continuously
# since then. The schema has accreted. The credentials have not changed.
#
# Web interface on :8080. SSH on :22 presents a Windows Server 2019 facade.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    python3 \
    python3-venv \
    sqlite3 \
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

WORKDIR /opt/historian

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY data/ ./data/
COPY entrypoint.sh /entrypoint.sh
COPY winserver2019_shell.sh /usr/local/bin/winserver2019_shell.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/winserver2019_shell.sh

# Pre-generated export files served by /export endpoint.
RUN mkdir -p /opt/historian/data/exports

RUN useradd -m -s /usr/local/bin/winserver2019_shell.sh hist_admin
RUN echo "hist_admin:Historian2015" | chpasswd

ENV DATA_SOURCE=intelligent_electronic_device
ENV DB_PATH=/opt/historian/data/historian.db

EXPOSE 22 8080

ENTRYPOINT ["/entrypoint.sh"]
