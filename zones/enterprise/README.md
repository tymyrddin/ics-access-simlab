# Enterprise zone

`ics_enterprise` (10.10.1.0/24) is the corporate IT network. Purdue Level 4. In a real utility this would be the floor that handles billing, HR, procurement, and the kind of email threads that cause security incidents. UU P&L is no exception.

The zone is not directly reachable from the internet. Attackers arrive either through `wizzards-retreat`'s second NIC or via the DMZ SSH bastion.

## What lives here

| Hostname         | IP         | Role                                                                                                                     |
|------------------|------------|--------------------------------------------------------------------------------------------------------------------------|
| wizzards-retreat | 10.10.1.3  | Second NIC. The internet-side entry is 10.10.0.10.                                                                       |
| hex-legacy-1     | 10.10.1.10 | Legacy workstation. Windows XP era. Alive out of inertia and a deferred upgrade budget.                                  |
| bursar-desk      | 10.10.1.20 | Enterprise workstation. Also on operational as 10.10.2.100. The Bursar has more access than anyone has audited in years. |

## Firewall position

Enterprise can reach:
- Historian web UI (10.10.2.10:8080)
- Operations SCADA web UI (10.10.2.20:8080)
- Engineering workstation SSH (10.10.2.30:22)

Enterprise cannot reach the control zone, the WAN, or the internet directly.

## In the CTF

The enterprise zone is a credential and key depot. `hex-legacy-1` has accumulated configuration files and old credentials from years of being the only machine anyone could log into quickly. `bursar-desk` has a second NIC in operational (10.10.2.100), giving it direct access to devices that enterprise machines normally only see through the firewall pinhole.

Compromise `bursar-desk` and the operational zone opens considerably wider than the firewall rules suggest.
