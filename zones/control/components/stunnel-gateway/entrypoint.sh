#!/bin/sh
# stunnel-gateway entrypoint.
# Substitutes FORWARD_TARGET from env into config, then execs stunnel.
set -eu

FORWARD_TARGET="${FORWARD_TARGET:-10.10.3.21:502}"
CONF=/etc/stunnel/stunnel.conf

# Write config from template (already copied to CONF by compose volume mount)
sed "s|FORWARD_TARGET|${FORWARD_TARGET}|g" /run/stunnel/stunnel.conf > "${CONF}"

chmod 600 /run/stunnel/server.key

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.1.0/24 10.10.2.202

echo "[stunnel-gateway] Listening :8502 (TLS mTLS) → ${FORWARD_TARGET} (plain Modbus)"
exec stunnel "${CONF}"
