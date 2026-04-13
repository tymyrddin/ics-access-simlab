FROM python:3.11-slim

WORKDIR /opt/meter

RUN apt-get update && apt-get install -y --no-install-recommends \
        snmpd \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9

COPY snmpd.conf /etc/snmp/snmpd.conf
COPY meter_server.py /opt/meter/meter_server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502 161/udp

ENTRYPOINT ["/entrypoint.sh"]
