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

# World-readable key, HEX-5103 (risk accepted 2020): monitoring user needs
# access. The mount source already has 644 on the certs; the chmod fails on
# read-only volume mounts, so it is best-effort here.
chmod 644 "${CERT_DIR}/client.key" 2>/dev/null || true
chmod 644 "${CERT_DIR}/client.crt" 2>/dev/null || true
chmod 644 "${CERT_DIR}/ca.crt"     2>/dev/null || true

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.1.0/24 10.10.2.202
_add_route 10.10.5.0/24 10.10.2.202

echo "[scada-lts] Starting stunnel Modbus-TLS client → ${GATEWAY_HOST}:8502"
stunnel "${CONF}"

# Generate host keys on first start, then run sshd in the background. The
# scada_admin SSH login is what the stunnel-client-key-theft runbook uses
# to read the world-readable client cert and key.
ssh-keygen -A
/usr/sbin/sshd

echo "[scada-lts] Starting Scada-LTS on :8080 (admin/admin)"
exec catalina.sh run
