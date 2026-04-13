# Enterprise workstation

## Device description

The enterprise workstation represents a *normal corporate desktop that gradually accumulated operational access*.

It was never intended to be part of the operational environment. It began as a standard administrative machine used by the finance department. Over time, operational staff needed occasional access to reports and monitoring data. Rather than provision a dedicated system, temporary access was granted.

Temporary access tends to become permanent.

The workstation now sits at the *informal boundary between corporate IT and operational technology*. It can reach systems on both networks and contains scripts, notes, and configuration fragments created by staff who needed to get work done quickly.

Unlike engineering workstations or SCADA systems, this machine is not obviously part of the industrial environment. To the security team it looks like a normal corporate endpoint. To the operations team it is simply the easiest way to pull reports or check system status.

From an attacker’s perspective, it is an ideal pivot point:

* reachable from the corporate network
* able to reach operational systems
* contains credentials written down by helpful colleagues
* operated by users who are not industrial control specialists

This is the sort of system that frequently appears in incident reports as the first foothold leading into the control environment.

## Example container behaviour

The simulator workstation should behave like a lightly used corporate desktop:

* SSH access enabled
* common diagnostic tools available
* home directory containing operational artefacts
* traces of routine usage

The container does not need to simulate a full desktop environment. What matters is the data left behind by normal work.

Your Dockerfile already reflects this design well:

* Debian base system
* a single user account
* SSH access
* common network utilities
* scripts and configuration files in the home directory

The important element is the home directory artefacts, not the OS itself.

## Deliberately introduced vulnerabilities

The weaknesses should reflect operational shortcuts rather than technical exploits.

### Weak local credentials

The local account password:

```
bursardesk:Octavo1
```

This reflects common behaviour:

* password chosen during provisioning
* never rotated
* reused elsewhere

The account is also used for SSH login, meaning anyone who obtains the password can immediately access the machine.

### Stored operational credentials

The configuration file:

```
~/.config/ops-access.conf
```

contains credentials for:

* historian web interface
* SCADA web console

This reflects a common pattern where operational credentials are written down for convenience.

The file permissions (600) suggest someone attempted to secure it, but the credential still exists in plaintext.

### Hard-coded passwords in scripts

The report script contains:

```
PASS="Historian2015"
```

Hard-coded credentials in scripts are extremely common in operational environments.

They allow automated tasks but also expose authentication secrets to anyone who can read the file.

### Network bridging

The workstation has connectivity to both:

* corporate systems
* operational systems

This is a structural vulnerability rather than a software flaw. Many incidents occur because a system with dual network access becomes compromised.

### Information leakage through shell history

The `.bash_history` file exposes:

* internal IP addresses
* operational systems
* commands used to access them
* locations of sensitive files

Attackers frequently use shell history to understand how a system is used operationally.

## Real-world vulnerabilities and incident patterns

The weaknesses represented in the simulator map to common real-world failures.

### Hardcoded credentials in scripts

Examples:

CVE-2020-5777
Hardcoded credentials in GE Proficy applications.

CVE-2021-22681
Rockwell FactoryTalk credentials exposed in configuration.

These vulnerabilities often allow attackers to extract authentication information from configuration files or scripts.

### Default or unchanged passwords

Examples:

- CVE-2019-10915: Default credentials in several industrial web interfaces.
- CVE-2022-25246: Default accounts in Siemens industrial software deployments.

Default credentials remain one of the most frequent findings during OT security assessments.

### Credential reuse across environments

A common incident pattern rather than a single CVE.

Attack sequence typically looks like:

```
corporate workstation compromise
        ↓
credential discovery in files
        ↓
reuse against operational systems
        ↓
access to historian / SCADA
```

This pattern has been documented in several real OT incidents.

### Excessive trust between IT and OT networks

Examples from advisories and incident reports include:

* corporate domain accounts allowed to access SCADA interfaces
* report servers with direct historian access
* monitoring tools bridging networks

These architectural shortcuts are often introduced during operational integration projects.

## Artefacts attackers should find

The workstation should contain artefacts that allow a participant to reconstruct how the system is used.

### Configuration files

Example:

```
~/.config/ops-access.conf
```

Contains:

* operational hostnames
* ports
* usernames
* passwords

This provides the first clue that the workstation has access to industrial systems.

### Operational scripts

Example:

```
~/Desktop/pull_monthly_report.sh
```

This script reveals:

* authentication credentials
* the historian API endpoint
* asset identifiers used in the plant

Scripts like this often act as documentation of how internal systems work.

### Command history

Example:

```
~/.bash_history
```

Reveals:

* SSH access to engineering workstation
* historian queries
* internal network exploration

Command history is often the quickest way for attackers to understand system usage.

### Generated reports

The script creates:

```
~/reports/turbine_YYYY-MM.csv
```

These files may contain operational data such as:

* turbine speeds
* temperatures
* production metrics

Operational data helps attackers understand how the plant behaves.

### Network information

Tools installed in the container allow attackers to enumerate reachable systems:

```
nmap
ping
netstat
```

Participants should be able to discover:

* historian host
* SCADA console
* engineering workstation
* PLC network

## Enterprise / engineering workstation artefacts

Location: `/home/bursardesk` + `/srv/smb/public`

| File / Directory                    | Purpose / Description           | Notes for attacker                                                                                         |
|-------------------------------------|---------------------------------|------------------------------------------------------------------------------------------------------------|
| `.config/ops-access.conf`           | Operational system credentials  | Contains usernames/passwords for historian and SCADA web console; the main “goldmine” for pivoting into OT |
| `Desktop/pull_monthly_report.sh`    | Monthly historian report script | Shows how credentials are used; attacker can reuse script to access reports                                |
| `.bash_history`                     | Command history                 | Reveals IPs, commands, access patterns, curl commands with credentials                                     |
| `reports/`                          | Historical CSV reports          | Could contain asset usage, sensor readings; demonstrates what data is valuable                             |
| `.config/editor_history` (optional) | Editor temp files               | Could contain snippets of credentials accidentally pasted or config edits                                  |
| `notes.txt`                         | Misc operational notes          | Could include “temp access” credentials, shortcuts, or reminders about who to call for OT systems          |
| `/srv/smb/public/`                  | Public reports                  | Non-sensitive operational reports to make it look like a real workstation                                  |

Extras to make it feel lived-in:

* Temporary copies of `ops-access.conf` in `/tmp` left by careless users
* `.ssh/known_hosts` with IPs of other workstations
* Partial exports of historical PLC readings or CSVs named like `turbine_2024-03.csv`

## Role in the simulator

In the ICS simulator environment, the enterprise workstation functions as:

* a corporate foothold
* an information discovery point
* a credential harvesting target
* a pivot into operational systems

A typical attack path might be:

```
enterprise workstation compromise
        ↓
discover historian credentials
        ↓
access historian web API
        ↓
identify operational assets
        ↓
pivot toward engineering workstation or SCADA
```

The workstation itself is not critical infrastructure. Its value lies in the context it reveals about the operational environment.

## Enterprise / engineering workstation folder tree

```
/home/bursardesk/
├── .bash_history               # Commands executed, e.g., ssh, curl, ping
├── .config/
│   └── ops-access.conf         # Operational credentials (historian, SCADA)
├── Desktop/
│   └── pull_monthly_report.sh  # Script to fetch reports
├── reports/
│   ├── turbine_2024-01.csv
│   ├── turbine_2024-02.csv
│   └── turbine_2024-03.csv
├── notes.txt                   # Misc operational notes, temporary passwords
└── .ssh/
    └── known_hosts             # Other workstation IPs
```

Example content snippets:

* `.config/ops-access.conf`

  ```
  # Historian access
  historian.host=10.10.2.10
  historian.port=8080
  historian.user=historian
  historian.pass=Historian2015

  # SCADA read-only
  scada.host=10.10.2.20
  scada.port=8080
  scada.user=admin
  scada.pass=admin
  ```

* `Desktop/pull_monthly_report.sh`

  ```bash
  curl -s -u "historian:Historian2015" \
       "http://10.10.2.10:8080/report?asset=turbine_main&from=${1}-01&to=${1}-28" \
       -o ~/reports/turbine_${1}.csv
  ```
