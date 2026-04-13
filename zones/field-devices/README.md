# Field devices

Placeholder zone. No containers are deployed here yet.

The intention is to extend the simulation with additional field-level devices: smart meters, RTUs, protection relays, 
and similar hardware that in real deployments communicates over WAN links (cellular, private APN, or leased line) 
rather than LAN. The WAN network (`ics_wan`, 10.10.4.0/24) already exists in the topology for this purpose.

When populated, devices here would be reachable from the operational zone over Modbus and SNMP, and unreachable from 
enterprise and internet directly.
