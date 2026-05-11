FROM python:3.11-slim-bookworm

WORKDIR /opt/meter

RUN printf 'Acquire::Retries "10";\nAcquire::http::Timeout "60";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 \
        snmpd \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9

COPY snmpd.conf /etc/snmp/snmpd.conf
COPY meter_server.py /opt/meter/meter_server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502 161/udp

ENTRYPOINT ["/entrypoint.sh"]
