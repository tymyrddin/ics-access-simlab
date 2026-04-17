#!/usr/bin/env bash
# engineering-workstation entrypoint
# Sets up SSH, builds the virtual Windows 10 LTSC profile, and starts sshd.
set -e

ICS_PROCESS="${ICS_PROCESS:-intelligent_electronic_device}"
CONTROL_SUBNET="${CONTROL_SUBNET:-10.10.3.0/24}"

# Virtual Windows profile root
PROFILE="/opt/win10/C/Users/engineer"

mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
PrintMotd no
EOF

# ── Virtual C: drive layout ───────────────────────────────────────────────────

mkdir -p \
    "$PROFILE/Desktop" \
    "$PROFILE/Documents" \
    "$PROFILE/config" \
    "$PROFILE/Tools" \
    "$PROFILE/Projects/PLC" \
    "$PROFILE/Projects/RelayConfigs" \
    "$PROFILE/Projects/Firmware" \
    "$PROFILE/backups" \
    "$PROFILE/.ssh" \
    "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine"

# ── plc-access.conf ───────────────────────────────────────────────────────────

cat > "$PROFILE/config/plc-access.conf" << EOF
# UU P&L — PLC and IED Access Configuration
# Written: 2001-09-03  Author: Ponder Stibbons
# Updated: 2023-06-14  (actuators added; relay web UIs documented)
#
# Format: device, ip, port, protocol, unit_id, notes
# Modbus TCP has no authentication. The network IS the access control.
#
# ICS Process: ${ICS_PROCESS}
# Control network: ${CONTROL_SUBNET}

EOF

case "$ICS_PROCESS" in
    uupl_ied)
        cat >> "$PROFILE/config/plc-access.conf" << 'CONF'
[hex_turbine_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Main turbine PLC. Coil 0 = emergency stop.
           Also: DNP3 :20000, IEC-104 :2404, SNMP :161 (community: public)
           DO NOT write coil 0 without coordination with the duty engineer.

[hmi_main]
ip       = 10.10.3.10
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Operator HMI. Modbus mirror of PLC state; writes forwarded to PLC.
           SSH: operator@10.10.3.10 password: operator (restricted shell)
           Web: http://10.10.3.10:8080/ login: operator/operator

[ied_relay_a]
ip       = 10.10.3.31
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Protective relay, Feeder A (Dolly Sisters). HR[0-2] = protection thresholds.
           Web: http://10.10.3.31:8081/ login: admin/relay1234
           SNMP: community public (read), private (read-write)

[ied_relay_b]
ip       = 10.10.3.32
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Protective relay, Feeder B (Nap Hill). HR[0-2] = protection thresholds.
           Web: http://10.10.3.32:8081/ login: admin/relay1234
           SNMP: community public (read), private (read-write)

[ied_meter_main]
ip       = 10.10.3.33
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Revenue meter — read-only input registers. Report discrepancies to the Bursar.
           SNMP: community public (read)

[actuator_fuel_valve]
ip       = 10.10.3.51
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Fuel valve actuator. HR[0] = position 0-100%. Written by PLC governor loop.

[actuator_cooling_pump]
ip       = 10.10.3.52
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Cooling pump. HR[0] = speed 0-100%. Default: 100%.

[actuator_breaker_a]
ip       = 10.10.3.53
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Feeder A circuit breaker. Coil[0]=state, coil[1]=trip, coil[2]=close.
           Written by relay IED on fault. DO NOT trip without coordination.

[actuator_breaker_b]
ip       = 10.10.3.54
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Feeder B circuit breaker. Coil[0]=state, coil[1]=trip, coil[2]=close.
           Written by relay IED on fault. DO NOT trip without coordination.
CONF
        ;;
    intelligent_electronic_device)
        cat >> "$PROFILE/config/plc-access.conf" << 'CONF'
[hex_turbine_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Main turbine control PLC. Coil 0 = emergency stop.
           DO NOT write coil 0 without coordination with the duty engineer.
CONF
        ;;
    water_bottle_factory)
        cat >> "$PROFILE/config/plc-access.conf" << 'CONF'
[plc_filling_line]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Bottle filling PLC. Coil 102 = input valve, 103 = output valve.

[plc_conveyor]
ip       = 10.10.3.22
port     = 502
protocol = modbus-tcp
unit_id  = 2
notes    = Conveyor and capping line.
CONF
        ;;
    smart_grid)
        cat >> "$PROFILE/config/plc-access.conf" << 'CONF'
[ats_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Automatic transfer switch controller.
CONF
        ;;
esac

# ── Modbus tools ──────────────────────────────────────────────────────────────

cat > "$PROFILE/Tools/modbus_read.py" << 'EOF'
#!/usr/bin/env python3
"""
Quick Modbus read utility.
Usage: python3 modbus_read.py <ip> <port> <register_type> <address> [count]
       register_type: coil | discrete | holding | input
"""
import sys
from pymodbus.client import ModbusTcpClient

def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(1)

    ip, port, reg_type, addr = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    count = int(sys.argv[5]) if len(sys.argv) > 5 else 1

    client = ModbusTcpClient(ip, port=port)
    client.connect()

    if reg_type == "coil":
        result = client.read_coils(addr, count)
        print(result.bits[:count])
    elif reg_type == "discrete":
        result = client.read_discrete_inputs(addr, count)
        print(result.bits[:count])
    elif reg_type == "holding":
        result = client.read_holding_registers(addr, count)
        print(result.registers)
    elif reg_type == "input":
        result = client.read_input_registers(addr, count)
        print(result.registers)
    else:
        print(f"Unknown register type: {reg_type}")

    client.close()

if __name__ == "__main__":
    main()
EOF

cat > "$PROFILE/Tools/modbus_write.py" << 'EOF'
#!/usr/bin/env python3
"""
Quick Modbus write utility.
Usage: python3 modbus_write.py <ip> <port> <register_type> <address> <value>
       register_type: coil | holding
"""
import sys
from pymodbus.client import ModbusTcpClient

def main():
    if len(sys.argv) < 6:
        print(__doc__)
        sys.exit(1)

    ip, port, reg_type, addr, val = (
        sys.argv[1], int(sys.argv[2]), sys.argv[3],
        int(sys.argv[4]), sys.argv[5],
    )

    client = ModbusTcpClient(ip, port=port)
    client.connect()

    if reg_type == "coil":
        client.write_coil(addr, val.lower() in ("1", "true", "on"))
    elif reg_type == "holding":
        client.write_register(addr, int(val))
    else:
        print(f"Unknown register type: {reg_type}")

    client.close()
    print(f"Written {val} to {reg_type}[{addr}] on {ip}:{port}")

if __name__ == "__main__":
    main()
EOF

# ── PLC project file ──────────────────────────────────────────────────────────

cat > "$PROFILE/Projects/PLC/turbine_controller.project" << 'PROJ'
# Hex Steam Turbine — Turbine PLC Project File
# Exported from HexSoft PLC Suite v3.2 — 2019-11-12
# Engineer: Ponder Stibbons
# DO NOT EDIT MANUALLY — use HexSoft PLC Suite

[device]
name             = hex_turbine_controller
ip               = 10.10.3.21
port             = 502
unit_id          = 1
firmware_version = 2.4.1
admin_pass       = turbineadmin

[coil_map]
; Coils (FC1) — read/write, no authentication required on Modbus
0 = emergency_stop      ; write 1 to trip immediately, write 0 to reset
1 = alarm_overspeed     ; set when RPM > 3300
2 = alarm_overtemp      ; set when temp > 490 C

[holding_register_map]
; Holding registers (FC3) — read/write
0 = governor_setpoint_rpm  ; target RPM, default 3000 (range 0-4000)
1 = fuel_valve_command     ; 0-100%, set by governor loop
2 = cooling_pump_speed     ; 0-100%, default 100
3 = overcurrent_threshold  ; amps, default 200

[input_register_map]
; Input registers (FC4) — read-only (physics simulation outputs)
0 = turbine_rpm
1 = turbine_temperature_c
2 = turbine_pressure_bar
3 = line_voltage_v
4 = line_current_a

[alarm_setpoints]
; Setpoints as of 2019 upgrade. Cross-reference historian alarm_config table.
overspeed_trip_rpm    = 3300
overtemp_trip_c       = 490
overpressure_trip_bar = 95
undervoltage_trip_v   = 196
overcurrent_trip_a    = 200
PROJ

cat > "$PROFILE/Projects/RelayConfigs/relay_a_2019.txt" << 'RCONF'
# IED Relay A — Dolly Sisters Feeder
# Configuration snapshot 2019-11-12 (pre-upgrade)
# Saved by Ponder Stibbons before installing web interface firmware

device_ip       = 10.10.3.31
device_port     = 502
unit_id         = 1

# Modbus holding registers (FC3) — protection thresholds
HR[0] undervoltage_threshold_v = 196    ; relay trips if V < this
HR[1] overcurrent_threshold_a  = 200    ; relay trips if I > this
HR[2] overspeed_threshold_rpm  = 3300   ; relay trips if RPM > this

# Coil map
coil[0] = relay_trip_status   ; 1=tripped, writable (force-trip)

# Note: HR values are writable via Modbus with no authentication.
# Reducing undervoltage threshold allows fault to persist without trip.
# Raising overcurrent threshold disables overcurrent protection.
RCONF

cp "$PROFILE/Projects/RelayConfigs/relay_a_2019.txt" \
   "$PROFILE/Projects/RelayConfigs/relay_b_2019.txt"
sed -i 's/Relay A/Relay B/; s/Dolly Sisters/Nap Hill/; s/10\.10\.3\.31/10.10.3.32/' \
    "$PROFILE/Projects/RelayConfigs/relay_b_2019.txt"

cat > "$PROFILE/Projects/Firmware/README.txt" << 'FWREADME'
PLC Firmware Update Procedure
==============================
Last updated: 2023-09-14  Author: Ponder Stibbons

Prerequisites:
  - Maintenance window confirmed with duty engineer
  - Backup current PLC config: see Tools\update_plc_firmware.ps1
  - Firmware file: request from vendor (HexSoft GmbH, support@hexsoft.de)

Target device credentials:
  IP:       10.10.3.21
  User:     admin
  Password: turbineadmin

Upload steps:
  1. Run: .\Tools\update_plc_firmware.ps1 -FirmwareFile <path>
  2. Confirm version via: python Tools\modbus_read.py 10.10.3.21 502 holding 0
  3. Monitor historian for RPM stabilisation (should return to 3000 within 60s)

If PLC does not recover:
  - Write coil 0 = 0 to reset emergency stop
  - Call Ponder (ext 201) immediately
FWREADME

# ── Desktop ───────────────────────────────────────────────────────────────────

cat > "$PROFILE/Desktop/update_plc_firmware.ps1" << 'FWUP'
# PLC Firmware Update Utility — PowerShell wrapper
# Usage: .\update_plc_firmware.ps1 -FirmwareFile <path> [-TargetIP <ip>]
param(
    [Parameter(Mandatory=$true)]
    [string]$FirmwareFile,
    [string]$TargetIP = "10.10.3.21"
)

$AdminUser = "admin"
$AdminPass = "turbineadmin"
$Cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${AdminUser}:${AdminPass}"))

Write-Host "[update_plc_firmware] Connecting to $TargetIP as $AdminUser..."
Write-Host "[update_plc_firmware] Firmware: $FirmwareFile"
Write-Host ""
Write-Host "TODO HEX-3501: Automate upload when vendor provides REST API docs."
Write-Host "For now, manual steps:"
Write-Host "  1. scp $FirmwareFile ${AdminUser}@${TargetIP}:/tmp/firmware.bin"
Write-Host "     (password: $AdminPass)"
Write-Host "  2. On PLC: /opt/plc/firmware_update.sh /tmp/firmware.bin"
Write-Host "  3. Monitor RPM — should stabilise at 3000 within 60s"
FWUP

# ── Tools ─────────────────────────────────────────────────────────────────────

cat > "$PROFILE/Tools/send_alarm.ps1" << 'ALARM'
# Manual alarm relay — sends SMTP alert when SCADA automated alerts fail.
# Usage: .\send_alarm.ps1 -Subject "text" -Body "text"
param(
    [string]$Subject = "Manual alarm from ENG-WS01",
    [string]$Body    = "Sent manually from engineering workstation."
)

$SmtpHost = "mail.uu.am"
$SmtpPort = 587
$SmtpUser = "alarms@uupl.am"
$SmtpPass = "plantmail123"
$AlertTo  = "ops-duty@uupl.am"

$Cred   = New-Object System.Net.NetworkCredential($SmtpUser, $SmtpPass)
$Client = New-Object System.Net.Mail.SmtpClient($SmtpHost, $SmtpPort)
$Client.EnableSsl             = $true
$Client.Credentials           = $Cred
$Client.Send($SmtpUser, $AlertTo, "[MANUAL ALARM] $Subject", $Body)
Write-Host "Alert sent to $AlertTo"
ALARM

# ── Documents ────────────────────────────────────────────────────────────────

cat > "$PROFILE/Documents/engineering_notes.txt" << 'NOTES'
Misc engineering notes — please do not delete
=============================================
Last updated: 2026-01-08  P. Stibbons

PLC access: see config\plc-access.conf
PLC project files: see Projects\PLC\turbine_controller.project

Historian:
  http://10.10.2.10:8080/report?asset=turbine_rpm&from=2026-01-01&to=2026-02-01
  DB credentials: historian / Historian2015  (never changed — "it's fine")

SCADA:
  http://10.10.2.20:8080/  login: admin / admin
  SSH:  scada_admin@10.10.2.20  password: W1nd0ws@2016
  Config dump: http://10.10.2.20:8080/config  (same creds as web)

Historian SSH:
  hist_admin@10.10.2.10  password: same as DB password

Relay IED web interfaces:
  http://10.10.3.31:8081/  admin/relay1234  (Dolly Sisters, Feeder A)
  http://10.10.3.32:8081/  admin/relay1234  (Nap Hill, Feeder B)
  NOTE: Modbus HR[0-2] are writable and control trip thresholds.
        See relay_a_2019.txt for register map.

HMI:
  SSH: operator@10.10.3.10  password: operator
  Web: http://10.10.3.10:8080/  operator/operator

Emergency contact: Ponder Stibbons ext 201, Igor ext 333 (out-of-hours)
NOTES

# ── SSH key ───────────────────────────────────────────────────────────────────
# Keep real SSH key at the real home path for SSH to work.
# Copy to virtual profile for discoverability.

mkdir -p /home/engineer/.ssh
if [ ! -f /home/engineer/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -f /home/engineer/.ssh/id_rsa -N "" \
        -C "ponder@uupl-eng-ws" -q
    cat /home/engineer/.ssh/id_rsa.pub >> /home/engineer/.ssh/authorized_keys
fi
# Remote admin key — UU P&L admin@home (rincewind-home) has this private key
cat >> /home/engineer/.ssh/authorized_keys << 'ADMINKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2tnjesWZoZrW8xRQZxOYD3/zzr38196aIui2cmjKF8 uupl-admin@rincewind-home
ADMINKEY
chmod 700 /home/engineer/.ssh
chmod 600 /home/engineer/.ssh/id_rsa /home/engineer/.ssh/authorized_keys
chmod 644 /home/engineer/.ssh/id_rsa.pub

# Copy to virtual profile (attackers will find it browsing C:\)
cp /home/engineer/.ssh/id_rsa     "$PROFILE/.ssh/id_rsa"
cp /home/engineer/.ssh/id_rsa.pub "$PROFILE/.ssh/id_rsa.pub"

cat > "$PROFILE/.ssh/known_hosts" << 'KNOWNHOSTS'
# SSH known_hosts — systems this workstation has connected to
# Public key was distributed to control zone devices at commissioning 2012.
# Reminder to add to new relay IEDs sent 2023-04-11 (ticket HEX-3421, open).
10.10.3.10 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5oHMExample...uupl-hmi
10.10.3.21 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5oHMExample...hex-turbine-plc
10.10.2.10 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5oHMExample...uupl-historian
10.10.2.20 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC5oHMExample...distribution-scada
KNOWNHOSTS
chmod 600 "$PROFILE/.ssh/known_hosts"

# ── PSReadLine command history ────────────────────────────────────────────────

cat > "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" << 'HIST'
dir
cd Projects\PLC
Get-Content .\turbine_controller.project
cd ~
python Tools\modbus_read.py 10.10.3.21 502 holding 0 4
python Tools\modbus_read.py 10.10.3.21 502 input 0 5
python Tools\modbus_write.py 10.10.3.21 502 holding 0 3000
cd config
Get-Content .\plc-access.conf
ping 10.10.3.21
ping 10.10.3.31
python Tools\modbus_read.py 10.10.3.31 502 holding 0 3
ssh operator@10.10.3.10
curl http://10.10.2.10:8080/assets
curl "http://10.10.2.10:8080/report?asset=turbine_rpm&from=2026-03-01&to=2026-03-08"
curl http://10.10.2.20:8080/ -u admin:admin
ssh scada_admin@10.10.2.20
nmap -sV 10.10.3.0/24
python Tools\modbus_read.py 10.10.3.51 502 holding 0
python Tools\modbus_read.py 10.10.3.52 502 holding 0
cd backups
dir
HIST

# ── 2019 backup archive ───────────────────────────────────────────────────────

BACKUP_TMP=$(mktemp -d)
mkdir -p "$BACKUP_TMP/PLC_Backup_2019"

cat > "$BACKUP_TMP/PLC_Backup_2019/plc-access-2019.conf" << 'BACKUP'
# UU P&L — PLC and IED Access Configuration (PRE-2019 UPGRADE)
# Archived: 2019-11-12 before turbine relay IED installation
# DO NOT USE — superseded by config\plc-access.conf on this workstation

[hex_turbine_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
admin    = admin
pass     = turbineadmin

[hmi_main]
ip       = 10.10.3.10
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = SSH operator/operator. Web operator/operator.

[scada_server]
ip       = 10.10.2.20
port     = 8080
user     = admin
pass     = sysadmin123
notes    = Password changed 2021-03 after audit. New creds not recorded here.
           Current SSH: scada_admin / W1nd0ws@2016

[historian]
ip       = 10.10.2.10
port     = 8080
db_user  = historian
db_pass  = Historian2015
notes    = "it's never needed changing" — P.S.
           SSH: hist_admin / Historian2015  (same password, don't tell IT)
BACKUP

cat > "$BACKUP_TMP/PLC_Backup_2019/network_map_2019.txt" << 'BACKUP'
UU P&L OT Network — 2019 Snapshot
===================================
Compiled by Ponder Stibbons, 2019-11-12

Operational zone (10.10.2.0/24):
  10.10.2.10   HIST-SRV01      hist_admin / Historian2015  (also: web port 8080)
  10.10.2.20   SCADA-SRV01     scada_admin / W1nd0ws@2016  (also: web admin/admin)
  10.10.2.30   ENG-WS01        engineer / spanner99

Control zone (10.10.3.0/24):
  10.10.3.10   uupl-hmi        operator / operator (SSH + web :8080)
  10.10.3.21   hex-turbine-plc admin / turbineadmin (Modbus :502, DNP3 :20000)
  10.10.3.31   uupl-relay-a    admin / relay1234 (Modbus :502, web :8081)
  10.10.3.32   uupl-relay-b    admin / relay1234 (Modbus :502, web :8081)
  10.10.3.33   uupl-meter      (read-only, no auth)
  10.10.3.51   uupl-fuel-valve (Modbus :502)
  10.10.3.52   uupl-cooling    (Modbus :502)
  10.10.3.53   uupl-breaker-a  (Modbus :502, coil[1]=trip)
  10.10.3.54   uupl-breaker-b  (Modbus :502, coil[1]=trip)
BACKUP

tar czf "$PROFILE/backups/PLC_Backup_2019.tar.gz" \
    -C "$BACKUP_TMP" PLC_Backup_2019/
rm -rf "$BACKUP_TMP"

# ── Historian ingest script ───────────────────────────────────────────────────
# Polls turbine PLC input registers and pushes readings to the historian.
# Only wired for uupl_ied — asset names must match what seed.py created.

if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    cat > "$PROFILE/Tools/poll_and_ingest.py" << 'EOF'
#!/usr/bin/env python3
"""
UU P&L Engineering Workstation — PLC poll and historian ingest.

Reads turbine PLC input registers and posts each reading to the process
historian at http://10.10.2.10:8080/ingest.

Runs every minute from cron. Adds a small timing jitter before polling so
readings do not land at exactly :00, and skips roughly one cycle in twenty
to reflect the fact that nothing on a plant network is perfectly reliable.
"""
import base64
import json
import random
import time
import urllib.request
from datetime import datetime, timezone

from pymodbus.client import ModbusTcpClient

PLC_IP        = "10.10.3.21"
PLC_PORT      = 502
HISTORIAN_URL = "http://10.10.2.10:8080/ingest"
INGEST_USER   = "hist_read"
INGEST_PASS   = "history2017"

# (historian asset name, unit) indexed by PLC IR register number
ASSETS = [
    ("turbine_rpm",         "RPM"),
    ("turbine_temperature", "C"),
    ("turbine_pressure",    "bar"),
    ("line_voltage_a",      "V"),
    ("line_current_a",      "A"),
    ("line_voltage_b",      "V"),
    ("line_current_b",      "A"),
    ("frequency_hz_x10",    "raw"),
    ("meter_power_kw",      "kW"),
]


def _post(asset, value, unit, ts):
    payload = json.dumps(
        {"timestamp": ts, "asset": asset, "value": value, "unit": unit}
    ).encode()
    creds = base64.b64encode(f"{INGEST_USER}:{INGEST_PASS}".encode()).decode()
    req = urllib.request.Request(
        HISTORIAN_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Basic {creds}",
        },
        method="POST",
    )
    urllib.request.urlopen(req, timeout=5)


def main():
    # Jitter: wait 2-12 s before reading so timestamps are not clock-aligned.
    time.sleep(random.uniform(2, 12))

    # Skip roughly one cycle in twenty.
    if random.random() < 0.05:
        print("poll_and_ingest: skipped cycle")
        return

    try:
        client = ModbusTcpClient(PLC_IP, port=PLC_PORT, timeout=3)
        client.connect()
        result = client.read_input_registers(0, len(ASSETS), slave=1)
        client.close()
        if result.isError():
            print("poll_and_ingest: Modbus read error")
            return
        regs = result.registers
    except Exception as e:
        print(f"poll_and_ingest: connection failed: {e}")
        return

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    errors = 0
    for i, (asset, unit) in enumerate(ASSETS):
        try:
            _post(asset, regs[i], unit, ts)
        except Exception:
            errors += 1

    ingested = len(ASSETS) - errors
    tag = "ok" if not errors else f"partial ({errors} ingest errors)"
    print(
        f"poll_and_ingest: rpm={regs[0]} temp={regs[1]} press={regs[2]} "
        f"volt_a={regs[3]} curr_a={regs[4]} [{tag}, {ingested}/{len(ASSETS)} ingested]"
    )


if __name__ == "__main__":
    main()
EOF
fi

# ── Cron artifact ─────────────────────────────────────────────────────────────

if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    cat > /etc/cron.d/plc-poll << 'CRON'
# UU P&L — PLC monitor and historian ingest
# Polls turbine PLC every minute; pushes readings to historian.
* * * * * engineer /venv/bin/python3 /opt/win10/C/Users/engineer/Tools/poll_and_ingest.py >> /opt/win10/C/Users/engineer/plc_poll.log 2>&1
CRON
else
    cat > /etc/cron.d/plc-poll << 'CRON'
# UU P&L — PLC availability monitor
# Polls turbine PLC every 5 minutes, logs governor setpoint (HR[0])
*/5 * * * * engineer /venv/bin/python3 /opt/win10/C/Users/engineer/Tools/modbus_read.py 10.10.3.21 502 holding 0 1 >> /opt/win10/C/Users/engineer/plc_poll.log 2>&1
CRON
fi

# ── Permissions ───────────────────────────────────────────────────────────────

chown -R engineer:engineer /opt/win10 /home/engineer
chmod 700 "$PROFILE/.ssh"
chmod 600 "$PROFILE/.ssh/id_rsa" "$PROFILE/.ssh/known_hosts"
chmod 644 "$PROFILE/.ssh/id_rsa.pub"
chmod 600 "$PROFILE/config/plc-access.conf"
chmod 600 "$PROFILE/backups/PLC_Backup_2019.tar.gz"
chmod 750 "$PROFILE/Tools/send_alarm.ps1"
chmod 644 "$PROFILE/Tools/modbus_read.py" "$PROFILE/Tools/modbus_write.py"

cron
/usr/sbin/sshd -D
