# Enterprise workstation

## Device description

The enterprise workstation represents a *normal corporate desktop that gradually accumulated operational access*.

It was never intended to be part of the operational environment. It began as a standard administrative machine used by
the finance department. Over time, operational staff needed occasional access to reports and monitoring data. Rather
than provision a dedicated system, temporary access was granted.

Temporary access tends to become permanent.

The workstation now sits at the *informal boundary between corporate IT and operational technology*. It can reach
systems on both networks and contains scripts, notes, and configuration fragments created by staff who needed to get
work done quickly.

Unlike engineering workstations or SCADA systems, this machine is not obviously part of the industrial environment. To
the security team it looks like a normal corporate endpoint. To the operations team it is simply the easiest way to pull
reports or check system status.

From an attacker’s perspective, it is an ideal pivot point:

* reachable from the corporate network
* able to reach operational systems
* contains credentials written down by helpful colleagues
* operated by users who are not industrial control specialists

This is the sort of system that frequently appears in incident reports as the first foothold leading into the control
environment.

## Example container behaviour

The simulator workstation behaves like a lightly used corporate desktop:

* SSH access enabled
* common diagnostic tools available
* user profile containing operational artefacts
* traces of routine usage

The container does not need to simulate a full desktop environment. What matters is the data left behind by normal work.

 * Windows 10 enterprise facade, UUPL domain-joined
 * single user account (bursardesk, local admin)
 * SSH access
 * common Windows network utilities
 * scripts and configuration files in the user profile

The important element is the user profile artefacts.

## Deliberately introduced vulnerabilities

The weaknesses reflect operational shortcuts rather than technical exploits.

### Weak local credentials

The local account password `bursardesk:Octavo1` reflects common behaviour:

* password chosen during provisioning
* never rotated
* reused elsewhere

The account is also used for SSH login, meaning anyone who obtains the password can immediately access the machine.

### Stored operational credentials

The configuration file `AppData\Roaming\UUPLOps\ops-access.conf` contains credentials for the uupl-historian web 
interface and the SCADA web console.

This reflects a common pattern where operational credentials are written down for convenience.

The file permissions (600) suggest someone attempted to secure it, but the credential still exists in plaintext.

### Hard-coded passwords in scripts

The PowerShell report script contains `$Pass = "Historian2015"`. Hard-coded credentials in scripts are extremely common 
in operational environments. They allow automated tasks but also expose authentication secrets to anyone who can read 
the file.

### Network bridging

The workstation has connectivity to both:

* corporate systems
* operational systems

This is a structural vulnerability rather than a software flaw. Many incidents occur because a system with dual network
access becomes compromised.

### Information leakage through Powershell history

The PowerShell history file (`AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt`) exposes:

* internal IP addresses
* operational systems
* Invoke-WebRequest calls with embedded Base64 credentials
* locations of sensitive files

Attackers frequently use command history to understand how a system is used operationally.

## Real-world vulnerabilities and incident patterns

The weaknesses represented in the simulator map to common real-world failures.

### Most common

* Hardcoded credentials in applications and credentials exposed in configuration are still fairly common. These vulnerabilities often allow attackers to extract authentication information from configuration files or scripts.
* Default credentials remain one of the most frequent findings during OT security assessments.
* Credential reuse across environments are a common incident pattern.

Attack sequence typically looks like:

```
corporate workstation compromise
        ↓
credential discovery in files
        ↓
reuse against operational systems
        ↓
access to uupl-historian / SCADA
```

This pattern has been documented in several real OT incidents.

### Excessive trust between IT and OT networks

Examples from advisories and incident reports include:

* corporate domain accounts allowed to access SCADA interfaces
* report servers with direct uupl-historian access
* monitoring tools bridging networks

These architectural shortcuts are often introduced during operational integration projects.

## Artefacts

The workstation contains artefacts that allow a participant to reconstruct how the system is used.

### Configuration files

For example, the `AppData\Roaming\UUPLOps\ops-access.conf` contains:

* operational hostnames
* ports
* usernames
* passwords

Providing a first clue that the workstation has access to industrial systems.

### Operational scripts

For example, the `Desktop\pull_monthly_report.ps1` script reveals:

* authentication credentials
* the uupl-historian API endpoint
* asset identifiers used in the plant

Scripts like this often act as documentation of how internal systems work.

### Command history

To demonstrate, `AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` reveals:

 * SSH access to the engineering workstation
 * Invoke-WebRequest calls to the historian (Base64 credentials visible)
 * internal network exploration

Command history is often the quickest way for attackers to understand system usage.

### Generated reports

The script creates `reports\turbine_YYYY-MM.csv`. These files may contain operational data such as:

* turbine speeds
* temperatures
* production metrics

Operational data helps attackers understand how the plant behaves.

### Network information

Tools installed in the container allow attackers to enumerate reachable systems: `nmap`, `ping` and `netstat`, with 
which participants can discover the:

* uupl-historian host (10.10.2.10)
* SCADA console (10.10.2.20)
* engineering workstation (10.10.2.30)

## Enterprise / engineering workstation artefacts

Location: `C:\Users\bursardesk\`

| File / Directory                                                                  | Purpose / Description           | Notes for attacker                                                               |
|-----------------------------------------------------------------------------------|---------------------------------|----------------------------------------------------------------------------------|
| `AppData\Roaming\UUPLOps\ops-access.conf`                                         | Operational system credentials  | historian + SCADA credentials; the main goldmine for pivoting into OT            |
| `C:\Temp\ops-access.conf.bak`                                                     | Careless copy outside profile   | World-readable; same content as ops-access.conf                                  |
| `Desktop\pull_monthly_report.ps1`                                                 | Monthly historian report script | Hard-coded `$Pass = “Historian2015”`; reveals API endpoint and asset name        |
| `AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` | PowerShell history              | IWR calls with Base64 credentials, SSH to eng-ws, nmap of 10.10.2.0/24           |
| `reports\`                                                                        | Historical CSV reports          | turbine_2024-01 through 2024-03; rpm, temperature, pressure, electrical readings |
| `Documents\notes.txt`                                                             | Misc operational notes          | References ops-access.conf and the monthly report script; SSH to 10.10.2.30      |
| `.ssh\known_hosts`                                                                | SSH known hosts                 | Keys for 10.10.2.10, .20, .30; confirms prior connections                        |

Extras that make it feel lived-in:

* `C:\Temp\ops-access.conf.bak`: a careless copy of ops-access.conf, world-readable
* `.ssh\known_hosts` populated at startup with keys for historian, SCADA, and eng-ws
* `reports\turbine_2024-01.csv` through `turbine_2024-03.csv` from the monthly script

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
discover uupl-historian credentials
        ↓
access uupl-historian web API
        ↓
identify operational assets
        ↓
pivot toward engineering workstation or SCADA
```

The workstation itself is not critical infrastructure. Its value lies in the context it reveals about the operational
environment.

## Enterprise workstation folder tree

```
C:\
├── Temp\
│   └── ops-access.conf.bak         # careless copy, world-readable
└── Users\bursardesk\
    ├── AppData\
    │   └── Roaming\
    │       ├── Microsoft\Windows\PowerShell\PSReadLine\
    │       │   └── ConsoleHost_history.txt
    │       └── UUPLOps\
    │           └── ops-access.conf
    ├── Desktop\
    │   └── pull_monthly_report.ps1
    ├── Documents\
    │   └── notes.txt
    ├── reports\
    │   ├── turbine_2024-01.csv
    │   ├── turbine_2024-02.csv
    │   └── turbine_2024-03.csv
    └── .ssh\
        └── known_hosts
```

