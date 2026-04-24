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

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.2.30/32 10.10.3.203

exec python3 /opt/relay/relay_server.py
