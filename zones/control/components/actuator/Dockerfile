FROM python:3.11-slim

WORKDIR /opt/actuator

RUN pip install --no-cache-dir pymodbus==3.6.9

COPY actuator_server.py /opt/actuator/actuator_server.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502

ENTRYPOINT ["/entrypoint.sh"]
