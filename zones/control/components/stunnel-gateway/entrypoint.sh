#!/bin/sh
# stunnel-gateway entrypoint.
# Substitutes FORWARD_TARGET from env into config, then execs stunnel.
set -eu

FORWARD_TARGET="${FORWARD_TARGET:-10.10.3.21:502}"
CONF=/etc/stunnel/stunnel.conf

# Write config from template (already copied to CONF by compose volume mount)
sed "s|FORWARD_TARGET|${FORWARD_TARGET}|g" /run/stunnel/stunnel.conf > "${CONF}"

# server.key is already 600 from orchestrator/generate.py and the volume is
# mounted :ro, so any chmod here would either be a no-op or crash the
# entrypoint under set -eu. Trust the source perms.

echo "[stunnel-gateway] Listening :8502 (TLS mTLS) → ${FORWARD_TARGET} (plain Modbus)"
exec stunnel "${CONF}"
