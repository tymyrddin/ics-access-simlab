FROM python:3.11-slim

WORKDIR /opt/relay

RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 \
        snmpd \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9 flask==3.0.3 paho-mqtt==1.6.1

COPY snmpd.conf.template /opt/relay/snmpd.conf.template
COPY relay_server.py /opt/relay/relay_server.py
COPY templates/ /opt/relay/templates/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502 8081 161/udp

ENTRYPOINT ["/entrypoint.sh"]
