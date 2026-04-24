#!/usr/bin/env bash
# scada-server entrypoint
# Sets up SSH with Windows Server 2016 facade, builds virtual filesystem,
# then starts sshd and the Flask web server.
set -e

HISTORIAN_IP="${HISTORIAN_IP:-10.10.2.10}"
PROFILE="/opt/winsvr/C/Users/scada_admin"

# ── SSH ───────────────────────────────────────────────────────────────────────

mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
PrintMotd no
EOF

# ── Virtual C: drive ─────────────────────────────────────────────────────────

mkdir -p \
    "$PROFILE/Desktop" \
    "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine" \
    "/opt/winsvr/C/SCADA/Config" \
    "/opt/winsvr/C/SCADA/Scripts" \
    "/opt/winsvr/C/SCADA/Logs"

# ── C:\SCADA\Config\scada.ini ─────────────────────────────────────────────────

cat > "/opt/winsvr/C/SCADA/Config/scada.ini" << EOF
; UU P&L Distribution SCADA — Connection Configuration
; Written: 2021-08-14  Author: I. Devious, Hex IT
; DO NOT DISTRIBUTE — contains service credentials

[historian]
host     = ${HISTORIAN_IP}
port     = 8080
user     = hist_read
password = history2017

[scada_web]
host     = 10.10.2.20
port     = 8080
user     = admin
password = admin

[alarm_smtp]
host     = mail.uu.am
port     = 587
user     = alarms@uupl.am
password = plantmail123

[scada_admin]
ssh_user = scada_admin
ssh_pass = W1nd0ws@2016
notes    = Windows admin account. Set at installation. IT asked about rotating it in 2022.
           Ticket raised. Ticket closed. Not rotated.
EOF

cat > "/opt/winsvr/C/SCADA/Config/alarm_recipients.txt" << 'EOF'
# UU P&L SCADA — Alarm Notification Recipients
# Updated: 2025-11-03  P. Stibbons

[critical]
ops-duty@uupl.am
ponder.stibbons@uupl.am

[warning]
ops-duty@uupl.am

[info]
; No auto-notification for info alarms. Check SCADA\Logs\ manually.
EOF

# ── C:\SCADA\Scripts\ ─────────────────────────────────────────────────────────

cat > "/opt/winsvr/C/SCADA/Scripts/send_alarm.bat" << 'EOF'
@echo off
REM UU P&L SCADA — Alarm notification relay
REM Called by SCADA monitor when trip conditions are detected.
REM Written: 2018-06-22  Last modified: 2023-01-09

set SMTP_HOST=mail.uu.am
set SMTP_PORT=587
set SMTP_USER=alarms@uupl.am
set SMTP_PASS=plantmail123
set ALERT_TO=ops-duty@uupl.am

curl -s --ssl-reqd ^
  --url "smtp://%SMTP_HOST%:%SMTP_PORT%" ^
  --user "%SMTP_USER%:%SMTP_PASS%" ^
  --mail-from "%SMTP_USER%" ^
  --mail-rcpt "%ALERT_TO%" ^
  --upload-file alarm_body.txt
EOF

# Also write the actual shell script used at runtime
mkdir -p /opt/scada/scripts
cat > /opt/scada/scripts/send_alarm.sh << 'EOF'
#!/usr/bin/env bash
# UU P&L SCADA — Alarm notification relay
SMTP_HOST="mail.uu.am"
SMTP_PORT=587
SMTP_USER="alarms@uupl.am"
SMTP_PASS="plantmail123"
ALERT_TO="ops-duty@uupl.am"

curl -s --ssl-reqd \
  --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
  --user "${SMTP_USER}:${SMTP_PASS}" \
  --mail-from "${SMTP_USER}" \
  --mail-rcpt "${ALERT_TO}" \
  --upload-file - << MAIL
From: UU P&L SCADA Alarms <${SMTP_USER}>
To: Duty Engineer <${ALERT_TO}>
Subject: [ALARM] ${1:-SCADA alarm}

${2:-No detail provided.}

--
UU P&L Distribution SCADA v2.1
MAIL
EOF
chmod 750 /opt/scada/scripts/send_alarm.sh

cat > "/opt/winsvr/C/SCADA/Scripts/poll_historian.ps1" << EOF
# Polls historian for current plant state. Run on demand or via Task Scheduler.
# Uses hist_read account — read-only access to historian web API.

\$HistorianUrl = "http://${HISTORIAN_IP}:8080"
\$User         = "hist_read"
\$Pass         = "history2017"
\$Cred         = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("\${User}:\${Pass}"))
\$Headers      = @{ Authorization = "Basic \$Cred" }

\$assets = (Invoke-WebRequest -Uri "\$HistorianUrl/assets" -Headers \$Headers).Content.Split(\`n)
foreach (\$asset in \$assets | Select-Object -First 10) {
    \$resp = Invoke-WebRequest -Uri "\$HistorianUrl/report?asset=\$asset&from=2026-01-01&to=2099-01-01" ``
        -Headers \$Headers
    Write-Host "\$asset: \$((\$resp.Content.Split(\`n)[-1]))"
}
EOF

# ── C:\SCADA\Logs\ ────────────────────────────────────────────────────────────

cat > "/opt/winsvr/C/SCADA/Logs/alarm_log_2026.txt" << 'EOF'
UU P&L Distribution SCADA — Alarm Log 2026
===========================================
Format: timestamp | severity | asset | value | threshold | action

2026-01-14T03:22:11 | WARNING  | turbine_rpm        | 3151 RPM  | hi=3150   | notified ops-duty
2026-01-14T03:22:43 | CLEAR    | turbine_rpm        | 3048 RPM  | -         | auto-clear
2026-02-03T11:07:55 | WARNING  | turbine_temperature| 462 C     | hi=460    | notified ops-duty
2026-02-03T11:08:02 | CLEAR    | turbine_temperature| 441 C     | -         | auto-clear
2026-02-19T22:44:01 | CRITICAL | line_voltage_a     | 193 V     | lo_lo=184 | relay trip — Feeder A offline
2026-02-19T22:44:09 | CRITICAL | relay_a_trip       | 1 (tripped)| -        | send_alarm.bat executed
2026-02-19T22:54:22 | INFO     | relay_a_trip       | 0 (reclosed)| -       | feeder restored
2026-03-01T08:30:00 | INFO     | turbine_rpm        | 3002 RPM  | -         | daily check OK
EOF

# ── PSReadLine history ────────────────────────────────────────────────────────

cat > "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" << EOF
cd C:\SCADA\Config
Get-Content .\scada.ini
cd C:\SCADA\Logs
Get-Content .\alarm_log_2026.txt
cd C:\SCADA\Scripts
.\poll_historian.ps1
curl http://${HISTORIAN_IP}:8080/status
curl http://${HISTORIAN_IP}:8080/assets
ssh hist_admin@${HISTORIAN_IP}
ping 10.10.3.21
nmap -sV 10.10.2.0/24
cd ~
dir
EOF

cat > "$PROFILE/Desktop/README.txt" << 'EOF'
SCADA-SRV01 — Quick Reference
==============================

Web dashboard:  http://10.10.2.20:8080/   (admin/admin)
Config dump:    http://10.10.2.20:8080/config  (same creds)
Historian:      http://10.10.2.10:8080/

SCADA config:   C:\SCADA\Config\scada.ini
Alarm scripts:  C:\SCADA\Scripts\
Event logs:     C:\SCADA\Logs\

For historian credentials see C:\SCADA\Config\scada.ini
EOF

# ── Permissions ───────────────────────────────────────────────────────────────

chown -R scada_admin:scada_admin /opt/winsvr
chmod 600 "/opt/winsvr/C/SCADA/Config/scada.ini"

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
echo "[scada-server] Starting web on :${WEB_PORT:-8080}, historian at ${HISTORIAN_IP}"
exec python3 /opt/scada/app/server.py
