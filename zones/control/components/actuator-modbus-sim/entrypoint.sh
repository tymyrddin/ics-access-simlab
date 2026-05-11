#!/bin/sh
# Actuator Modbus-TCP simulator entrypoint.
# Routing handled by the FRR fabric; no per-service _add_route.
set -e

ACTUATOR_TYPE="${ACTUATOR_TYPE:-valve}"
PROFILE="/sim/configs/${ACTUATOR_TYPE}-profile.json"
SCRIPT="/sim/scripts/${ACTUATOR_TYPE}-logic.py"

if [ ! -f "$PROFILE" ]; then
    echo "[actuator] ERROR: profile $PROFILE not found." >&2
    exit 1
fi

if [ -f "$SCRIPT" ]; then
    exec python3 /sim/runner.py --port 502 --profile "$PROFILE" \
        --script "$SCRIPT" --delay 0.1
else
    exec python3 /sim/runner.py --port 502 --profile "$PROFILE"
fi
