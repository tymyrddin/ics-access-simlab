# Control zone

`ics_control` (10.10.3.0/24) is the area supervisory and field device network. Purdue Levels 1 and 2. This is the zone 
where commands become physical consequences. Writing a Modbus register here does not update a dashboard; it moves a 
valve, opens a breaker, or changes a setpoint the turbine governor is actively reading.

## What lives here

| Hostname          | IP         | Role                                                                                                                                                     |
|-------------------|------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| uupl-hmi          | 10.10.3.10 | Control Scada-LTS (Mango Automation base). Operators issue commands from here. Modbus data source via stunnel gateway. Default credentials: admin/admin. |
| hmi-main-db       | 10.10.3.11 | MySQL sidecar for the control Scada-LTS instance.                                                                                                        |
| uupl-modbus-gw    | 10.10.3.50 | Stunnel TLS gateway, control NIC. Also on operational as 10.10.2.50. Forwards port 8502 to the PLC at 502.                                               |
| hex-turbine-plc   | 10.10.3.21 | Turbine PLC. Modbus :502, DNP3 :20000, IEC-104 :2404, SNMP :161. No authentication on any of these. Publishes telemetry to the MQTT broker.              |
| uupl-relay-a      | 10.10.3.31 | Protective relay IED, Dolly Sisters feeder. Modbus :502, web UI admin/relay1234. Undervoltage, overcurrent, and overspeed thresholds all writable.       |
| uupl-relay-b      | 10.10.3.32 | Protective relay IED, Nap Hill feeder. Same configuration as relay-a.                                                                                    |
| uupl-meter        | 10.10.3.33 | Revenue meter. Modbus read-only (FC4). Polls the PLC every 2 seconds.                                                                                    |
| uupl-fuel-valve   | 10.10.3.51 | Modbus actuator (pymodbus-sim). HOLDING_REGISTERS[0]: valve position 0-100%.                                                                             |
| uupl-cooling-pump | 10.10.3.52 | Modbus actuator (pymodbus-sim). HOLDING_REGISTERS[0]: pump speed 0-100%.                                                                                 |
| uupl-breaker-a    | 10.10.3.53 | Modbus actuator (pymodbus-sim). COILS: state/trip/close for the Dolly Sisters feeder.                                                                    |
| uupl-breaker-b    | 10.10.3.54 | Modbus actuator (pymodbus-sim). COILS: state/trip/close for the Nap Hill feeder.                                                                         |
| uupl-mqtt         | 10.10.3.60 | Mosquitto broker. Port 1883, allow_anonymous true. Receives turbine telemetry and relay trip events.                                                     |

## Firewall position

The control zone accepts inbound Modbus (:502) from the engineering workstation (10.10.3.100, which is `uupl-eng-ws`'s 
second NIC) only. All other traffic from operational is dropped. The DMZ, enterprise, internet, and WAN have no path 
into this zone.

The control zone does not initiate outbound connections. The stunnel gateway handles the one exception: mTLS from the 
operational zone to the control-zone PLC, but that is a dual-homed container rather than a routed connection.

## Physical consequences

Everything in the control zone is wired into a simulated turbine process. The PLC runs a governor loop; the relay IEDs 
monitor voltage and current; the actuators hold register values the PLC reads on its own cycle.

Trips both feeder breakers and the distribution network loses supply. Close the fuel valve and the turbine coasts down. 
Disable the cooling pump and temperature climbs toward the overtemperature trip threshold. Raise the PLC SNMP community 
from `public` to `private` and write the governor setpoint, and the turbine overspeeds.

The relay IED reclose logic will attempt to restore a tripped breaker after 10 seconds. A repeated trip before the 
reclose completes leaves the breaker latched open until someone closes it manually, which in the simulator means an 
API call.
