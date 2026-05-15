#!/bin/bash
set -euo pipefail

# snmpd needs /var/run/agentx to exist
mkdir -p /var/run/agentx

# Start SNMP daemon in background
snmpd -C -c /etc/snmp/snmpd.conf -f &

exec python3 /opt/plc/plc_server.py
