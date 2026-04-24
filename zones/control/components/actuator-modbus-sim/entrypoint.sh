#!/bin/sh
set -e

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.2.30/32 10.10.3.203

ACTUATOR_TYPE="${ACTUATOR_TYPE:-valve}"
PROFILE="/sim/configs/${ACTUATOR_TYPE}-profile.json"

if [ "$ACTUATOR_TYPE" = "breaker" ]; then
    exec pymodbus-sim --port 502 \
        --profile "$PROFILE" \
        --script /sim/scripts/breaker-logic.py \
        --delay 0.1
else
    exec pymodbus-sim --port 502 \
        --profile "$PROFILE"
fi
