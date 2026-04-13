#!/bin/bash
# Scada-LTS entrypoint.
# Sets cert permissions, starts stunnel client, then hands off to Scada-LTS.
set -euo pipefail

GATEWAY_HOST="${STUNNEL_GW_IP:-10.10.2.50}"
CERT_DIR="/run/stunnel-certs"
CONF_TEMPLATE="/run/stunnel-client/stunnel-client.conf"
CONF="/etc/stunnel/scadalts-client.conf"

# Substitute gateway IP
sed "s|GATEWAY_HOST|${GATEWAY_HOST}|g" "${CONF_TEMPLATE}" > "${CONF}"

# World-readable key — HEX-5103 (risk accepted 2020): monitoring user needs access.
chmod 644 "${CERT_DIR}/client.key"
chmod 644 "${CERT_DIR}/client.crt"
chmod 644 "${CERT_DIR}/ca.crt"

echo "[scada-lts] Starting stunnel Modbus-TLS client → ${GATEWAY_HOST}:8502"
stunnel "${CONF}"

echo "[scada-lts] Starting Scada-LTS on :8080 (admin/admin)"
exec catalina.sh run
