# Internet zone

`ics_internet` (10.10.0.0/24) is the city-side network. In Purdue model terms it is external, below Level 4, belonging 
to nobody in particular. In Ankh-Morpork terms it is the street outside the gate, which has never been especially safe.

Participants enter here. Everything interesting is deeper.

## What lives here

| Hostname         | IP         | Role                                                                                                         |
|------------------|------------|--------------------------------------------------------------------------------------------------------------|
| unseen-gate      | 10.10.0.5  | Attacker machine. SSH entry point. Internet NIC only.                                                        |
| wizzards-retreat | 10.10.0.10 | Rincewind's home machine. Dual-homed into enterprise via a WireGuard config that has been left lying around. |

`wizzards-retreat` also holds 10.10.1.3 on `ics_enterprise`. Its internet NIC is the only route from here into the rest of the network.

## Firewall position

The internet zone is blocked from reaching enterprise, operational, control, and WAN directly. The exception is 
`wizzards-retreat`: its enterprise NIC is permitted because it simulates an established VPN tunnel, not a fresh 
connection from outside.

Inbound from the internet to the DMZ (`ics_dmz`, 10.10.5.0/24) is open. That is the intended attack surface for the 
Guild Quarter path.

## Getting out of here

Three routes:

1. Compromise `wizzards-retreat` (SSH brute force, HTTP endpoint, or OSINT from `unseen-gate`) and use its enterprise NIC to reach 10.10.1.x.
2. Move into the DMZ (10.10.5.x) and work through the Guild Quarter devices from there.
3. The DMZ SSH bastion (`contractors-gate`, 10.10.5.20) has a second NIC in enterprise. Compromise it and the enterprise zone opens.

The firewall does not block `unseen-gate` from the DMZ, so both paths are available from the attacker machine.
