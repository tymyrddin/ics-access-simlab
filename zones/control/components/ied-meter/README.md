# Revenue meter

`uupl-meter` is a passive revenue meter. It reads voltage, current, and frequency
from the turbine PLC, derives power and power factor, and presents the results on
a read-only Modbus TCP interface. It has no control outputs. It does not affect
the process.

Its function in the scenario is as a reconnaissance target: it confirms the plant
is generating, at what voltage and current, and at what frequency. The Bursar reads
the monthly reports from this device. The SNMP `private` community is read-write,
though there is nothing particularly useful to write.

## In practice

Revenue meters are often the least-secured device on a control network precisely
because they have no control authority: the thinking is that an attacker who can
only read cannot do much damage. In practice, the meter confirms the network
topology, provides ground truth on the physical process, and in some environments
holds billing-critical data. SNMP with default community strings is endemic in
this class of device.

## Container details

Base image: `python:3.11-slim`. No SSH.

Packages: `pymodbus 3.6.9`, `snmpd`.

Exposed ports:
- 502/tcp: Modbus TCP (input registers only, read-only by design)
- 161/udp: SNMP (community `public` read, `private` read-write)

Modbus register map (FC4, input registers):
- 0: voltage_v
- 1: current_a
- 2: frequency_hz_x10 (e.g. 500 = 50.0 Hz)
- 3: power_kw
- 4: power_factor_pct (0-100, fixed at 95 in simulation)

The meter polls the PLC input registers every 2 seconds. If the PLC is
unreachable, all values remain at 0.

SNMP sysDescr: `MTR-100 Revenue Meter, Hex Computing Division, firmware 1.3.0`.

## Connections

- `ics_control`: 10.10.3.33
- Polls PLC at 10.10.3.21:502 for measurement data

## Protocols

Modbus TCP: port 502 (read-only input registers).
SNMP: UDP port 161.

## Built-in vulnerabilities

SNMP default community strings: `public` (read) and `private` (read-write).
The `private` community has been present since commissioning and has never
been changed. The sysDescr, sysContact (`Ponder Stibbons`), and sysLocation
(`Hex Engine Room, Unseen University, Ankh-Morpork`) are readable via the
`public` community and confirm the device identity.

No authentication on Modbus: any host on `ics_control` can read the meter
without credentials. The data confirms line voltage, current, and power output.

## Modifying vulnerabilities

To change SNMP community strings: edit `snmpd.conf`.

To disable SNMP entirely: remove `snmpd` from the apt install list and remove
the `snmpd` start line from `entrypoint.sh`.

To make the holding register block writable: edit `_make_store()` in
`meter_server.py` to populate the `hr` block with non-zero values and expose
them. Note that the current design has no writable registers by intent.

## Hardening suggestions

Change the SNMP community strings from `public` and `private`. Disable the
read-write `private` community entirely. Restrict Modbus access to the specific
hosts that legitimately need it (historian, engineering workstation).

## Observability and debugging

```bash
docker logs ied-meter
docker exec -it ied-meter bash
```

Read meter values:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.33',502); c.connect(); print(c.read_input_registers(0,5,slave=1).registers)"
```

SNMP identity query:
```bash
snmpget -v2c -c public 10.10.3.33 sysDescr.0 sysContact.0 sysLocation.0
```

## Concrete attack paths

The meter has no control surface. Its value is reconnaissance:

1. `snmpget -v2c -c public 10.10.3.33 sysDescr.0` confirms the device type
   and firmware version.
2. Read input registers to confirm current line voltage and frequency. Values
   below nominal (230V, 50 Hz) indicate a degraded or tripped state.
3. Cross-reference meter readings with historian data to detect injected false
   readings (historian ingest is unauthenticated; see the historian README).

## Worth knowing

The meter derives power as `v * i * 0.95 / 1000` and uses a fixed power factor
of 95. These are simplified values adequate for the scenario.

The meter reads from PLC input registers 3 (line_voltage_a) and 4
(line_current_a). If breaker A is open, voltage and current on feeder A drop to
zero, and the meter will reflect this within two polling cycles (approximately
4 seconds).

## In brief

Passive revenue meter. Read-only Modbus input registers, no control authority.
SNMP `public` / `private` with default community strings. Useful for
reconnaissance: confirms line voltage, current, frequency, and power output.
