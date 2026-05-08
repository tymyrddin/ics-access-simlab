FROM python:3.11-slim-bookworm
# UU P&L substation RTU. Custom Python service that exposes both:
#   :2404  IEC-60870-5-104 protocol, no auth
#   :8080  REST management API, no auth
# Datapoints are mutable at runtime via REST, picked up by the IEC-104 server
# on the next periodic report. Vendor-style management UI on the same host is
# a real OT pattern: engineers commission via the web, then forget to firewall.
#
# Replaces the upstream ghcr.io/richyp7/iec60870-5-104-simulator image, which
# only speaks IEC-104 and has an empty Kestrel on :8080.
#
# Pinned to bookworm to match the rest of the lab and avoid the trixie
# transitional g++-14 dependency tree that currently breaks slim builds.

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# c104 publishes manylinux wheels for cpython 3.11/x86_64; --only-binary
# refuses to fall back to source build, so we fail loud here if the wheel is
# missing rather than silently dragging in a build toolchain.
RUN pip install --no-cache-dir --only-binary=c104 c104==2.0.1 flask==3.0.3

COPY rtu_config.json /app/rtu_config.json
COPY rtu_server.py   /app/rtu_server.py
COPY entrypoint.sh   /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh

EXPOSE 2404 8080
ENTRYPOINT ["/dmz-entrypoint.sh"]