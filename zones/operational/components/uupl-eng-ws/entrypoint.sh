#!/usr/bin/env bash
# uupl-eng-ws entrypoint
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
PrintLastLog no
EOF

# PAM prints the MOTD via pam_motd.so regardless of PrintMotd in sshd_config.
# The facade presents a Windows login banner; the Linux MOTD breaks the fiction.
> /etc/motd 2>/dev/null || true
sed -i '/pam_motd/s/^/# /' /etc/pam.d/sshd 2>/dev/null || true

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
# UU P&L, PLC and IED Access Configuration
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

[uupl-relay-a]
ip       = 10.10.3.31
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Protective relay, Feeder A (Dolly Sisters). HR[0-2] = protection thresholds.
           Web: http://10.10.3.31:8081/ login: admin/relay1234
           SNMP: community public (read), private (read-write)

[uupl-relay-b]
ip       = 10.10.3.32
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Protective relay, Feeder B (Nap Hill). HR[0-2] = protection thresholds.
           Web: http://10.10.3.32:8081/ login: admin/relay1234
           SNMP: community public (read), private (read-write)

[uupl-meter]
ip       = 10.10.3.33
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Revenue meter, read-only input registers. Report discrepancies to the Bursar.
           SNMP: community public (read)

[uupl-fuel-valve]
ip       = 10.10.3.51
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Fuel valve actuator. HR[0] = position 0-100%. Written by PLC governor loop.

[uupl-cooling-pump]
ip       = 10.10.3.52
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Cooling pump. HR[0] = speed 0-100%. Default: 100%.

[uupl-breaker-a]
ip       = 10.10.3.53
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Feeder A circuit breaker. Coil[0]=state, coil[1]=trip, coil[2]=close.
           Written by relay IED on fault. DO NOT trip without coordination.

[uupl-breaker-b]
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
# Hex Steam Turbine, Turbine PLC Project File
# Exported from HexSoft PLC Suite v3.2, 2019-11-12
# Engineer: Ponder Stibbons
# DO NOT EDIT MANUALLY, use HexSoft PLC Suite

[device]
name             = hex_turbine_controller
ip               = 10.10.3.21
port             = 502
unit_id          = 1
firmware_version = 2.4.1
admin_pass       = turbineadmin

[coil_map]
; Coils (FC1), read/write, no authentication required on Modbus
0 = emergency_stop      ; write 1 to trip immediately, write 0 to reset
1 = alarm_overspeed     ; set when RPM > 3300
2 = alarm_overtemp      ; set when temp > 490 C

[holding_register_map]
; Holding registers (FC3), read/write
0 = governor_setpoint_rpm  ; target RPM, default 3000 (range 0-4000)
1 = fuel_valve_command     ; 0-100%, set by governor loop
2 = cooling_pump_speed     ; 0-100%, default 100
3 = overcurrent_threshold  ; amps, default 200

[input_register_map]
; Input registers (FC4), read-only (physics simulation outputs)
0 = turbine_rpm
1 = turbine_temperature_c
2 = turbine_pressure_bar
3 = line_voltage_v
4 = line_current_a

[alarm_setpoints]
; Setpoints as of 2019 upgrade. Cross-reference uupl-historian alarm_config table.
overspeed_trip_rpm    = 3300
overtemp_trip_c       = 490
overpressure_trip_bar = 95
undervoltage_trip_v   = 196
overcurrent_trip_a    = 200
PROJ

cat > "$PROFILE/Projects/RelayConfigs/relay_a_2019.txt" << 'RCONF'
# IED Relay A, Dolly Sisters Feeder
# Configuration snapshot 2019-11-12 (pre-upgrade)
# Saved by Ponder Stibbons before installing web interface firmware

device_ip       = 10.10.3.31
device_port     = 502
unit_id         = 1

# Modbus holding registers (FC3), protection thresholds
HR[0] undervoltage_threshold_v = 196    ; relay trips if V < this
HR[1] overspeed_threshold_rpm  = 3300   ; relay trips if RPM > this
HR[2] overcurrent_threshold_a  = 200    ; relay trips if I > this

# Coil map
coil[0] = relay_trip_status   ; 1=tripped, writable (force-trip)

# Note: HR values are writable via Modbus with no authentication.
# Reducing undervoltage threshold allows fault to persist without trip.
# Lowering overspeed or overcurrent threshold triggers a spurious trip.
RCONF

cp "$PROFILE/Projects/RelayConfigs/relay_a_2019.txt" \
   "$PROFILE/Projects/RelayConfigs/relay_b_2019.txt"
sed -i 's/Relay A/Relay B/; s/Dolly Sisters/Nap Hill/; s/10\.10\.3\.31/10.10.3.32/' \
    "$PROFILE/Projects/RelayConfigs/relay_b_2019.txt"

cat > "$PROFILE/Projects/RelayConfigs/trip_history_2024.txt" << 'TRIPS'
UU P&L Relay IED Trip History, 2024 Annual Report
Export generated: 2024-11-08  Engineer: P. Stibbons

--- REL-200a (Dolly Sisters Feeder, 10.10.3.31) ---
2024-01-08 14:22:44  TRIP    cause=undervoltage  V=183.2V  threshold=196V  duration=10s
2024-01-08 14:22:54  RECLOSE auto
2024-03-19 02:07:13  TRIP    cause=overcurrent   I=218.4A  threshold=200A  duration=10s
2024-03-19 02:07:23  RECLOSE auto
2024-05-02 11:33:06  TRIP    cause=remote        operator=engineer
2024-05-02 11:33:16  RECLOSE auto
2024-07-14 08:51:29  TRIP    cause=undervoltage  V=191.1V  threshold=196V  duration=10s
2024-07-14 08:51:39  RECLOSE auto
2024-09-03 16:04:55  TRIP    cause=overcurrent   I=203.7A  threshold=200A  duration=10s
2024-09-03 16:05:05  RECLOSE auto

--- REL-200b (Nap Hill Feeder, 10.10.3.32) ---
2024-02-14 03:18:22  TRIP    cause=overcurrent   I=211.0A  threshold=200A  duration=10s
2024-02-14 03:18:32  RECLOSE auto
2024-04-07 19:42:01  TRIP    cause=undervoltage  V=188.3V  threshold=196V  duration=10s
2024-04-07 19:42:11  RECLOSE auto
2024-06-22 09:15:44  TRIP    cause=remote        operator=engineer
2024-06-22 09:15:54  RECLOSE auto
2024-10-11 22:30:17  TRIP    cause=overspeed     RPM=3347  threshold=3300  duration=10s
2024-10-11 22:30:27  RECLOSE auto

Total 2024: 9 events (REL-200a), 7 events (REL-200b).
Previous year (2023): 12 events (REL-200a), 8 events (REL-200b).
TRIPS

cat > "$PROFILE/Projects/RelayConfigs/threshold_override_2023-09.txt" << 'THRESH'
TEMPORARY THRESHOLD MODIFICATION RECORD
========================================
Date:     2023-09-14
Engineer: P. Stibbons
Relay:    REL-200b (Nap Hill feeder, 10.10.3.32)

Overcurrent threshold (HR[2]) raised from 200 A to 240 A for the duration
of the Nap Hill load test. Restored to 200 A on completion at 16:30.

No firmware record was filed at the time (oversight). Entry added to relay
maintenance log after the fact.

Overspeed threshold (HR[1]) for REL-200b is due for a recalibration check
per the 2021 commissioning schedule. Still outstanding.

TODO: Chase Nobby at sorting-office about the gateway password rotation
before the next annual audit. (Ticket: OPS-2024-0088)
THRESH

cat > "$PROFILE/Projects/RelayConfigs/relay_maintenance_log.txt" << 'MLOG'
UU P&L Relay IED Maintenance Log
===================================
Author: Ponder Stibbons

2019-04-07  REL-200a  Initial commissioning, Dolly Sisters feeder
             UV=196V, OC=200A, OS=3300RPM, RECLOSE=10s
             Signed off: P. Stibbons

2019-04-07  REL-200b  Initial commissioning, Nap Hill feeder
             UV=196V, OC=200A, OS=3300RPM, RECLOSE=10s
             Signed off: P. Stibbons

2021-02-19  REL-200a  Firmware upgrade 1.2.0 -> 2.0.1
             No threshold changes.
             Signed off: P. Stibbons

2021-02-19  REL-200b  Firmware upgrade 1.2.0 -> 2.0.1
             No threshold changes.
             Signed off: P. Stibbons

2023-09-14  REL-200b  Load test: OC threshold raised 200A -> 240A
             Duration approx. 4 hours. Restored to 200A at 16:30.
             See threshold_override_2023-09.txt for details.
             OS threshold check skipped; ticket raised, still outstanding.
             Signed off: P. Stibbons

2024-05-02  REL-200a  Operational test (scheduled maintenance window)
             Remote trip/reclose via engineer workstation, nominal.
             Signed off: P. Stibbons

2024-06-22  REL-200b  Operational test (scheduled maintenance window)
             Remote trip/reclose via engineer workstation, nominal.
             Signed off: P. Stibbons

2025-04-09  REL-200a  Annual inspection
             Thresholds verified: UV=196V, OC=200A, OS=3300RPM. No changes.
             OS recalibration check deferred; parts on order.
             Signed off: P. Stibbons

2025-04-09  REL-200b  Annual inspection
             Thresholds verified: UV=196V, OC=200A, OS=3300RPM. No changes.
             OS threshold ticket (open since 2021): escalated to procurement.
             Signed off: P. Stibbons
MLOG

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
  3. Monitor uupl-historian for RPM stabilisation (should return to 3000 within 60s)

If PLC does not recover:
  - Write coil 0 = 0 to reset emergency stop
  - Call Ponder (ext 201) immediately
FWREADME

# ── Desktop ───────────────────────────────────────────────────────────────────

cat > "$PROFILE/Desktop/update_plc_firmware.ps1" << 'FWUP'
# PLC Firmware Update Utility, PowerShell wrapper
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
Write-Host "  3. Monitor RPM, should stabilise at 3000 within 60s"
FWUP

# ── Tools ─────────────────────────────────────────────────────────────────────

cat > "$PROFILE/Tools/send_alarm.ps1" << 'ALARM'
# Manual alarm relay, sends SMTP alert when SCADA automated alerts fail.
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
Misc engineering notes, please do not delete
=============================================
Last updated: 2026-01-08  P. Stibbons

PLC access: see config\plc-access.conf
PLC project files: see Projects\PLC\turbine_controller.project

Historian:
  http://10.10.2.10:8080/report?asset=turbine_rpm&from=2026-01-01&to=2026-02-01
  DB credentials: historian / Historian2015  (never changed, "it's fine")

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
  Web: http://10.10.3.10:1881/  (no login required; admin account default)

Emergency contact: Ponder Stibbons ext 201, Igor ext 333 (out-of-hours)
NOTES

cat > "$PROFILE/Documents/mqtt_topics.txt" << 'TOPICS'
UU P&L Control Zone MQTT Topics
=================================
Broker: uupl-mqtt at 10.10.3.60:1883 (no authentication)
Author: P. Stibbons, 2019-03-11, updated 2021-07-08

uupl/turbine/telemetry
  Published every 5s by the turbine PLC (10.10.3.21).
  Payload: JSON
    rpm         integer  turbine shaft RPM
    temp_c      integer  exhaust temperature, Celsius
    pressure    integer  steam pressure, bar
    voltage_a   integer  line voltage A, V
    voltage_b   integer  line voltage B, V
    current_a   integer  line current A, A
    current_b   integer  line current B, A
    freq_x10    integer  mains frequency * 10 (e.g. 483 = 48.3 Hz)
    power_kw    integer  generated power, kW
    estop       integer  0=running, 1=emergency stop active

uupl/relay/a/trip
  Published by REL-200a (Dolly Sisters) on trip or reclose.
  Payload: JSON {relay_id, feeder, cause, timestamp, state}
  cause: "undervoltage" | "overcurrent" | "overspeed" | "remote"

uupl/relay/b/trip
  Published by REL-200b (Nap Hill) on trip or reclose.
  Same payload format.

Note: the DMZ broker (clacks-relay, 10.10.5.12) receives a one-way
bridge of all topics above, republished verbatim by mqtt_bridge.py
running on this workstation.
TOPICS

cat > "$PROFILE/Documents/telemetry_sample_2024-01-20.log" << 'TELEM'
# uupl/turbine/telemetry capture, 2024-01-20 09:00:00--09:02:05
# mosquitto_sub -h 10.10.3.60 -t uupl/turbine/telemetry
# Saved by: P. Stibbons
{"rpm":2941,"temp_c":174,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2958,"temp_c":175,"pressure":84,"voltage_a":227,"voltage_b":225,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2947,"temp_c":173,"pressure":84,"voltage_a":225,"voltage_b":223,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2939,"temp_c":176,"pressure":83,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":499,"power_kw":30,"estop":0}
{"rpm":2951,"temp_c":174,"pressure":84,"voltage_a":228,"voltage_b":226,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2944,"temp_c":177,"pressure":84,"voltage_a":225,"voltage_b":223,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2963,"temp_c":175,"pressure":84,"voltage_a":229,"voltage_b":227,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2937,"temp_c":173,"pressure":83,"voltage_a":224,"voltage_b":222,"current_a":72,"current_b":70,"freq_x10":499,"power_kw":30,"estop":0}
{"rpm":2948,"temp_c":174,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2955,"temp_c":175,"pressure":84,"voltage_a":227,"voltage_b":225,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2942,"temp_c":176,"pressure":84,"voltage_a":225,"voltage_b":223,"current_a":73,"current_b":71,"freq_x10":499,"power_kw":30,"estop":0}
{"rpm":2961,"temp_c":174,"pressure":84,"voltage_a":228,"voltage_b":226,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2946,"temp_c":175,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2932,"temp_c":173,"pressure":83,"voltage_a":223,"voltage_b":221,"current_a":72,"current_b":70,"freq_x10":499,"power_kw":29,"estop":0}
{"rpm":2950,"temp_c":174,"pressure":84,"voltage_a":225,"voltage_b":223,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2957,"temp_c":175,"pressure":84,"voltage_a":227,"voltage_b":225,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2945,"temp_c":174,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2939,"temp_c":176,"pressure":83,"voltage_a":224,"voltage_b":222,"current_a":72,"current_b":70,"freq_x10":499,"power_kw":30,"estop":0}
{"rpm":2953,"temp_c":175,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2941,"temp_c":173,"pressure":84,"voltage_a":225,"voltage_b":223,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2958,"temp_c":174,"pressure":84,"voltage_a":228,"voltage_b":226,"current_a":74,"current_b":72,"freq_x10":500,"power_kw":31,"estop":0}
{"rpm":2949,"temp_c":175,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
{"rpm":2936,"temp_c":174,"pressure":83,"voltage_a":224,"voltage_b":222,"current_a":72,"current_b":70,"freq_x10":499,"power_kw":30,"estop":0}
{"rpm":2952,"temp_c":175,"pressure":84,"voltage_a":226,"voltage_b":224,"current_a":73,"current_b":71,"freq_x10":500,"power_kw":30,"estop":0}
TELEM

cat > "$PROFILE/Documents/snmp_plc_2024-03-15.txt" << 'SNMPW'
# snmpwalk -v 2c -c public 10.10.3.21
# Captured: 2024-03-15  Engineer: P. Stibbons
SNMPv2-MIB::sysDescr.0 = STRING: HEX-CPU-4000 Turbine PLC, Hex Computing Division, firmware 4.1.2
SNMPv2-MIB::sysObjectID.0 = OID: SNMPv2-SMI::enterprises
SNMPv2-MIB::sysUpTime.0 = Timeticks: (2741892) 7 days, 16:10:18.92
SNMPv2-MIB::sysContact.0 = STRING: Ponder Stibbons <ponder@unseen.edu>
SNMPv2-MIB::sysName.0 = STRING: hex-turbine-plc
SNMPv2-MIB::sysLocation.0 = STRING: Hex Engine Room, Unseen University, Ankh-Morpork
SNMPv2-MIB::sysServices.0 = INTEGER: 72
SNMPv2-MIB::sysORLastChange.0 = Timeticks: (0) 0:00:00.00
IF-MIB::ifNumber.0 = INTEGER: 2
IF-MIB::ifIndex.1 = INTEGER: 1
IF-MIB::ifDescr.1 = STRING: lo
IF-MIB::ifType.1 = INTEGER: softwareLoopback(24)
IF-MIB::ifMtu.1 = INTEGER: 65536
IF-MIB::ifSpeed.1 = Gauge32: 10000000
IF-MIB::ifPhysAddress.1 = STRING:
IF-MIB::ifIndex.2 = INTEGER: 2
IF-MIB::ifDescr.2 = STRING: eth1
IF-MIB::ifType.2 = INTEGER: ethernetCsmacd(6)
IF-MIB::ifMtu.2 = INTEGER: 1500
IF-MIB::ifSpeed.2 = Gauge32: 10000000
IF-MIB::ifPhysAddress.2 = STRING: 02:42:0a:0a:03:15
IF-MIB::ifOperStatus.2 = INTEGER: up(1)
IF-MIB::ifInOctets.2 = Counter32: 6843201
IF-MIB::ifOutOctets.2 = Counter32: 4921037
# Note: rwcommunity "private" also active. Write access enabled on all OIDs.
SNMPW

cat > "$PROFILE/Documents/grafana_turbine_panel.json" << 'GRAFANA'
{
  "title": "Turbine Overview",
  "datasource": "uupl-historian-api",
  "panels": [
    {
      "type": "graph",
      "title": "Shaft RPM",
      "targets": [
        {
          "measurement": "turbine_rpm",
          "query": "SELECT mean(value) FROM turbine_rpm WHERE $timeFilter GROUP BY time($interval)",
          "alias": "RPM"
        }
      ],
      "yaxes": [{"min": 0, "max": 4000, "label": "RPM"}],
      "thresholds": [
        {"value": 3300, "op": "gt", "colorMode": "critical", "fill": true}
      ]
    },
    {
      "type": "graph",
      "title": "Line Voltage A",
      "targets": [
        {
          "measurement": "line_voltage_a",
          "query": "SELECT mean(value) FROM line_voltage_a WHERE $timeFilter GROUP BY time($interval)"
        }
      ],
      "yaxes": [{"min": 180, "max": 240, "label": "V"}],
      "thresholds": [
        {"value": 196, "op": "lt", "colorMode": "warning", "fill": false}
      ]
    },
    {
      "type": "singlestat",
      "title": "Emergency Stop",
      "targets": [{"measurement": "turbine_estop", "query": "SELECT last(value) FROM turbine_estop WHERE $timeFilter"}],
      "valueMaps": [{"op": "=", "value": "0", "text": "Running"}, {"op": "=", "value": "1", "text": "STOPPED"}],
      "colorBackground": true,
      "colors": ["green", "red", "red"],
      "thresholds": "0.5,0.5"
    }
  ],
  "refresh": "5s",
  "time": {"from": "now-1h", "to": "now"},
  "__note": "Historian creds for datasource: historian / Historian2015. See engineering_notes.txt."
}
GRAFANA

cat > "$PROFILE/Documents/alarm_history_2024-Q1.csv" << 'ALARMS'
timestamp,asset,value,unit,limit,direction,state,ack_by,ack_time
2024-01-08 14:22:31,line_voltage_a,183,V,196,below,ACK,pstibbons,2024-01-08 14:25:00
2024-01-08 14:22:44,line_voltage_a,183,V,196,below,CLR,,
2024-01-15 09:14:02,turbine_rpm,3312,RPM,3300,above,ACK,pstibbons,2024-01-15 09:16:44
2024-01-15 09:15:12,turbine_rpm,2998,RPM,3300,above,CLR,,
2024-02-03 11:00:00,turbine_estop,1,,,,ACK,pstibbons,2024-02-03 11:05:33
2024-02-03 11:00:00,turbine_estop,0,,,,CLR,,
2024-02-14 03:18:10,line_current_a,211,A,200,above,ACK,pstibbons,2024-02-14 08:02:17
2024-02-14 03:18:32,line_current_a,73,A,200,above,CLR,,
2024-03-04 16:47:55,turbine_temperature,221,C,210,above,ACK,pstibbons,2024-03-04 16:51:03
2024-03-04 16:53:10,turbine_temperature,207,C,210,above,CLR,,
2024-03-19 02:07:13,line_current_a,218,A,200,above,ACK,pstibbons,2024-03-19 08:14:52
2024-03-19 02:07:23,line_current_a,74,A,200,above,CLR,,
ALARMS

# ── SSH key ───────────────────────────────────────────────────────────────────
# Keep real SSH key at the real home path for SSH to work.
# Copy to virtual profile for discoverability.

mkdir -p /home/engineer/.ssh
if [ ! -f /home/engineer/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -f /home/engineer/.ssh/id_rsa -N "" \
        -C "ponder@uupl-eng-ws" -q
    cat /home/engineer/.ssh/id_rsa.pub >> /home/engineer/.ssh/authorized_keys
fi
# Remote admin key, UU P&L admin@home (rincewind-home) has this private key
cat >> /home/engineer/.ssh/authorized_keys << 'ADMINKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2tnjesWZoZrW8xRQZxOYD3/zzr38196aIui2cmjKF8 uupl-admin@rincewind-home
ADMINKEY
# Contractor maintenance key (contractors-gate, DMZ bastion).
# Added 2023-09-14 by Ponder to let the IT field team run PLC health checks
# without calling him every time. Access is engineer only, not root.
cat >> /home/engineer/.ssh/authorized_keys << 'CONTRACTORKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9aZ66/ATZXg7Lx/ge0QQXQPyYxncY5VxQWj5jHyOQm contract-admin@uupl-maintenance
CONTRACTORKEY
chmod 700 /home/engineer/.ssh
chmod 600 /home/engineer/.ssh/id_rsa /home/engineer/.ssh/authorized_keys
chmod 644 /home/engineer/.ssh/id_rsa.pub

# Copy to virtual profile (attackers will find it browsing C:\)
cp /home/engineer/.ssh/id_rsa     "$PROFILE/.ssh/id_rsa"
cp /home/engineer/.ssh/id_rsa.pub "$PROFILE/.ssh/id_rsa.pub"

cat > "$PROFILE/.ssh/known_hosts" << 'KNOWNHOSTS'
# SSH known_hosts, systems this workstation has connected to
# Public key was distributed to control zone devices at commissioning 2012.
# Reminder to add to new relay IEDs sent 2023-04-11 (ticket HEX-3421, open).
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
curl http://10.10.2.10:8080/assets
curl "http://10.10.2.10:8080/report?asset=turbine_rpm&from=2026-03-01&to=2026-03-08"
curl http://10.10.2.20:8080/ -u admin:admin
ssh scada_admin@10.10.2.20
nmap -sV 10.10.3.0/24
python Tools\modbus_read.py 10.10.3.51 502 holding 0
python Tools\modbus_read.py 10.10.3.52 502 holding 0
python Tools\mqtt_check.py
cat Documents\mqtt_topics.txt
cat Documents\alarm_history_2024-Q1.csv
cat Projects\RelayConfigs\trip_history_2024.txt
cat Projects\RelayConfigs\relay_maintenance_log.txt
cd backups
dir
Expand-Archive .\backup_2022_final_v3.zip -DestinationPath .\backup_2022_expanded
dir .\backup_2022_expanded
HIST

# ── 2019 backup archive ───────────────────────────────────────────────────────

BACKUP_TMP=$(mktemp -d)
mkdir -p "$BACKUP_TMP/PLC_Backup_2019"

cat > "$BACKUP_TMP/PLC_Backup_2019/plc-access-2019.conf" << 'BACKUP'
# UU P&L, PLC and IED Access Configuration (PRE-2019 UPGRADE)
# Archived: 2019-11-12 before turbine relay IED installation
# DO NOT USE, superseded by config\plc-access.conf on this workstation

[hex_turbine_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
admin    = admin
pass     = turbineadmin

[uupl-hmi]
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

[uupl-historian]
ip       = 10.10.2.10
port     = 8080
db_user  = historian
db_pass  = Historian2015
notes    = "it's never needed changing", P.S.
           SSH: hist_admin / Historian2015  (same password, don't tell IT)
BACKUP

cat > "$BACKUP_TMP/PLC_Backup_2019/network_map_2019.txt" << 'BACKUP'
UU P&L OT Network, 2019 Snapshot
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

# ── 2022 backup archive ───────────────────────────────────────────────────────

python3 - << 'PYZIP'
import zipfile, os

PROFILE = "/opt/win10/C/Users/engineer"
zippath = os.path.join(PROFILE, "backups", "backup_2022_final_v3.zip")

plc_conf = """\
# UU P&L, PLC and IED Access Configuration (2022 MAINTENANCE SNAPSHOT)
# Archived: 2022-11-04 before annual service
# Compare with current config\\plc-access.conf for changes

[hex_turbine_controller]
ip       = 10.10.3.21
port     = 502
protocol = modbus-tcp
unit_id  = 1
admin    = admin
pass     = turbineadmin

[uupl-relay-a]
ip       = 10.10.3.31
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Dolly Sisters feeder. Web: admin/relay1234

[uupl-relay-b]
ip       = 10.10.3.32
port     = 502
protocol = modbus-tcp
unit_id  = 1
notes    = Nap Hill feeder. Web: admin/relay1234

[uupl-hmi]
ip       = 10.10.3.10
port     = 502
protocol = modbus-tcp
notes    = SSH operator/operator. No web auth.

[uupl-historian]
ip       = 10.10.2.10
port     = 8080
db_user  = historian
db_pass  = Historian2015
notes    = SSH: hist_admin / Historian2015

[scada_server]
ip       = 10.10.2.20
port     = 8080
user     = admin
pass     = admin
notes    = SSH: scada_admin / W1nd0ws@2016
"""

setpoints = """\
UU P&L Turbine Governor Setpoints, 2022 Annual Service
=======================================================
Recorded: 2022-11-04  Engineer: P. Stibbons

PLC Holding Registers (FC3 read, FC16 write):
  HR[0] governor_setpoint_rpm  = 3000  (normal operating speed)
  HR[1] fuel_valve_position    = 65    (percent open, governor-controlled)
  HR[2] cooling_pump_speed     = 100   (percent, always max)
  HR[3] overcurrent_threshold  = 200   (amps, relay trip limit)

Relay Holding Registers (HR[0-2] on both REL-200a and REL-200b):
  HR[0] undervoltage_v         = 196   (trip if line V drops below this)
  HR[1] overspeed_rpm          = 3300  (trip if shaft RPM exceeds this)
  HR[2] overcurrent_a          = 200   (trip if line current exceeds this)

All registers writable over Modbus TCP with no authentication.
Thresholds unchanged since 2019 commissioning except brief REL-200b OC test 2023.
"""

with zipfile.ZipFile(zippath, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("plc-access-2022.conf", plc_conf)
    zf.writestr("setpoints_2022.txt",   setpoints)
PYZIP

# ── Historian ingest script ───────────────────────────────────────────────────
# Polls turbine PLC input registers and pushes readings to the uupl-historian.
# Only wired for uupl_ied, asset names must match what seed.py created.

if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    cat > "$PROFILE/Tools/poll_and_ingest.py" << 'EOF'
#!/usr/bin/env python3
"""
UU P&L Engineering Workstation, PLC poll and uupl-historian ingest.

Reads turbine PLC input registers and posts each reading to the process
uupl-historian at http://10.10.2.10:8080/ingest.

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

# (uupl-historian asset name, unit) indexed by PLC IR register number
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

    cat > "$PROFILE/Tools/mqtt_bridge.py" << 'EOF'
#!/usr/bin/env python3
"""
UU P&L Engineering Workstation, control-zone to DMZ MQTT bridge.

Subscribes to telemetry and relay event topics on uupl-mqtt (10.10.3.60)
and republishes them on the DMZ broker (clacks-relay, 10.10.5.12) so that
DMZ monitoring feeds see live process data without a direct path into the
control zone.

Written: Ponder Stibbons, 2019-03-11.
"""
import time
import paho.mqtt.client as mqtt

SRC_HOST = "10.10.3.60"
DST_HOST = "10.10.5.12"
TOPICS   = ["uupl/turbine/telemetry", "uupl/relay/#"]

dst = mqtt.Client(client_id="eng-ws-bridge-dst")
dst.reconnect_delay_set(min_delay=2, max_delay=30)

def on_connect(src, userdata, flags, rc):
    for t in TOPICS:
        src.subscribe(t)

def on_message(src, userdata, msg):
    try:
        dst.publish(msg.topic, msg.payload, qos=0, retain=False)
    except Exception:
        pass

for _attempt in range(30):
    try:
        dst.connect(DST_HOST, 1883, 60)
        break
    except Exception:
        time.sleep(5)
dst.loop_start()

src = mqtt.Client(client_id="eng-ws-bridge-src")
src.on_connect = on_connect
src.on_message = on_message
src.reconnect_delay_set(min_delay=2, max_delay=30)
src.connect_async(SRC_HOST, 1883, 60)
src.loop_forever(retry_first_connection=True)
EOF

    cat > "$PROFILE/Tools/rtu_updater.py" << 'EOF'
#!/usr/bin/env python3
"""
UU P&L Engineering Workstation, substation RTU state updater.

Polls the relay IEDs and turbine PLC for live process values and pushes
updates to the DMZ substation RTU management interface (substation-rtu,
10.10.5.14) every ten seconds. The RTU's IEC-104 server picks up new
values on the next periodic report, so SCADA clients watching IEC-104
datapoint IO/20 see live process state.

Written: Ponder Stibbons, 2021-07-08.
"""
import json
import time
import urllib.request

from pymodbus.client import ModbusTcpClient

PLC_IP     = "10.10.3.21"
RELAY_A_IP = "10.10.3.31"
RELAY_B_IP = "10.10.3.32"
RTU_URL    = "http://10.10.5.14:8080/datapoints"
INTERVAL   = 10

# LV bus (220 V nominal) to 11-kV distribution feeder through the step-up
# transformer. 220 V -> 11.0 kV; 196 V undervoltage trip -> 9.8 kV.
VOLT_SCALE = 0.05


def mb_coil(ip, addr):
    c = ModbusTcpClient(ip, port=502, timeout=3)
    if not c.connect():
        return None
    r = c.read_coils(addr, 1, slave=1)
    c.close()
    return None if r.isError() else bool(r.bits[0])


def mb_ir(ip, addr):
    c = ModbusTcpClient(ip, port=502, timeout=3)
    if not c.connect():
        return None
    r = c.read_input_registers(addr, 1, slave=1)
    c.close()
    return None if r.isError() else r.registers[0]


def rtu_post(dp_id, value):
    body = json.dumps({"value": value}).encode()
    req  = urllib.request.Request(
        f"{RTU_URL}/{dp_id}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=5)


while True:
    try:
        trip_a    = mb_coil(RELAY_A_IP, 0)   # COIL[0]: 1=tripped, 0=closed
        trip_b    = mb_coil(RELAY_B_IP, 0)
        volt_a    = mb_ir(PLC_IP, 3)          # IR[3]: line_voltage_a, V
        volt_b    = mb_ir(PLC_IP, 5)          # IR[5]: line_voltage_b, V
        curr_a    = mb_ir(PLC_IP, 4)          # IR[4]: line_current_a, A
        freq_raw  = mb_ir(PLC_IP, 7)          # IR[7]: frequency * 10

        if trip_a   is not None: rtu_post(5, not trip_a)
        if trip_b   is not None: rtu_post(6, not trip_b)
        if volt_a   is not None: rtu_post(1, round(volt_a * VOLT_SCALE, 2))
        if volt_b   is not None: rtu_post(2, round(volt_b * VOLT_SCALE, 2))
        if curr_a   is not None: rtu_post(3, curr_a)
        if freq_raw is not None: rtu_post(4, round(freq_raw / 10.0, 2))
    except Exception:
        pass
    time.sleep(INTERVAL)
EOF
fi

# ── Cron artifact ─────────────────────────────────────────────────────────────

if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    echo "* * * * * /venv/bin/python3 /opt/win10/C/Users/engineer/Tools/poll_and_ingest.py >> /opt/win10/C/Users/engineer/plc_poll.log 2>&1  # SCHTASK:PLC-Poll" \
        | crontab -u engineer -
else
    echo "*/5 * * * * /venv/bin/python3 /opt/win10/C/Users/engineer/Tools/modbus_read.py 10.10.3.21 502 holding 0 1 >> /opt/win10/C/Users/engineer/plc_poll.log 2>&1  # SCHTASK:PLC-Poll" \
        | crontab -u engineer -
fi

# ── Permissions ───────────────────────────────────────────────────────────────

chown -R engineer:engineer /opt/win10 /home/engineer
chmod 700 "$PROFILE/.ssh"
chmod 600 "$PROFILE/.ssh/id_rsa" "$PROFILE/.ssh/known_hosts"
chmod 644 "$PROFILE/.ssh/id_rsa.pub"
chmod 600 "$PROFILE/config/plc-access.conf"
chmod 600 "$PROFILE/backups/PLC_Backup_2019.tar.gz"
chmod 600 "$PROFILE/backups/backup_2022_final_v3.zip"
chmod 750 "$PROFILE/Tools/send_alarm.ps1"
chmod 644 "$PROFILE/Tools/modbus_read.py" "$PROFILE/Tools/modbus_write.py"
if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    chmod 644 "$PROFILE/Tools/mqtt_bridge.py" "$PROFILE/Tools/rtu_updater.py"
fi

echo "[eng-ws] Waiting for PLC at 10.10.3.21:502..."
until nc -z 10.10.3.21 502 2>/dev/null; do sleep 2; done
echo "[eng-ws] PLC reachable, running first poll then starting cron."

# Run one poll synchronously so plc_poll.log has at least one entry from the
# moment the workstation is up. Cron then takes over on its */1 schedule. This
# mirrors a real engineering workstation that has been online for ages, where
# the polling log is never empty. Run as engineer to match the cron user so
# the log file ends up owned correctly for future cron-driven appends.
WIN_PROFILE="/opt/win10/C/Users/engineer"
touch "$WIN_PROFILE/plc_poll.log"
chown engineer:engineer "$WIN_PROFILE/plc_poll.log"
su engineer -s /bin/sh -c "/venv/bin/python3 $WIN_PROFILE/Tools/poll_and_ingest.py >> $WIN_PROFILE/plc_poll.log 2>&1" || true

if [ "$ICS_PROCESS" = "uupl_ied" ]; then
    touch "$WIN_PROFILE/mqtt_bridge.log" "$WIN_PROFILE/rtu_updater.log"
    chown engineer:engineer "$WIN_PROFILE/mqtt_bridge.log" "$WIN_PROFILE/rtu_updater.log"
    su -s /bin/sh engineer -c "nohup /venv/bin/python3 $WIN_PROFILE/Tools/mqtt_bridge.py >> $WIN_PROFILE/mqtt_bridge.log 2>&1 &"
    su -s /bin/sh engineer -c "nohup /venv/bin/python3 $WIN_PROFILE/Tools/rtu_updater.py >> $WIN_PROFILE/rtu_updater.log 2>&1 &"
    echo "[eng-ws] MQTT bridge and RTU updater started."
fi

cron
/usr/sbin/sshd -D
