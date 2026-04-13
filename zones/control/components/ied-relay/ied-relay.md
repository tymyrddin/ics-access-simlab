# Protective Relay IED: REL-200A / REL-200B

## Device description

The REL-200 series protective relay IEDs monitor the output feeders of the
UU P&L Hex Turbine and automatically trip the associated breaker when
electrical or mechanical faults are detected. Two units are deployed:

* REL-200A (10.10.3.31): monitors Feeder A, Dolly Sisters substation
* REL-200B (10.10.3.32): monitors Feeder B, Nap Hill substation

Each relay polls the PLC for line voltage, current, and turbine RPM every
500 ms. When a measurement exceeds a protection threshold, the relay trips its
associated breaker actuator and logs the event. After 10 seconds it attempts
to reclose. If the fault persists, it trips again and stops reclosing.

The relays also expose a web interface for configuration and manual operation,
and a Modbus server that allows direct threshold adjustment.

From an attacker's perspective, the relay IEDs are manipulation targets, not
pivot points:

* lowering protection thresholds via Modbus causes spurious trips at normal conditions
* forcing a trip via the web interface or Modbus coil takes a feeder offline
* raising thresholds disables protection, allowing damaging conditions to persist

## Container behaviour

Each container exposes three network services:

* Modbus TCP on port 502: relay state and writable protection thresholds
* HTTP on port 8081: web interface, default credentials admin/relay1234
* SNMP on port 161 (UDP): snmpd with default community strings

The relay logic runs continuously:

1. Poll PLC input registers (voltage, current, RPM, frequency)
2. Compare against local threshold registers
3. If any threshold is exceeded: log event, set trip coil, write breaker actuator
4. After RECLOSE_DELAY (10 s): attempt reclose, re-check, re-trip if fault persists

The web interface displays current measurements, relay status, protection
settings (when authenticated), and the last 10 trip events.

## Deliberately introduced vulnerabilities

### Default web credentials

```
admin : relay1234
```

These are the factory defaults for the REL-200 series. Changing them requires
web UI access, which most operators do not do during commissioning. The password
is not rate-limited.

### Writable protection thresholds via Modbus (no authentication)

The three holding registers controlling protection thresholds are writable by
any host with Modbus access:

| Register                         | Default  | Effect of manipulation                          |
|----------------------------------|----------|-------------------------------------------------|
| `HR[0]` undervoltage_threshold_v | 196 V    | Raise to 230 V → relay trips at nominal voltage |
| `HR[1]` overcurrent_threshold_a  | 200 A    | Lower to 1 A → relay trips on any current       |
| `HR[2]` overspeed_threshold_rpm  | 3300 RPM | Lower to 0 → relay trips immediately            |

Setting any threshold to a value that the running turbine already exceeds causes
an immediate trip. Setting thresholds to extreme values (e.g. 0 V undervoltage)
disables that protection entirely.

### Modbus coil 0 is the force-trip vector

Writing coil 0 = 1 via Modbus activates the relay trip status flag. The relay
logic treats this as a tripped state and sends a trip command to the breaker
actuator. No authentication required.

### Auto-reclose creates a race condition

After a trip, the relay reclosing logic runs at a 10-second interval. An
attacker who continuously writes coil 0 = 1 can prevent the relay from
reclosing, keeping the feeder offline indefinitely.

### Trip log reveals protection events

The web interface trip log (last 50 events, last 10 displayed) records cause,
voltage, current, and RPM at the time of each trip. This reveals attacker
actions and historical fault patterns. The log also confirms whether previous
manipulation attempts worked.

## Real-world vulnerabilities / CVEs

| Component                                  | CVE / Reference                  | Notes                                                         |
|--------------------------------------------|----------------------------------|---------------------------------------------------------------|
| Default relay credentials                  | CVE-2015-6574                    | SEL relay default passwords                                   |
| Unauthenticated Modbus threshold write     | CVE-2022-3084                    | GE Reason RT430: unauthenticated write to protection settings |
| Force trip via Modbus coil                 | ICS-CERT ICSA-19-099-05          | ABB relay: remote trip via unauthenticated Modbus write       |
| No Modbus application-layer authentication | ICS-CERT Advisory ICSA-10-090-01 | Modbus design limitation                                      |
| SNMP default community strings             | CVE-2002-0012                    | Standard net-snmp default community strings                   |

## Artefacts attackers should find

### Port scan (either relay)

```
502/tcp  open  modbus
8081/tcp open  http    (REL-200A Relay Web Interface)
161/udp  open  snmp
```

No SSH. No shell access.

### Web interface

Visiting `http://10.10.3.31:8081/` shows without login:

* relay ID and feeder name (Dolly Sisters / Nap Hill)
* current relay status (normal / tripped)
* live measurements: voltage, current, RPM, frequency
* trip log (last 10 events, even without authentication)
* login form with username field

The measurements confirm the relay is reading from the PLC. The trip log
confirms whether the relay has operated previously.

After login (admin / relay1234), the configuration panel appears:

* current protection threshold values
* form to change undervoltage, overcurrent, and overspeed thresholds
* force-trip button

### Modbus register enumeration

Reading input registers reveals live measurements mirrored from the PLC.
Reading holding registers reveals the current protection thresholds.
Coil 0 shows whether the relay is currently tripped.

All of these are readable and writable without credentials.

## Modbus register map

### Holding Registers (FC3: read/write, no authentication)

| Address | Name                     | Default  | Attack vector                           |
|---------|--------------------------|----------|-----------------------------------------|
| 0       | undervoltage_threshold_v | 196 V    | Raise → spurious trip at normal voltage |
| 1       | overcurrent_threshold_a  | 200 A    | Lower → spurious trip on normal current |
| 2       | overspeed_threshold_rpm  | 3300 RPM | Lower → trip immediately                |

### Input Registers (FC4: read-only)

| Address | Name             | Source                           |
|---------|------------------|----------------------------------|
| 0       | line_voltage_v   | Mirrored from PLC input register |
| 1       | line_current_a   | Mirrored from PLC input register |
| 2       | frequency_hz_x10 | Mirrored from PLC input register |
| 3       | turbine_rpm      | Mirrored from PLC input register |

### Coils (FC1: read/write, no authentication)

| Address | Name              | Description                        |
|---------|-------------------|------------------------------------|
| 0       | relay_trip_status | 1 = tripped; write 1 to force trip |

## Role in the simulator

The relay IEDs are intermediate manipulation targets. They sit between the PLC
and the breaker actuators. An attacker with Modbus access to the relay can
affect the power distribution without touching the PLC at all.

```
attacker writes relay HR[0] = 230 (undervoltage threshold = nominal voltage)
        ↓
relay poll detects voltage < threshold
        ↓
relay sets coil[0] = 1, sends trip command to actuator_breaker_a/b
        ↓
breaker opens → feeder A or B offline → generator loses load
        ↓
PLC physics responds: RPM climbs (reduced drag) → overspeed alarm
        ↓
PLC auto-trips on overspeed → full turbine trip
```

Or more directly:

```
attacker writes relay coil[0] = 1 (force trip)
        ↓
relay sends trip to breaker → feeder offline
```

The relays also provide a second path to the breaker actuators: the web
interface force-trip button, accessible after login with default credentials,
triggers the same breaker trip command as the Modbus coil write.
