# Turbine PLC: HEX-CPU-4000

## Device description

The turbine PLC is the primary controller for the UU P&L Hex Steam Turbine. It
runs the governor loop, monitors process variables, enforces safety interlocks,
and communicates with relays, actuators, and the HMI.

The device is a Hex Computing Division HEX-CPU-4000, firmware 4.1.2. It
presents itself on four protocols simultaneously: Modbus TCP for primary control
access, DNP3 and IEC-104 for SCADA polling, and SNMP for device management.

None of these protocols implement authentication. This is typical of PLCs
deployed before the ICS security standards of the 2010s became widespread,
and remains common in operational environments today.

From an attacker's perspective, this is the most valuable device in the control
zone:

* direct write access to process setpoints and safety interlocks
* no credential requirement on any interface
* physics responds immediately to register writes
* a single coil write can trip the turbine

## Container behaviour

The container exposes four network services:

* Modbus TCP on port 502: primary control interface, no authentication
* DNP3 on port 20000: SCADA polling interface, minimal outstation
* IEC-104 on port 2404: substation automation, responds to standard frames
* SNMP on port 161 (UDP): managed by snmpd with default community strings

The container runs a physics simulation internally. Turbine RPM, temperature,
pressure, oil pressure, and vibration are computed at 10 Hz. The governor loop
adjusts the fuel valve to track the setpoint RPM. Alarms trigger automatically
when physical limits are exceeded; a safety interlock trips the turbine on
overspeed, overtemperature, or overpressure.

At startup, the fuel valve ramps from 0 to 60% over approximately 30 seconds,
bringing the turbine from cold to operating speed.

## Deliberately introduced vulnerabilities

### No authentication on Modbus

Any host that can reach port 502 can read and write all registers. This is not
a misconfiguration. It reflects the design assumptions of Modbus TCP, which was
never designed to operate over untrusted networks.

An attacker with network access can:

* read all process variables
* change the governor setpoint
* write the fuel valve command directly (bypassing the governor)
* activate the emergency stop
* change the overcurrent threshold (affecting relay protection)

### No authentication on DNP3 or IEC-104

Both protocols accept connections and respond to requests without any form of
identity verification. An attacker can use standard tools to enumerate the
outstation and read process data.

### Default SNMP community strings

The snmpd configuration uses the factory-default community strings:

```
public   (read)
private  (read-write)
```

Walking the public community reveals device information. The private community
allows write access to SNMP-managed parameters.

### Emergency stop accessible over the network

Coil 0 is the emergency stop flag. Writing 1 to coil 0 via Modbus immediately
trips the turbine and cuts fuel. This is a design convenience that becomes a
remote attack vector.

### Governor can be fought via direct register writes

The governor loop reads the setpoint from holding register 0 and adjusts the
fuel valve in holding register 1. An attacker writing directly to holding
register 1 will fight the governor, creating unstable oscillation until the
attacker wins or the governor compensates.

## Real-world vulnerabilities / CVEs

| Interface                    | CVE / Reference                  | Notes                                                                                            |
|------------------------------|----------------------------------|--------------------------------------------------------------------------------------------------|
| Modbus TCP (unauthenticated) | ICS-CERT Advisory ICSA-10-090-01 | Modbus has no authentication by design; widely documented                                        |
| Direct coil/register write   | CVE-2015-0987                    | Schneider Modicon: unauthenticated write to process registers                                    |
| Unauthenticated DNP3         | ICS-CERT ICSA-14-084-01          | DNP3 spoofing and replay without SAv5                                                            |
| Default SNMP community       | CVE-2002-0012                    | SNMPv1 public/private community strings; affects essentially all devices using net-snmp defaults |
| Network-accessible E-stop    | CVE-2019-6547                    | GE CIMPLICITY: remote write to safety-critical registers                                         |

## Artefacts attackers should find

### Port scan

```
502/tcp   open  modbus
2404/tcp  open  iec-104
20000/tcp open  dnp3
161/udp   open  snmp
```

No SSH. No HTTP. No shell. Interaction is protocol-only.

### Modbus register enumeration

An attacker reading all registers discovers the full process state and all
writable control points. The register map is consistent with a real Modicon or
Siemens S7 PLC.

### DNP3 Class 0 poll

A Class 0 read returns Group 30 Var 2 analogue inputs: RPM, temperature,
pressure, voltage, frequency. This is the standard SCADA polling response.

### SNMP walk

```
snmpwalk -c public -v1 10.10.3.21
```

Returns system OIDs: device name (HEX-CPU-4000), firmware version, uptime,
interface information. Community string `private` allows writes.

## Modbus register map

### Coils (FC1: read/write, no authentication)

| Address | Name               | Description                                           |
|---------|--------------------|-------------------------------------------------------|
| 0       | emergency_stop     | Write 1 to trip turbine immediately; write 0 to reset |
| 1       | alarm_overspeed    | Set automatically when RPM > 3300                     |
| 2       | alarm_overtemp     | Set automatically when temperature > 490 °C           |
| 3       | alarm_overpressure | Set automatically when pressure > 95 bar              |
| 4       | alarm_undervoltage | Set when feeder voltage < 85% of 230 V nominal        |
| 5       | breaker_a_closed   | Mirrored from actuator_breaker_a (1 = closed)         |
| 6       | breaker_b_closed   | Mirrored from actuator_breaker_b (1 = closed)         |

### Holding Registers (FC3: read/write, no authentication)

| Address | Name                  | Default | Description                                          |
|---------|-----------------------|---------|------------------------------------------------------|
| 0       | governor_setpoint_rpm | 3000    | Target RPM; governor adjusts fuel to reach this      |
| 1       | fuel_valve_command    | 0–100%  | Written by governor loop; can be overridden directly |
| 2       | cooling_pump_speed    | 100%    | Cooling pump speed; affects temperature              |
| 3       | overcurrent_threshold | 200 A   | Shared with relay IEDs for OC protection             |

### Input Registers (FC4: read-only)

| Address | Name                  | Unit | Notes                               |
|---------|-----------------------|------|-------------------------------------|
| 0       | turbine_rpm           | RPM  | Live value from physics loop        |
| 1       | turbine_temperature_c | °C   | Rises with fuel; falls with cooling |
| 2       | turbine_pressure_bar  | bar  | Steam pressure                      |
| 3       | line_voltage_a_v      | V    | Feeder A output voltage             |
| 4       | line_current_a_a      | A    | Feeder A current                    |
| 5       | line_voltage_b_v      | V    | Feeder B output voltage             |
| 6       | line_current_b_a      | A    | Feeder B current                    |
| 7       | frequency_hz_x10      | —    | e.g. 500 = 50.0 Hz                  |
| 8       | power_kw              | kW   | Total output power                  |
| 9       | oil_pressure_bar      | bar  | Lubrication system                  |
| 10      | vibration_mm_s_x10    | —    | e.g. 12 = 1.2 mm/s                  |

## Role in the simulator

The turbine PLC is the primary target of the control zone. Everything else, 
relays, actuators, HMI, meter, exists in relation to it.

Attack paths involving the PLC:

```
network access to 10.10.3.21
        ↓
write coil 0 = 1 (emergency stop)
        → turbine trips immediately

write holding register 0 = 0 (setpoint zero)
        → governor reduces fuel → turbine ramps down

write holding register 1 = 100 (fuel valve max, bypassing governor)
        → RPM climbs past 3300 → overspeed alarm → auto-trip
        → or: hold at 100% if estop coil is also cleared repeatedly

write holding register 3 = 0 (OC threshold zero)
        → relay IEDs receive threshold via their own polling
        → relays immediately detect overcurrent → trip both feeders
```

The PLC also serves as the pivot point for understanding the full process: its
registers reflect the state of the turbine, both feeders, and all actuators.
```
