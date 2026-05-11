FROM python:3.11-slim-bookworm

WORKDIR /sim

RUN printf 'Acquire::Retries "10";\nAcquire::http::Timeout "60";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pymodbus==3.6.9

COPY configs/    /sim/configs/
COPY scripts/    /sim/scripts/
COPY runner.py   /sim/runner.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 502
ENTRYPOINT ["/entrypoint.sh"]
