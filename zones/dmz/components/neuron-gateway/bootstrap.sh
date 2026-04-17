#!/bin/bash
# Neuron startup wrapper.
# Starts Neuron, waits for the API to respond, bootstraps the MQTT northbound
# node and changes the password on first run, then keeps the process alive.
# Idempotent: if the password has already been changed, the login with the
# factory default simply returns a non-token response and the config step is
# skipped without error.

set -e

/usr/bin/entrypoint.sh &
NEURON_PID=$!

# Wait up to 30 s for the API to come up
echo "[neuron-bootstrap] Waiting for API..."
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:7000/api/v2/ping >/dev/null 2>&1 && break
    sleep 1
done

# Try to log in with the factory default. If the password has already been
# changed (container restart), this returns an error body with no token field
# and TOKEN stays empty — the config block is skipped cleanly.
TOKEN=$(curl -s -X POST http://127.0.0.1:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"0000"}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null \
    || true)

if [ -n "$TOKEN" ]; then
    echo "[neuron-bootstrap] Configuring MQTT northbound node..."

    curl -s -X POST http://127.0.0.1:7000/api/v2/node \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"name":"uupl-mqtt-north","plugin":"MQTT"}' >/dev/null 2>&1 || true

    curl -s -X POST http://127.0.0.1:7000/api/v2/node/setting \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"node":"uupl-mqtt-north","params":{"version":4,"client-id":"neuron-sorting-office","qos":0,"format":0,"upload_err":true,"enable_topic":true,"write-req-topic":"/neuron/sorting-office/write/req","write-resp-topic":"/neuron/sorting-office/write/resp","upload_drv_state":false,"offline-cache":false,"host":"10.10.5.12","port":1883,"username":"","password":"","ssl":false}}' \
        >/dev/null 2>&1 || true

    curl -s -X POST http://127.0.0.1:7000/api/v2/password \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"name":"admin","old_pass":"0000","new_pass":"uupl2015"}' \
        >/dev/null 2>&1 || true

    echo "[neuron-bootstrap] Done. admin password set to uupl2015."
else
    echo "[neuron-bootstrap] Already configured or login unavailable, continuing."
fi

wait $NEURON_PID
