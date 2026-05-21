# Legacy workstation

## Device description

A Win95-era service stack workstation simulating a late-1990s office environment.

* Designed for connectivity, not security: SMB, FTP, Telnet, and early SSH run openly.
* Accounts use weak, static passwords.
* Security assumptions: "anyone on the network is trusted."
* Dual role: file shares for operations and engineering, FTP for external partners, Telnet for remote maintenance.
* Acted as a bridge between corporate and OT networks, often unwittingly.

From an attacker’s perspective:

* All services are discoverable and accessible.
* Weak authentication allows easy credential harvesting.
* Historical data in shares, logs, and network inventory provides a blueprint for the environment.
* This is your classic pivot workstation.

## Example container behaviour

Your Dockerfile already mirrors this behaviour:

* Debian-based container simulating Win95-era services.
* SMB with share-level security (public + private).
* FTP with anonymous read-only access.
* Telnet: no login prompt, drops directly into the DOS facade shell.
* The public share (`\\HEX-LEGACY-1\public`) contains the operational documents.
* Share-level files are the primary artefact surface.

The SMB shares run on Samba (Linux). From a participant's perspective this is invisible: the share names, access 
controls, and NTLMv1 authentication behave as they would on a native Win95 server. The distinction matters only 
inside the container, where Samba configuration lives at Linux filesystem paths rather than in the Windows registry.

Key point: nothing is “broken”, everything is authentically old-school operational defaults.

## Deliberately introduced vulnerabilities

### Weak credentials

* Administrator and root accounts use dictionary-like passwords (`hex123`).
* These were standard practice for the era, often documented on sticky notes.

### Legacy protocols

* Telnet: no authentication required; the session itself is unencrypted.
* FTP: anonymous login enabled, exposing public data.
* Samba NT1 + LM hashes: vulnerable to cracking and man-in-the-middle attacks.

### Default share permissions

* `public` share allows read access to operational documents.
* `private` share restricted only by username/password.
* Permissions reflect typical 1990s NT/SMB defaults.

### Lack of patching

Services reflect pre-2000 behaviour; any vulnerabilities documented for that era (SMBv1 buffer overflows, vsftpd misconfigurations) are present.

## Real-world vulnerabilities / CVEs

| Component             | CVE / Example | Notes                                                                  |
|-----------------------|---------------|------------------------------------------------------------------------|
| Samba NT1 / LM hashes | CVE-1999-0484 | Weak LM hash allows offline password cracking                          |
| vsftpd 2.3.4 source code        | CVE-2011-2523 | Backdoor in earlier vsftpd, conceptually matches old unpatched servers |
| Telnet service        | N/A           | Plaintext credentials, classic MITM / sniffing risk                    |
| SMBv1 shares          | CVE-2017-0143 | EternalBlue; illustrates the old SMB protocol vulnerabilities          |

* Not all weaknesses map to a CVE: many are operational or protocol flaws, not software bugs. This is exactly why legacy workstations remain high-value targets.
* EternalBlue is associated with CVE-2017-0144, and CVE-2017-0143 is a related SMBv1 RCE flaw.

## Artefacts

### Configuration files

* `UUPL\NETWORK.TXT` (public share): current network segments, 10.10.x.x IPs, 2019
* `NETWORK_INVENTORY.TXT` (public share root): 1999 version with old IP ranges, still present

### Credentials

* Local passwords (`Administrator:hex123`, `root:hex123`)
* NTLMv1 authentication on all SMB connections; any captured challenge is crackable offline (Responder on the enterprise segment captures it on any SMB browse)
* FTP: anonymous access, no credentials required. Telnet: no login prompt; session traffic unencrypted
* Historian ingest credential (`hist_read / history2017`) in `LOGBOOK\ENGINEER.LOG` only
* SCADA SSH credential (`scada_admin / W1nd0ws@2016`) in `LOGBOOK\ENGINEER.LOG`

### Operational documents

* The public share (`\\HEX-LEGACY-1\public`, pre-mapped as `G:`) contains:

  * `LOGBOOK\ENGINEER.LOG`: all system passwords; the only source of hist_read and scada_admin credentials
  * `UUPL\NETWORK.TXT`: current network inventory (10.10.x.x, 2019)
  * `NETWORK_INVENTORY.TXT`: 1999 network map at share root, old IP ranges, still present
  * `PROCEDURES.TXT`: operational procedures

* The C: drive (Telnet) contains:

  * `C:\LOGBOOK\ENGINEER.LOG`: all system passwords; same content as the public share copy
  * `C:\UUPL\NETWORK.TXT`: current network inventory; same content as the public share copy
  * `C:\UUPL\PROCS.TXT`: Modbus coil names and actuator IPs
  * `C:\UUPL\SCADA\LOGS.CSV`: SCADA event log 1999-2003
  * `C:\PRIVATE\PLCACCS.CFG`: historian, SCADA, and SSH credentials
  * `C:\PRIVATE\BACKUP.BAK`: domain admin password from 2003 migration, never deleted

* The private share (`\\HEX-LEGACY-1\private`, Administrator:hex123) contains:

  * `PLC-ACCESS.CONF`: same credentials as PLCACCS.CFG (historian, SCADA, eng-ws)
  * `OLD-BACKUP.BAK`: copy of BACKUP.BAK from the 2003 migration

## Role in the simulator

* Initial foothold: any attacker with network access can exploit weak protocols.
* Information discovery point: artefacts give full map of OT and corporate networks.
* Credential harvesting target: offline cracking of LM/NTLM hashes, plaintext FTP/Telnet passwords.
* Pivot potential: used to access private shares or reach engineering workstations.

Attackers typically follow:

```text
legacy workstation compromise via Telnet or anonymous FTP
        ↓
map public share (G:), read LOGBOOK\ENGINEER.LOG and UUPL\NETWORK.TXT
        ↓
use Administrator:hex123 (from C:\PRIVATE\BACKUP.BAK) to access C:\PRIVATE\
        ↓
read PLCACCS.CFG for historian, SCADA, and engineer SSH credentials
        ↓
pivot to uupl-historian (hist_read / history2017) or SCADA (admin / admin)
```

## Legacy workstation artefacts

Location: public share (`\\HEX-LEGACY-1\public`, G:) and C: drive via Telnet

| File / Directory                               | Purpose / Description | Notes for attacker                                             |
|------------------------------------------------|-----------------------|----------------------------------------------------------------|
| `UUPL\NETWORK.TXT` (public share)              | Current network map   | 10.10.x.x IPs, hostnames; 2019 update                          |
| `NETWORK_INVENTORY.TXT` (share root)           | 1999 network map      | Old IP ranges; confirms years of neglect                       |
| `LOGBOOK\ENGINEER.LOG` (public share)          | Engineering logbook   | All system passwords; only source of hist_read and scada_admin |
| `C:\PRIVATE\PLCACCS.CFG`                       | PLC and system access | Historian, SCADA, engineer SSH credentials                     |
| `C:\PRIVATE\BACKUP.BAK`                        | Migration backup      | `Administrator / hex123` from 2003 migration, never deleted    |
| `C:\UUPL\SCADA\LOGS.CSV`                       | SCADA event log       | Events 1999-2003; asset names, relay trip history              |
| `C:\UUPL\PROCS.TXT`                            | Process procedures    | Modbus coil names and actuator IPs                             |

Extras that make it feel “1999 real”:

* `AUTOEXEC.BAT` and `CONFIG.SYS` on C: for atmosphere
* `C:\WINDOWS\WIN.INI` and `C:\WINDOWS\SYSTEM\PROTOCOL.INI` for network config artefacts

## Legacy workstation folder tree

```
C:\   (accessible via Telnet)
├── LOGBOOK\
│   └── ENGINEER.LOG         # All system passwords (same as public share copy)
├── PRIVATE\
│   ├── BACKUP.BAK           # Administrator / hex123, 2003 migration
│   └── PLCACCS.CFG          # historian, SCADA, engineer SSH credentials
├── UUPL\
│   ├── NETWORK.TXT          # Current network inventory (same as public share copy)
│   ├── PROCS.TXT            # Modbus coil names, actuator IPs
│   └── SCADA\
│       └── LOGS.CSV         # SCADA event log 1999-2003
└── WINDOWS\
    ├── WIN.INI
    └── SYSTEM\
        └── PROTOCOL.INI

\\HEX-LEGACY-1\public   (pre-mapped as G:, no credentials required)
├── LOGBOOK\
│   └── ENGINEER.LOG         # All system passwords
├── UUPL\
│   └── NETWORK.TXT          # Current network inventory (10.10.x.x, 2019)
├── NETWORK_INVENTORY.TXT    # 1999 network map, old IP ranges
└── PROCEDURES.TXT           # Operational procedures

\\HEX-LEGACY-1\private  (Administrator:hex123 required)
├── PLC-ACCESS.CONF          # Same credentials as PLCACCS.CFG
└── OLD-BACKUP.BAK           # Copy of BACKUP.BAK from 2003 migration
```
