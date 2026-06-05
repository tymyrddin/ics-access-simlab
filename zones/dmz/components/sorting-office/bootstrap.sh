#!/bin/bash
# Neuron startup wrapper and process supervisor.
# Starts Neuron, waits for the API to respond, bootstraps the MQTT northbound
# node and changes the password on first run, then supervises the Neuron
# process. If Neuron exits it is respawned in place rather than allowed to take
# PID 1 down with it: a container restart destroys the netns, and clab does not
# re-attach eth1 on restart (the host veth is gone), leaving the node
# single-homed and unreachable on 10.10.5.0/24. Keeping PID 1 alive across a
# Neuron crash preserves the netns and its eth1. See docs/to-investigate.md,
# "DMZ veth lost when a clab node restarts".
# Idempotent: if the password has already been changed, the login with the
# factory default returns a non-token response and the config step is skipped.

set -e

# Re-attach the lab IP if eth1 exists but lost its address. This cannot help
# after a full container restart (eth1 is gone entirely then); the supervisor
# below is what prevents that restart in the first place.
if ! ip addr show dev eth1 2>/dev/null | grep -q '10\.10\.5\.11'; then
    echo "[neuron-bootstrap] eth1 lacks lab IP, restoring 10.10.5.11/24..."
    ip addr add 10.10.5.11/24 dev eth1 || true
    ip link set eth1 up || true
    ip route replace default via 10.10.5.201 || true
fi

NEURON_PID=""
SHUTTING_DOWN=0

# Forward SIGTERM/SIGINT to Neuron and stop supervising, so `docker stop`
# (./ctl down) exits promptly instead of triggering a respawn.
terminate() {
    SHUTTING_DOWN=1
    [ -n "$NEURON_PID" ] && kill -TERM "$NEURON_PID" 2>/dev/null || true
}
trap terminate TERM INT

start_neuron() {
    /usr/bin/entrypoint.sh &
    NEURON_PID=$!
}

start_neuron

# Wait up to 30 s for the API to come up
echo "[neuron-bootstrap] Waiting for API..."
for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:7000/api/v2/ping >/dev/null 2>&1 && break
    sleep 1
done

# First-run configuration. On a later start the password is no longer the
# factory default, login returns no token, and this block is skipped cleanly.
TOKEN=$(curl -s -X POST http://127.0.0.1:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"0000"}' \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' \
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

# Supervise: if Neuron exits while we are not shutting down, respawn it so the
# container, and its clab-attached eth1, stays up.
while true; do
    wait "$NEURON_PID" || true
    [ "$SHUTTING_DOWN" -eq 1 ] && break
    echo "[neuron-bootstrap] Neuron exited unexpectedly, respawning in 2s..." >&2
    sleep 2
    start_neuron
done
