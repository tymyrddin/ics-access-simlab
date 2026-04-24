#!/usr/bin/env bash
# enterprise-workstation entrypoint
# Sets up SSH and builds the virtual Windows 10 user profile.
set -e

# --- SSH ---
mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
PrintMotd no
EOF

# --- Virtual Windows 10 C: drive ---
# Everything the attacker sees lives here.
# Structure mirrors a real Windows 10 user profile.

WIN="C:\\Users\\bursardesk"   # display only — actual root below
PROFILE="/opt/win10/C/Users/bursardesk"

mkdir -p \
    "$PROFILE/Desktop" \
    "$PROFILE/Documents" \
    "$PROFILE/reports" \
    "$PROFILE/AppData/Roaming/UUPLOps" \
    "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine" \
    "$PROFILE/.ssh"

# ops-access.conf — operational credentials, written by Ponder for convenience.
# Stored in AppData because someone followed a "keep config out of Desktop" tip
# without understanding that AppData is not encrypted.
cat > "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf" << 'EOF'
# Operational systems access — created by Ponder Stibbons 2019-03-14
# "Just copy these into whatever tool you're using, saves the back and forth"
#
# Historian web interface
historian.host=10.10.2.10
historian.port=8080
historian.user=historian
historian.pass=Historian2015
#
# SCADA web console (read-only view)
scada.host=10.10.2.20
scada.port=8080
scada.user=admin
scada.pass=admin
EOF

# Monthly report script — PowerShell version on the Desktop.
# Hard-coded credentials because that is how it was done in 2019.
cat > "$PROFILE/Desktop/pull_monthly_report.ps1" << 'EOF'
# Monthly historian report — run on the 1st of each month
# Usage: .\pull_monthly_report.ps1 -Month 2024-04
param(
    [string]$Month = (Get-Date -Format "yyyy-MM")
)

$HistorianUrl = "http://10.10.2.10:8080"
$User         = "historian"
$Pass         = "Historian2015"

$Cred    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
$Headers = @{ Authorization = "Basic $Cred" }
$Uri     = "$HistorianUrl/report?asset=turbine_main&from=$Month-01&to=$Month-28"
$OutFile = "$HOME\reports\turbine_$Month.csv"

New-Item -ItemType Directory -Force -Path "$HOME\reports" | Out-Null
Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile
Write-Host "Done. Report saved to $OutFile"
EOF

# PSReadLine history — PowerShell command history.
# The equivalent of .bash_history, and just as revealing.
cat > "$PROFILE/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" << 'EOF'
dir
cd AppData\Roaming\UUPLOps
Get-Content .\ops-access.conf
cd ~
.\Desktop\pull_monthly_report.ps1 -Month 2024-03
ssh engineer@10.10.2.30
ping 10.10.2.10
Invoke-WebRequest -Uri "http://10.10.2.10:8080/report?asset=turbine_main&from=2024-04-01&to=2024-04-28" -Headers @{Authorization="Basic aGlzdG9yaWFuOkhpc3RvcmlhbjIwMTU="} -OutFile .\reports\turbine_2024-04.csv
nmap -sn 10.10.2.0/24
ssh engineer@10.10.2.30
cat plc-access.conf
exit
dir .\reports
EOF

# notes.txt in Documents — informal operational notes
cat > "$PROFILE/Documents/notes.txt" << 'EOF'
Misc operational notes — please do not delete

Access to historian: see AppData\Roaming\UUPLOps\ops-access.conf
If historian is down, call Ponder (ext 201) before trying anything yourself.

Monthly report script is on the Desktop. Runs on the 1st of each month.
If it fails mid-month, re-run manually:
  .\Desktop\pull_monthly_report.ps1 -Month 2024-04

SSH to eng workstation: engineer @ 10.10.2.30
(ask Ponder for the password — not keeping it here again)

SCADA is read-only from here. Changes go through Sgt Colon (ext 105).

Note from Reg Shoe: "All historical reports should be in C:\Users\bursardesk\reports.
Yes, I know December is missing. I am working on it."
EOF

# Pre-generated turbine reports
cat > "$PROFILE/reports/turbine_2024-01.csv" << 'EOF'
timestamp,asset,rpm,temp_c,pressure_bar,voltage_a,current_a,voltage_b,current_b
2024-01-15T08:00:00,turbine_main,2987,182.3,4.1,11042,312.4,10988,309.1
2024-01-15T08:05:00,turbine_main,2991,183.1,4.1,11038,311.9,10994,310.2
2024-01-15T12:00:00,turbine_main,3002,184.7,4.2,11051,313.8,11003,311.7
2024-01-15T16:00:00,turbine_main,2998,183.9,4.1,11047,312.9,10999,310.8
2024-01-31T23:55:00,turbine_main,2994,183.4,4.1,11044,312.5,10996,310.4
EOF

cat > "$PROFILE/reports/turbine_2024-02.csv" << 'EOF'
timestamp,asset,rpm,temp_c,pressure_bar,voltage_a,current_a,voltage_b,current_b
2024-02-01T08:00:00,turbine_main,2983,181.8,4.0,11039,311.7,10985,308.9
2024-02-14T08:00:00,turbine_main,2990,182.6,4.1,11041,312.0,10989,309.4
2024-02-28T23:55:00,turbine_main,2987,182.4,4.0,11038,311.8,10986,309.2
EOF

cat > "$PROFILE/reports/turbine_2024-03.csv" << 'EOF'
timestamp,asset,rpm,temp_c,pressure_bar,voltage_a,current_a,voltage_b,current_b
2024-03-01T08:00:00,turbine_main,2989,182.7,4.1,11040,312.1,10987,309.3
2024-03-15T12:00:00,turbine_main,2993,183.2,4.1,11043,312.6,10991,310.0
2024-03-31T23:55:00,turbine_main,2996,183.7,4.1,11046,313.1,10995,310.5
EOF

# .ssh/known_hosts — systems bursardesk has connected to
cat > "$PROFILE/.ssh/known_hosts" << 'EOF'
10.10.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBk7t3v2mNpOqLxRdYuHsWcAeJ9fKgXnMbZoQpTyVwIu
10.10.2.20 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDrm4wHqP8yNcXeGsAfLjVtUkZoBpWnMdCiRlTuSvYxE
10.10.2.30 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFvn6xKpQrYeHdMbWoLgJcNuAtZsSiTmXqBfDkRwPjGy
EOF

# Careless copy left in temp — someone needed it outside the profile
cp "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf" /tmp/ops-access.conf.bak
chmod 644 /tmp/ops-access.conf.bak

# Fix ownership
chown -R bursardesk:bursardesk /opt/win10
chmod 700 "$PROFILE/.ssh"
chmod 600 "$PROFILE/.ssh/known_hosts"
chmod 600 "$PROFILE/AppData/Roaming/UUPLOps/ops-access.conf"

# Also wire up the real Linux home dir .ssh so SSH agent/known_hosts work
# when bursardesk uses the ssh command from within the shell
mkdir -p /home/bursardesk/.ssh
cp "$PROFILE/.ssh/known_hosts" /home/bursardesk/.ssh/known_hosts
chown -R bursardesk:bursardesk /home/bursardesk/.ssh
chmod 700 /home/bursardesk/.ssh
chmod 600 /home/bursardesk/.ssh/known_hosts

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
# Dual-homed (enterprise + operational); only non-adjacent zones need explicit routes.
_add_route 10.10.5.0/24 10.10.1.202

/usr/sbin/sshd -D
