FROM python:3.11-slim

WORKDIR /opt/plc

RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 \
        snmpd \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9 paho-mqtt==1.6.1

COPY snmpd.conf /etc/snmp/snmpd.conf
COPY plc_server.py /opt/plc/plc_server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502 20000 2404 161/udp

ENTRYPOINT ["/entrypoint.sh"]
