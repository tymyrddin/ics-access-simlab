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
* Telnet + SSH with weak credentials.
* Home directories and `/srv/smb/public` contain realistic operational documents.
* `.txt` files in `data/shares/` act as artefacts.

Key point: nothing is “broken”, everything is authentically old-school operational defaults.

## Deliberately introduced vulnerabilities

### 1. Weak credentials

* Administrator and root accounts use dictionary-like passwords (`hex123`).
* These were standard practice for the era, often documented on sticky notes.

### 2. Legacy protocols

* Telnet: plaintext credentials across the network.
* FTP: anonymous login enabled, exposing public data.
* Samba NT1 + LM hashes: vulnerable to cracking and man-in-the-middle attacks.

### 3. Default share permissions

* `public` share allows read access to operational documents.
* `private` share restricted only by username/password.
* Permissions reflect typical 1990s NT/SMB defaults.

### 4. Lack of patching

* Services reflect pre-2000 behaviour; any vulnerabilities documented for that era (SMBv1 buffer overflows, vsftpd misconfigurations) are present.

## Real-world vulnerabilities / CVEs

| Component             | CVE / Example | Notes                                                                  |
|-----------------------|---------------|------------------------------------------------------------------------|
| Samba NT1 / LM hashes | CVE-1999-0484 | Weak LM hash allows offline password cracking                          |
| vsftpd <=2.0.5        | CVE-2011-2523 | Backdoor in earlier vsftpd, conceptually matches old unpatched servers |
| Telnet service        | N/A           | Plaintext credentials, classic MITM / sniffing risk                    |
| SSH (weak password)   | N/A           | Credential reuse + default root login; brute force easily succeeds     |
| SMBv1 shares          | CVE-2017-0143 | EternalBlue; illustrates the old SMB protocol vulnerabilities          |

Not all weaknesses map to a CVE: many are operational or protocol flaws, not software bugs. This is exactly why legacy workstations remain high-value targets.

## Artefacts attackers should find

### 1. Configuration files

* `/etc/samba/smb.conf`, share names, permissions, authentication type
* `/etc/vsftpd.conf`, FTP service parameters
* `/etc/xinetd.d/telnet`, Telnet availability
* `/opt/legacy/config/network_inventory.txt`, network segments, IPs, gateways, workstations

### 2. Credentials

* Local passwords (`Administrator:hex123`, `root:hex123`)
* Samba passwords via `smbpasswd`
* FTP and Telnet credentials in plaintext

### 3. Logs

* Samba logs: show which accounts accessed which shares
* FTP logs: file listings and connections
* xinetd/Telnet logs: failed or successful logins

### 4. Operational documents

* `data/shares/` contains:

  * network diagrams
  * historical reports
  * operational SOPs
  * legacy configuration snapshots

### 5. MOTD and notes

* `/etc/motd` / internal documentation: IPs, servers, operational quirks
* Provides context for attacker to map network topology quickly

## Role in the simulator

* Initial foothold: any attacker with network access can exploit weak protocols.
* Information discovery point: artefacts give full map of OT and corporate networks.
* Credential harvesting target: offline cracking of LM/NTLM hashes, plaintext FTP/Telnet passwords.
* Pivot potential: used to access private shares or reach engineering workstations.

Attackers typically follow:

```text
legacy workstation compromise
        ↓
discover credentials in smbpasswd / network_inventory.txt
        ↓
access private shares / FTP
        ↓
enumerate engineering and OT hosts
        ↓
pivot to historian or SCADA
```

## Legacy workstation artefacts

Location: `/srv/smb/public` + `/srv/smb/private` + `/opt/legacy/data`

| File / Directory                               | Purpose / Description   | Notes for attacker                                                                                     |
|------------------------------------------------|-------------------------|--------------------------------------------------------------------------------------------------------|
| `/opt/legacy/config/network_inventory.txt`     | Network map             | Shows IP ranges, gateways, workstation hostnames, ideal for recon                                      |
| `/srv/smb/public/*.txt`                        | Public operational docs | SOPs, equipment manuals, general reports; attacker can read, but not write                             |
| `/srv/smb/private/*.conf`                      | Private configs         | Could contain PLC passwords, engineering notes, or internal scripts; accessible only via Administrator |
| `/opt/legacy/data/`                            | Sample data snapshots   | Example SCADA logs, process reports, CSV exports                                                       |
| `/etc/motd`                                    | Operational message     | Gives context: last update, contacts, known quirks of machinery and servers                            |
| `.smbpasswd`                                   | LM / NTLM hashes        | For offline cracking of the Administrator password                                                     |
| `/var/log/ftp.log` / `/var/log/samba/log.smbd` | Access logs             | Show who accessed what and when; demonstrates historical activity                                      |
| `engineering-logbook.txt`                      | Embedded passwords      | Simulates sticky-note style plaintext passwords for PLCs or historian                                  |

Extras to make it feel “1999 real”:

* Random `.bak` files or `.old` configs in `/srv/smb/private`
* Telnet session recordings (mock) or history files under `/opt/legacy`
* Old spreadsheets with sample inventory numbers
* Legacy backups of network diagrams in GIF or BMP format

## 2. Legacy workstation folder tree

```
/opt/legacy/
├── config/
│   └── network_inventory.txt   # IP ranges, gateways, hostnames
├── data/
│   └── shares/
│       ├── procedures.txt     # Sample SOPs
│       ├── manuals.pdf        # Equipment manuals
│       └── logs_sample.csv    # Mock SCADA logs
│   └── engineering-logbook.txt # Sticky-note style passwords
└── smb-private/                # Only accessible to Administrator
    ├── plc-access.conf         # Realistic legacy credentials
    ├── old-backup.bak
    └── scripts/
        └── update_inventory.sh
```

Example content snippets:

* `network_inventory.txt`

  ```
  Operations Floor: 192.168.1.10-30
  Engineering: 10.0.1.20-25
  Turbine Control: 172.16.3.10-12
  Distribution SCADA: see Sgt Colon
  ```
* `engineering-logbook.txt`

  ```
  Turbine PLC: plc123
  Historian DB: hist1999
  Backup router: admin
  ```

Optional artefacts for realism:

* `.smbpasswd` with LM hashes
* `/var/log/samba/log.smbd` (mocked)
* FTP logs with anonymous access entries
