#!/usr/bin/env bash
# legacy-workstation entrypoint
# Configures and starts services as they would have been in a 1990s Windows shop.
# Nothing here is intentionally broken — it's intentionally correct for its era.
set -e

# --- Samba ---
# Guest/null session access was the default. Share-level security.
# "security = share" was deprecated but was standard through Windows 98.
cat > /etc/samba/smb.conf << 'EOF'
[global]
    workgroup = UUPL
    server string = UU P&L Inventory Server
    security = user
    map to guest = Bad User
    guest account = nobody
    log level = 0
    # NTLMv1 was the norm. LAN Manager hashes in the wild.
    lanman auth = yes
    ntlm auth = yes
    client lanman auth = yes
    min protocol = CORE
    max protocol = NT1

[public]
    path = /srv/smb/public
    browseable = yes
    read only = yes
    guest ok = yes
    comment = UU P&L Public Documents

[private]
    path = /srv/smb/private
    browseable = no
    read only = no
    valid users = Administrator
    comment = Administration
EOF

# Local user — password set at build time in the realistic weak way
# (short, dictionary word, matches what's on a sticky note somewhere)
useradd -M -s /bin/false Administrator 2>/dev/null || true
echo "Administrator:hex123" | chpasswd
(echo "hex123"; echo "hex123") | smbpasswd -a Administrator -s

# --- FTP ---
# vsftpd with anonymous access. Read-only anonymous was considered safe.
cat > /etc/vsftpd.conf << 'EOF'
listen=YES
anonymous_enable=YES
local_enable=YES
write_enable=NO
anon_root=/srv/smb/public
anon_upload_enable=NO
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=NO
connect_from_port_20=YES
ftpd_banner=UU P&L FTP Service
EOF

# --- SSH ---
# SSH was added later. PasswordAuthentication left on, root login permitted
# because the sysadmin needed to get in remotely.
mkdir -p /var/run/sshd
cat >> /etc/ssh/sshd_config << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
PrintMotd yes
EOF
echo "root:hex123" | chpasswd

# --- Telnet ---
# Still running. Nobody turned it off.
cat > /etc/xinetd.d/telnet << 'EOF'
service telnet
{
    flags           = REUSE
    socket_type     = stream
    wait            = no
    user            = root
    server          = /usr/sbin/in.telnetd
    log_on_failure  += USERID
    disable         = no
}
EOF

# --- Virtual C: drive (what attackers see in the DOS shell) ---
# Uppercase 8.3 DOS-style filenames throughout.
# This is the filesystem root that win95shell.sh navigates.

mkdir -p /opt/legacy/C/{WINDOWS/SYSTEM,UUPL/SCADA,LOGBOOK,PRIVATE}

cat > /opt/legacy/C/AUTOEXEC.BAT << 'EOF'
@ECHO OFF
PROMPT $P$G
SET PATH=C:\WINDOWS;C:\DOS
NET USE F: \\UUPL-SRV-01\operations$ /persistent:yes
EOF

cat > /opt/legacy/C/CONFIG.SYS << 'EOF'
DEVICE=C:\WINDOWS\HIMEM.SYS
DEVICE=C:\WINDOWS\EMM386.EXE NOEMS
DOS=HIGH,UMB
FILES=40
BUFFERS=20
EOF

cat > /opt/legacy/C/WINDOWS/WIN.INI << 'EOF'
[windows]
load=
run=
NullPort=None
device=HP LaserJet IIP,HPPCL,LPT1:

[Desktop]
Pattern=(None)
Wallpaper=(None)
GridGranularity=0

[Network]
LogonDomain=UUPL
LMLogon=1
EOF

cat > /opt/legacy/C/WINDOWS/SYSTEM/PROTOCOL.INI << 'EOF'
[network.setup]
version=0x3110
netcard=ms$elnkii,1,MS$ELNKII
transport=tcpip,TCPIP

[TCPIP]
DHCP=0
IPAddress=10.10.1.10
SubnetMask=255.255.255.0
DefaultGateway=10.10.1.1
EOF

# UUPL\ — public operational data, the first goldmine
cat > /opt/legacy/C/UUPL/NETWORK.TXT << 'EOF'
UU P&L Network Inventory — Hex Computing Division
Last updated: Q3 1999 (Ponder Stibbons)

=== NETWORK SEGMENTS ===

Operations Floor (Building B Basement)
  Gateway:        192.168.1.1
  Workstations:   192.168.1.10-30
  Printers:       192.168.1.40-45

Engineering (Building A, Level 2)
  Gateway:        10.10.2.1
  ENG-WS-01:      10.10.2.30   (Ponder Stibbons — DO NOT REBOOT WITHOUT WARNING)
  ENG-WS-02:      10.10.2.31   (Spare — often borrowed by Archchancellor)

Operational Systems
  Historian:      10.10.2.10   (HISTORIAN-01, web API :8080)
  SCADA:          10.10.2.20   (distribution-scada, web console :8080)

Turbine Control (Basement Sub-Level 3)
  NOTE: Separate network. Access via ENG-WS-01 only.
  Password in engineering logbook (C:\LOGBOOK\ENGINEER.LOG)

Distribution SCADA (Offsite, Dolly Sisters relay hut)
  Dial-in: see Sgt Colon for modem number

=== SERVERS ===

UUPL-SRV-01   File server / domain controller
              \\uupl-srv-01\operations$ (Administrator, hex123)

HISTORIAN-01  Process data logger
              Running since 1997. Do not restart without notifying Ponder.
              Web interface: http://10.10.2.10:8080
              Credentials: see C:\PRIVATE\PLCACCS.CFG

=== KNOWN ISSUES ===

- Turbine controller PLC does not respond to Modbus after power cycle.
  Workaround: wait 90 seconds before polling.
- Historian web interface returns SQL errors on reports with apostrophes.
  Known issue, vendor says it is a "cosmetic limitation."
- FTP server on this machine (hex-legacy-1) has no write access. Use SMB.

=== CONTACTS ===

Ponder Stibbons  ext 201  (all technical matters)
Sgt Colon        ext 105  (operations floor; modem numbers)
Archchancellor   ext 100  (emergencies only; define carefully)
EOF

cat > /opt/legacy/C/UUPL/PROCS.TXT << 'EOF'
UU P&L Hex Turbine -- Standard Operating Procedures
Last reviewed: 2019-11-12 / P. Stibbons

PROCEDURE: Turbine Start-up
1. Confirm all protective relay trips are RESET on HMI (10.10.3.10)
2. Open throttle valve incrementally (actuator at 10.10.3.51)
3. Allow RPM to stabilise above 2900 before closing distribution breakers
4. Monitor relay A (Dolly Sisters, 10.10.3.31) and relay B (Nap Hill, 10.10.3.32)
5. Report stable generation to Sgt Colon (ext 105)

PROCEDURE: Emergency Shutdown
1. Set Modbus coil 0 = TRUE on hex_turbine_controller (10.10.3.21)
   OR use the physical emergency stop button on HMI panel
2. Confirm breakers A and B open (actuators 10.10.3.53, 10.10.3.54)
3. Notify Ponder Stibbons (ext 201) immediately

PROCEDURE: Monthly Report
1. Log in to historian: http://10.10.2.10:8080
   Credentials: see C:\PRIVATE\PLCACCS.CFG
2. Query asset "turbine_main", date range 1st to last of month
3. Export CSV, forward to bursar-desk workstation (10.10.1.20)
EOF

cat > /opt/legacy/C/UUPL/SCADA/LOGS.CSV << 'EOF'
timestamp,asset,event,value,unit,operator
1999-06-01T07:52:11,hex_turbine_controller,startup,1,,wizard_technician
1999-06-01T07:54:33,throttle_valve,setpoint,35,percent,wizard_technician
1999-06-01T08:01:07,turbine_main,rpm,2987,rpm,auto
1999-06-15T14:22:41,ied_relay_b,trip,1,,auto
1999-06-15T14:22:41,turbine_main,rpm,2741,rpm,auto
1999-06-15T14:23:10,ied_relay_b,trip_reset,0,,engineer
2003-11-12T09:11:05,hex_turbine_controller,config_write,1,,ponder_stibbons
2003-11-12T09:11:22,ied_relay_a,config_write,1,,ponder_stibbons
EOF

# LOGBOOK\ — engineering logbook with sticky-note passwords
cat > /opt/legacy/C/LOGBOOK/ENGINEER.LOG << 'EOF'
=== ENGINEERING LOGBOOK -- UU P&L HEX TURBINE DIVISION ===
(Ponder Stibbons' informal notes -- do not bin this)

SYSTEM PASSWORDS (last updated 2019-11-12)
------------------------------------------
Turbine PLC:       no password (Modbus TCP, network IS the access control)
Historian DB:      hist1999 (old), Historian2015 (current web API)
Engineer SSH:      spanner99
Administrator:     hex123
HMI operator:      hex123

Emergency stop: Modbus coil 0 on hex_turbine_controller (10.10.3.21)
                DO NOT write without coordinating with duty engineer.

KNOWN ISSUES
------------
- IED relay B (Nap Hill, 10.10.3.32) gives false positive trips when
  voltage drops below 10800V. Workaround: raise trip threshold via
  Modbus HR[10]. Reset before leaving shift.

- Historian web API returns SQL errors on asset names with apostrophes.
  Vendor says it is a "cosmetic limitation." It is not cosmetic.

CONTACTS
--------
Ponder Stibbons  ext 201
Sgt Colon        ext 105 (operations floor, knows where the modem numbers are)
The Librarian    (server room, do not disturb without bananas)
Archchancellor   ext 100 (emergencies only -- define carefully)
EOF

# PRIVATE\ — restricted, but Win95 had no local file permissions.
# Anyone who gets a shell gets everything.
cat > /opt/legacy/C/PRIVATE/PLCACCS.CFG << 'EOF'
; UU P&L -- PLC and System Access Credentials
; Maintained by Ponder Stibbons (last updated 2019-11-12)
; DO NOT DISTRIBUTE -- authorised staff only

[engineering_workstation]
host     = 10.10.2.30
user     = engineer
pass     = spanner99
protocol = ssh
notes    = Has plc-access.conf with full Modbus device list.

[historian_web]
host     = 10.10.2.10
port     = 8080
user     = historian
pass     = Historian2015
protocol = http
notes    = Process historian web API. DB direct: pass hist1999 (ask Ponder).

[scada_console]
host     = 10.10.2.20
port     = 8080
user     = admin
pass     = admin
protocol = http
notes    = Read-only view. Admin/admin not changed. Known issue.
EOF

cat > /opt/legacy/C/PRIVATE/BACKUP.BAK << 'EOF'
[backup created 2003-11-04 by wsadmin]
source: \\UUPL-SRV-01\operations$

Previous hostname: HEXLEG-WS1
New hostname:      hex-legacy-1

--- Domain admin account at time of migration ---
Administrator / hex123

--- Note from Ponder ---
This file can be deleted once we confirm nothing was lost in the migration.
That was 2003. Nothing has been deleted.
EOF

# Set root's login shell to the DOS emulator.
# The entrypoint itself runs as root via Docker ENTRYPOINT, not as a login
# shell, so changing the shell here does not affect container startup.
usermod -s /usr/local/bin/win95shell.sh root

# --- Private share contents ---
# Restricted to Administrator but contains the information that makes this
# machine valuable as a pivot point. These files existed on the real server
# and were migrated without review when the hardware was replaced.

cat > /srv/smb/private/plc-access.conf << 'EOF'
# UU P&L -- PLC and System Access Credentials
# Maintained by Ponder Stibbons (last updated 2019-11-12)
# DO NOT DISTRIBUTE -- authorised staff only

[engineering_workstation]
host     = 10.10.2.30
user     = engineer
pass     = spanner99
protocol = ssh
notes    = Engineering workstation. Has plc-access.conf with full Modbus device list.

[historian_web]
host     = 10.10.2.10
port     = 8080
user     = historian
pass     = Historian2015
protocol = http
notes    = Process historian web API. DB direct access: pass hist1999 (ask Ponder).

[scada_console]
host     = 10.10.2.20
port     = 8080
user     = admin
pass     = admin
protocol = http
notes    = Read-only view. Admin/admin has not been changed. Known issue.
EOF
chmod 640 /srv/smb/private/plc-access.conf

cat > /srv/smb/private/old-backup.bak << 'EOF'
[backup created 2003-11-04 by wsadmin]
source: \\UUPL-SRV-01\operations$
dest: /srv/smb/private/old-backup.bak

Previous hostname: HEXLEG-WS1
New hostname:      hex-legacy-1

--- Domain admin account at time of migration ---
Administrator / hex123

--- Note from Ponder ---
This file can be deleted once we confirm nothing was lost in the migration.
That was 2003. Nothing has been deleted.
EOF
chmod 640 /srv/smb/private/old-backup.bak

# --- Engineering logbook ---
# Sticky-note style plaintext passwords. These were written down because
# the plant operators needed to get things done without calling Ponder.
mkdir -p /opt/legacy/data
cat > /opt/legacy/data/engineering-logbook.txt << 'EOF'
=== ENGINEERING LOGBOOK -- UU P&L HEX TURBINE DIVISION ===
(Ponder Stibbons' informal notes -- do not bin this)

SYSTEM PASSWORDS (last updated 2019-11-12)
------------------------------------------
Turbine PLC:       no password (Modbus TCP, network IS the access control)
Historian DB:      hist1999 (old), Historian2015 (current web API)
Engineer SSH:      spanner99
Administrator:     hex123
HMI operator:      hex123

Emergency stop: Modbus coil 0 on hex_turbine_controller (10.10.3.21)
                DO NOT write without coordinating with duty engineer.

KNOWN ISSUES
------------
- IED relay B (Nap Hill, 10.10.3.32) gives false positive trips when
  voltage drops below 10800V. Workaround: raise trip threshold temporarily
  via Modbus HR[10]. Reset it before leaving shift.

- Historian web API returns SQL errors on asset names with apostrophes.
  Vendor says it is a "cosmetic limitation." It is not cosmetic.

- FTP on hex-legacy-1 has no write access. Use SMB share instead.

CONTACTS
--------
Ponder Stibbons  ext 201
Sgt Colon        ext 105 (operations floor, knows where the modem numbers are)
The Librarian    (server room, do not disturb without bananas)
Archchancellor   ext 100 (emergencies only -- define carefully)
EOF
chmod 644 /opt/legacy/data/engineering-logbook.txt

# --- /etc/motd ---
cat > /etc/motd << 'EOF'

  UU P&L Network Inventory System v2.3
  Hex Computing Division

  Authorised users only. Contact Ponder Stibbons for access issues.

EOF

# Start services
service smbd start
service nmbd start
mkdir -p /var/run/vsftpd/empty
vsftpd &
service xinetd start
/usr/sbin/sshd -D