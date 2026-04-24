#!/usr/bin/env bash
# historian entrypoint
# Sets up SSH with Windows Server 2019 facade, seeds the database,
# builds virtual Windows filesystem, then starts sshd and Flask.
set -e

DB_PATH="${DB_PATH:-/opt/historian/data/historian.db}"
DATA_SOURCE="${DATA_SOURCE:-intelligent_electronic_device}"
PROFILE="/opt/winsvr/C/Users/hist_admin"

# ── SSH ───────────────────────────────────────────────────────────────────────

mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
PrintMotd no
EOF

# ── Database ──────────────────────────────────────────────────────────────────

echo "[historian] Data source: $DATA_SOURCE"
echo "[historian] DB path: $DB_PATH"

if [ ! -f "$DB_PATH" ]; then
    echo "[historian] Seeding database..."
    python3 /opt/historian/data/seed.py "$DATA_SOURCE" "$DB_PATH"
fi

# ── Virtual C: drive ──────────────────────────────────────────────────────────

mkdir -p \
    "$PROFILE/Desktop" \
    "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine" \
    "/opt/winsvr/C/Historian/Config" \
    "/opt/winsvr/C/Historian/Data" \
    "/opt/winsvr/C/Historian/Archive"

# ── C:\Historian\Config\historian.ini ─────────────────────────────────────────

cat > "/opt/winsvr/C/Historian/Config/historian.ini" << EOF
; UU P&L Process Historian — Configuration
; Installed: 1997-03-22
; Last modified: 2019-04-07 (added /ingest endpoint for RTU feeds)
; Contact: ponder.stibbons@uupl.am

[database]
; SQLite database. Path on this server: /opt/historian/data/historian.db
; Export via web: http://10.10.2.10:8080/export?tag=<filename>
path     = C:\Historian\Data\historian.db
user     = historian
password = Historian2015

[web]
port     = 8080
; No authentication on read endpoints — "internal network only"
; /report  — query time-series (SQLi present — HEX-1847, closed won't-fix 2019)
; /export  — serve export files (path traversal — HEX-2291, never filed)
; /ingest  — write data (auth: hist_read / history2017)
; /assets  — list asset names (no auth)
; /status  — health check (no auth)

[ingest]
user     = hist_read
password = history2017

[admin]
ssh_user = hist_admin
ssh_pass = Historian2015
notes    = Same password as database — "easier to remember" — P.S.
EOF

cat > "/opt/winsvr/C/Historian/Config/data_sources.xml" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- UU P&L Historian — RTU Data Source Configuration -->
<!-- Written: 2019-04-07  Added city RTU feeds via /ingest endpoint -->
<DataSources>
  <Source name="turbine_plc" type="modbus-tcp">
    <IP>10.10.3.21</IP>
    <Port>502</Port>
    <Tags>turbine_rpm,turbine_temperature,turbine_pressure</Tags>
    <PollInterval>60</PollInterval>
  </Source>
  <Source name="meter_main" type="modbus-tcp">
    <IP>10.10.3.33</IP>
    <Port>502</Port>
    <Tags>meter_power_kw,line_voltage_a,line_voltage_b</Tags>
    <PollInterval>60</PollInterval>
  </Source>
</DataSources>
EOF

# ── C:\Historian\Data\ ────────────────────────────────────────────────────────

cat > "/opt/winsvr/C/Historian/Data/README.txt" << 'EOF'
C:\Historian\Data\
==================
The historian database lives here. Do not move or delete.

  historian.db    — SQLite database, ~80 MB, 30 days of 1-minute readings

To query directly:
  sqlite3 historian.db "SELECT * FROM readings WHERE asset='turbine_rpm' LIMIT 10;"
  sqlite3 historian.db "SELECT * FROM alarm_config;"
  sqlite3 historian.db "SELECT * FROM config;"

The web interface (/report, /export) is the preferred access method.
The DB file is also accessible via the /export path traversal:
  http://10.10.2.10:8080/export?tag=../historian.db

Note: the config table contains the database credentials. See historian.ini.
EOF

# ── C:\Historian\Archive\ ────────────────────────────────────────────────────

cat > "/opt/winsvr/C/Historian/Archive/export_schedule.txt" << 'EOF'
UU P&L Historian — Nightly Export Schedule
==========================================
Generated files are served at http://10.10.2.10:8080/export?tag=<filename>
Path traversal: tag=../historian.db serves the raw database file.

Schedule (runs at 01:00 daily via Task Scheduler):
  turbine_rpm.csv       — turbine speed, 24h
  line_voltage_a.csv    — feeder A voltage, 24h
  line_voltage_b.csv    — feeder B voltage, 24h
  line_current_a.csv    — feeder A current, 24h

Files are written to C:\Historian\Data\exports\ (Linux: /opt/historian/data/exports/)
EOF

# ── PSReadLine history ────────────────────────────────────────────────────────

cat > "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" << 'HIST'
cd C:\Historian\Config
Get-Content .\historian.ini
cd C:\Historian\Data
dir
curl http://localhost:8080/status
curl "http://localhost:8080/report?asset=turbine_rpm&from=2026-03-01&to=2026-03-08"
curl "http://localhost:8080/assets"
curl "http://localhost:8080/export?tag=turbine_rpm.csv"
sqlite3 historian.db ".tables"
sqlite3 historian.db "SELECT * FROM config;"
sqlite3 historian.db "SELECT * FROM alarm_config;"
cd ~
dir
HIST

cat > "$PROFILE/Desktop/README.txt" << 'EOF'
HIST-SRV01 — Quick Reference
==============================

Web interface:  http://10.10.2.10:8080/
  /report       — query data (SQL injection in asset parameter)
  /export       — serve exports (path traversal in tag parameter)
  /ingest       — write data (POST, auth: hist_read/history2017)
  /assets       — list assets (no auth)
  /status       — health check (no auth)

Database:  C:\Historian\Data\historian.db
Config:    C:\Historian\Config\historian.ini
EOF

# ── Permissions ───────────────────────────────────────────────────────────────

chown -R hist_admin:hist_admin /opt/winsvr
chmod 600 "/opt/winsvr/C/Historian/Config/historian.ini"

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.1.0/24 10.10.2.202
_add_route 10.10.5.0/24 10.10.2.202

# ── Start services ────────────────────────────────────────────────────────────

/usr/sbin/sshd
echo "[historian] Starting web interface on :8080"
exec python3 /opt/historian/app/server.py
