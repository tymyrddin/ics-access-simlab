#!/bin/bash
set -euo pipefail
mkdir -p /var/run/agentx
snmpd -C -c /etc/snmp/snmpd.conf -f &
exec python3 /opt/meter/meter_server.py
