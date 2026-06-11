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
# Devices and tags surface in GET /api/project (unauthenticated) as visitor loot.
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
    "devices": {
      "hex-turbine-plc": {
        "id": "hex-turbine-plc",
        "name": "Hex Turbine PLC",
        "type": "ModbusTCP",
        "enabled": true,
        "property": {
          "address": "10.10.3.21",
          "port": "502",
          "slaveid": "1"
        },
        "tags": {
          "turbine_rpm":          { "id": "turbine_rpm",          "name": "Turbine RPM",             "type": "UInt16", "memaddress": "300000", "address": "1" },
          "turbine_temperature_c":{ "id": "turbine_temperature_c","name": "Turbine Temperature (C)", "type": "UInt16", "memaddress": "300000", "address": "2" },
          "turbine_pressure_bar": { "id": "turbine_pressure_bar", "name": "Turbine Pressure (bar)",  "type": "UInt16", "memaddress": "300000", "address": "3" },
          "line_voltage_a_v":     { "id": "line_voltage_a_v",     "name": "Line Voltage A (V)",      "type": "UInt16", "memaddress": "300000", "address": "4" },
          "line_current_a_a":     { "id": "line_current_a_a",     "name": "Line Current A (A)",      "type": "UInt16", "memaddress": "300000", "address": "5" },
          "line_voltage_b_v":     { "id": "line_voltage_b_v",     "name": "Line Voltage B (V)",      "type": "UInt16", "memaddress": "300000", "address": "6" },
          "line_current_b_a":     { "id": "line_current_b_a",     "name": "Line Current B (A)",      "type": "UInt16", "memaddress": "300000", "address": "7" },
          "frequency_hz_x10":     { "id": "frequency_hz_x10",     "name": "Frequency Hz x10",        "type": "UInt16", "memaddress": "300000", "address": "8" },
          "power_kw":             { "id": "power_kw",             "name": "Power (kW)",              "type": "UInt16", "memaddress": "300000", "address": "9" },
          "governor_setpoint_rpm":{ "id": "governor_setpoint_rpm","name": "Governor Setpoint RPM",   "type": "UInt16", "memaddress": "400000", "address": "1" },
          "fuel_valve_command":   { "id": "fuel_valve_command",   "name": "Fuel Valve Command",      "type": "UInt16", "memaddress": "400000", "address": "2" },
          "cooling_pump_speed":   { "id": "cooling_pump_speed",   "name": "Cooling Pump Speed",      "type": "UInt16", "memaddress": "400000", "address": "3" },
          "overcurrent_threshold":{ "id": "overcurrent_threshold","name": "Overcurrent Threshold (A)","type": "UInt16", "memaddress": "400000", "address": "4" },
          "emergency_stop":       { "id": "emergency_stop",       "name": "Emergency Stop",          "type": "Bool",   "memaddress": "0",      "address": "1" }
        }
      }
    },
    "hmi": {
      "views": []
    }
  }' >/dev/null 2>&1 || true

echo "[fuxa-init] FUXA seeding complete."

# Bring FUXA process to foreground so container lifecycle is tied to it.
wait $PID
