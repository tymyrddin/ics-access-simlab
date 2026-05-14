#!/bin/sh
# UU P&L FUXA entrypoint.
#
# Start FUXA, then seed an initial project via the API so it persists to
# the SQLite database. The seeded project references the turbine PLC so
# visitors see real OT device names when they browse the HMI.
set -e

# Start FUXA in the background.
docker-entrypoint.sh npm start &
PID=$!

# Wait for :1881 to be ready by polling the API. Use curl retries.
echo "[fuxa-init] Waiting for API to be ready..."
for i in $(seq 1 30); do
    if curl -s http://localhost:1881/api/project >/dev/null 2>&1; then
        echo "[fuxa-init] API is ready."
        break
    fi
    sleep 1
done

# Seed the project via POST /api/project so it persists to the database.
# Use an empty devices object to avoid "plugin not found" warnings on ModbusTCP.
echo "[fuxa-init] Seeding UUPL project..."
curl -s -X POST http://localhost:1881/api/project \
  -H 'Content-Type: application/json' \
  -d '{
    "version": "1.00",
    "server": {
      "id": "0",
      "name": "UUPL Control HMI",
      "type": "FuxaServer",
      "property": {}
    },
    "devices": {},
    "hmi": {
      "views": []
    }
  }' >/dev/null 2>&1 || true

echo "[fuxa-init] FUXA seeding complete."

# Bring FUXA process to foreground so container lifecycle is tied to it.
wait $PID
