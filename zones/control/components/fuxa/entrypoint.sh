#!/bin/sh
# UU P&L FUXA entrypoint.
#
# Seed an initial project that references the turbine PLC by hostname and IP
# so visitors browsing the HMI see real OT device names. The project is
# placed in _appdata before FUXA starts; FUXA loads it on first boot. The
# project is intentionally simple, the lab's interesting surface is the
# CVE-laden API, not the dashboard widgets.
set -e

APP_DATA=/usr/src/app/FUXA/server/_appdata
PROJECT_FILE="$APP_DATA/project.fuxap"

mkdir -p "$APP_DATA"

if [ ! -s "$PROJECT_FILE" ]; then
    cat > "$PROJECT_FILE" <<'PROJ'
{
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
      "name": "hex-turbine-plc",
      "type": "ModbusTCP",
      "enabled": true,
      "polling": 1000,
      "property": {
        "address": "10.10.3.21",
        "port": 502,
        "slave_id": 1
      },
      "tags": {
        "turbine_rpm": {
          "id": "turbine_rpm",
          "name": "turbine_rpm",
          "type": "uint16",
          "memaddress": "HoldingRegister",
          "address": "0"
        }
      }
    }
  },
  "hmi": {
    "views": [
      {
        "id": "view_overview",
        "name": "Plant Overview",
        "profile": {"bkcolor": "#1e1e1e", "fgcolor": "#cccccc"},
        "items": {}
      }
    ]
  }
}
PROJ
fi

exec docker-entrypoint.sh npm start
