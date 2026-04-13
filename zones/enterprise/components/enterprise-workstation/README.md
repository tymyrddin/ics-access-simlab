# Enterprise workstation

`bursar-desk` was originally provisioned for the finance department. At some point it was given access to operational 
systems for a temporary data pull that became permanent. Nobody revoked the access because the monthly reports kept 
working. The result is a corporate workstation with a user profile full of credentials, scripts with hard-coded 
passwords, and a PowerShell history that reads like a guided tour of the operational network.

## Real-world context

An IT/OT boundary machine: a corporate workstation that, through a series of entirely reasonable individual decisions, 
accumulated read access to operational systems. The dual-homed configuration (enterprise and operational networks) 
reflects the common pattern of machines that were temporarily given operational access and never had it removed. The 
vulnerabilities are not in the software; they are in what was left in the profile.

## Container details

Base image: `debian:bookworm-slim` with a Windows 10 login shell (`win10shell.sh`). Profile root at `/opt/win10/C/Users/bursardesk/`. SSH on port 22.

User: `bursardesk`, password `Octavo1`. Root login disabled.

The virtual profile contains:
- `AppData\Roaming\UUPLOps\ops-access.conf`: historian and SCADA credentials
- `Desktop\pull_monthly_report.ps1`: PowerShell script with hard-coded historian credentials
- `AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt`: command history including SSH to engineering workstation
- `Documents\notes.txt`: operational notes
- `reports\turbine_2024-0*.csv`: pre-generated turbine reports
- `.ssh\known_hosts`: historian, SCADA, and engineering workstation fingerprints
- `/tmp/ops-access.conf.bak`: a copy left outside the profile by someone who needed it quickly

## Connections

- `ics_enterprise`: 10.10.1.20
- `ics_operational`: 10.10.2.100 (the IT/OT boundary NIC)
- Reachable from `wizzards-retreat` and `hex-legacy-1` on enterprise, and from the operational segment directly

## Protocols

SSH: port 22.

## Built-in vulnerabilities

Credential exposure: `ops-access.conf` contains historian credentials (`historian`/`Historian2015`) and SCADA 
credentials (`admin`/`admin`). The PowerShell script on the Desktop contains the same historian credentials in 
plaintext. `/tmp/ops-access.conf.bak` is world-readable.

PowerShell history: includes the exact `Invoke-WebRequest` command with a Base64-encoded Basic auth header, which 
decodes to `historian:Historian2015`.

SSH known_hosts: confirms historian, SCADA, and engineering workstation are all reachable and have been connected 
to from this machine.

The dual-homed operational NIC (10.10.2.100) means a shell on this machine provides direct access to the operational 
network without needing to pivot through the engineering workstation.

## Modifying vulnerabilities

To change the password: edit the `chpasswd` line in the Dockerfile.

To change the credentials in the profile: edit the heredoc blocks in `entrypoint.sh` that write `ops-access.conf` and `pull_monthly_report.ps1`.

To remove the world-readable backup: delete the `cp` and `chmod` lines near the end of `entrypoint.sh`.

To change which networks the machine is on: edit `ctf-config.yaml` under `enterprise_workstation`.

## Hardening suggestions

Remove the plaintext credential files, or at minimum ensure they are not world-readable. Rotate credentials after 
any staff change. Replace hard-coded credentials in scripts with a secrets manager or environment-variable injection. 
Consider whether a finance department workstation genuinely needs a persistent network route to the operational 
historian.

## Observability and debugging

```bash
docker logs enterprise-workstation
docker exec -it enterprise-workstation bash
ssh bursardesk@10.10.1.20    # password: Octavo1
```

Inside, the virtual C: drive is at `/opt/win10/C/`. The win10shell presents a PowerShell-style prompt. Real SSH and 
curl commands work normally.

## Concrete attack paths

From anywhere on enterprise (e.g. `wizzards-retreat` at 10.10.1.3):

1. `ssh bursardesk@10.10.1.20`, password `Octavo1`
2. `type AppData\Roaming\UUPLOps\ops-access.conf` exposes historian and SCADA credentials
3. `curl -u historian:Historian2015 http://10.10.2.10:8080/report?asset=turbine_main&from=2024-01-01&to=2024-12-31`
4. From the operational NIC (10.10.2.100), reach historian and SCADA directly without going through the enterprise firewall rules

Alternative: read the PowerShell history, decode the Base64 auth header, arrive at the same credentials with less typing.

## Worth knowing

The win10shell is cosmetic: it presents a PowerShell-style prompt and provides an `ls`/`dir`, `cat`/`type`, and `cd` 
approximation, but it is a thin Bash wrapper. Real Linux commands work if called directly.

The `/tmp/ops-access.conf.bak` file is on the Linux filesystem, not in the virtual Windows profile. It is accessible 
from a real shell (`docker exec`) or from a Linux-aware participant who drops out of the win10shell.

The operational NIC (10.10.2.100) gives direct access to `ics_operational`. Combined with the credentials in the 
profile, this machine is a complete pivot to the operational zone without touching the engineering workstation.

## The short version

Finance workstation, dual-homed into operational. Historian and SCADA credentials hard-coded into a PowerShell script and a config file, both in the user profile. The PowerShell history contains a ready-to-run historian query. Dual-homed NIC provides direct operational network access.
