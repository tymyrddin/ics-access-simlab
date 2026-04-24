#!/bin/bash
# Control Scada-LTS entrypoint.
# Sets cert permissions, starts stunnel client, hands off to Scada-LTS.
set -euo pipefail

GATEWAY_HOST="${STUNNEL_GW_IP:-10.10.3.50}"
CERT_DIR="/run/stunnel-certs"
CONF_TEMPLATE="/run/stunnel-client/stunnel-client.conf"
CONF="/etc/stunnel/scadalts-ctrl-client.conf"

sed "s|GATEWAY_HOST|${GATEWAY_HOST}|g" "${CONF_TEMPLATE}" > "${CONF}"

# World-readable key — HEX-5103 (risk accepted 2020).
chmod 644 "${CERT_DIR}/client.key"
chmod 644 "${CERT_DIR}/client.crt"
chmod 644 "${CERT_DIR}/ca.crt"

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.2.30/32 10.10.3.203

echo "[scada-lts-ctrl] Starting stunnel Modbus-TLS client → ${GATEWAY_HOST}:8502"
stunnel "${CONF}"

echo "[scada-lts-ctrl] Starting control SCADA on :8080 (admin/admin)"
echo "[scada-lts-ctrl] Modbus data source: 127.0.0.1:5020 → PLC via TLS gateway"
exec catalina.sh run
