#!/bin/sh
set -e

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
