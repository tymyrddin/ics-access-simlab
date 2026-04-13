#!/bin/bash
set -euo pipefail

RELAY_ID="${RELAY_ID:-a}"
FEEDER="${FEEDER:-Unknown Feeder}"

mkdir -p /var/run/agentx

# Build snmpd.conf from template, substituting relay identity
sed \
  -e "s/{{RELAY_ID}}/${RELAY_ID}/g" \
  -e "s/{{FEEDER}}/${FEEDER}/g" \
  /opt/relay/snmpd.conf.template > /etc/snmp/snmpd.conf

snmpd -C -c /etc/snmp/snmpd.conf -f &

exec python3 /opt/relay/relay_server.py
