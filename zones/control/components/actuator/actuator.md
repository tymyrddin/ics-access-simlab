# Actuator containers

## Device description

Four actuator containers serve the UU P&L Hex Turbine control zone. Each
implements a different physical device type but shares the same container image,
parameterised by environment variables:

| Container             | IP         | Type    | Function                          |
|-----------------------|------------|---------|-----------------------------------|
| actuator_fuel_valve   | 10.10.3.51 | valve   | Controls fuel supply to turbine   |
| actuator_cooling_pump | 10.10.3.52 | pump    | Controls cooling water flow       |
| actuator_breaker_a    | 10.10.3.53 | breaker | Controls Feeder A circuit breaker |
| actuator_breaker_b    | 10.10.3.54 | breaker | Controls Feeder B circuit breaker |

In normal operation, the PLC writes to these containers continuously: the
governor loop writes the fuel valve position, and the breaker actuators are
read by the PLC to mirror breaker state into its own coils.

The relay IEDs also write to the breaker actuators when they detect fault
conditions, operating the breakers independently of the PLC.

From an attacker's perspective, the actuators are the closest thing to a
physical effect. Writing to a breaker actuator opens or closes a circuit breaker.
Writing to the fuel valve changes fuel flow. No authentication is required.
The actuators do not validate who is writing to them.

## Container behaviour

Each container exposes one network service:

* Modbus TCP on port 502, register map varies by actuator type (see below)

No HTTP interface. No SSH. No SNMP.

A sync loop runs internally at 10 Hz, keeping echo-back input registers consistent
with the writable registers and coils. For breakers, the loop also processes
trip and close command coils.

Breaker actuators start in the closed state (coil 0 = 1, input register 0 = 1).
Fuel valve starts at position 0 (closed). Cooling pump starts at 100% speed.

## Deliberately introduced vulnerabilities

### No authentication on any interface

Any host with TCP access to port 502 can read and write all registers. There
is no concept of authorised writers. The PLC, the relay IEDs, and an attacker
all appear identical from the actuator's perspective.

This reflects a real design pattern: actuators in legacy ICS deployments are
typically on isolated networks and assumed to be reachable only by trusted
controllers. The isolation is the security control. When an attacker reaches
the control network, that assumption collapses.

### Breaker trip/close commands bypass the PLC control loop

The breaker actuators implement trip and close as separate command coils:

* write coil 1 = 1 → breaker opens (trip command)
* write coil 2 = 1 → breaker closes (close command)

These coils are processed directly by the actuator's sync loop. They do not
pass through the PLC. An attacker can open a breaker without touching the PLC
at all, without triggering PLC alarms, and without the relay IEDs being
involved.

The PLC does poll the breaker actuators and updates its own breaker state coils,
so the PLC will eventually reflect the changed state, but the trip itself
happens immediately, before the PLC polls.

### Fuel valve position directly writable

Writing to holding register 0 of the fuel valve actuator changes the fuel supply
to the turbine. The PLC governor loop also writes this register continuously.
An attacker writing to it will fight the governor: the attacker sets a value,
the governor corrects it on the next cycle (every 200 ms).

Setting the fuel valve to 0 while simultaneously writing 0 to the PLC governor
setpoint defeats both. The turbine will lose fuel and ramp down.

Setting the fuel valve to 100 while the governor setpoint is 3000 RPM causes
the governor to fight against the forced 100% fuel setting, potentially driving
RPM to the overspeed threshold.

### Cooling pump speed directly writable

Writing to holding register 0 of the cooling pump reduces or eliminates cooling.
Combined with high fuel input, reduced cooling causes the temperature to rise
toward the overspeed/overtemp trip threshold.

## Real-world vulnerabilities / CVEs

| Component                              | CVE / Reference         | Notes                                                                    |
|----------------------------------------|-------------------------|--------------------------------------------------------------------------|
| Unauthenticated actuator write         | CVE-2015-0987           | Schneider Modicon: unauthenticated coil write affecting physical output  |
| Direct breaker control via Modbus      | ICS-CERT ICSA-19-099-05 | ABB relay/actuator: remote state change without authentication           |
| Fuel valve override bypassing governor | CVE-2022-3084           | GE Reason RT430: write to control register bypassing safety logic        |
| No network isolation enforcement       | ICS-CERT AA20-205A      | CISA advisory: flat control networks allow lateral movement to actuators |

## Modbus register maps

### valve (fuel_valve, 10.10.3.51)

| Register | FC  | Mode | Description              |
|----------|-----|------|--------------------------|
| HR[0]    | FC3 | R/W  | valve_position, 0–100%   |
| IR[0]    | FC4 | R    | valve_position echo-back |

PLC writes HR[0] every second with the current fuel valve command. Attacker
can override by writing HR[0] directly.

### pump (cooling_pump, 10.10.3.52)

| Register | FC  | Mode | Description                  |
|----------|-----|------|------------------------------|
| HR[0]    | FC3 | R/W  | pump_speed, 0–100%           |
| coil[0]  | FC1 | R    | pump_running, 1 if speed > 0 |
| IR[0]    | FC4 | R    | pump_speed echo-back         |

Default speed is 100%. Writing HR[0] = 0 stops the cooling pump.

### breaker (breaker_a 10.10.3.53, breaker_b 10.10.3.54)

| Register | FC  | Mode | Description                                       |
|----------|-----|------|---------------------------------------------------|
| coil[0]  | FC1 | R/W  | breaker_state, 1=closed 0=open; writable directly |
| coil[1]  | FC1 | R/W  | trip_command; write 1 to open breaker             |
| coil[2]  | FC1 | R/W  | close_command; write 1 to close breaker           |
| IR[0]    | FC4 | R    | breaker_state echo-back                           |

Both trip_command and close_command self-clear after the sync loop processes them.
Writing `coil[0]` directly is also effective but less semantically clean.

## Role in the simulator

The actuators are the terminal effect layer. Everything upstream, PLC physics,
relay logic, HMI commands, ultimately writes to one of these four devices.

From an attacker's perspective they are accessible directly once on the control
network, without needing credentials or pivoting through the HMI or PLC:

```
attacker on ics_control network
        ↓
write actuator_breaker_a coil[1] = 1
        → Feeder A breaker opens
        → PLC detects: COIL_BREAKER_A = 0
        → physics: drag drops, RPM climbs
        → line voltage A = 0, alarm_undervoltage fires

write actuator_breaker_b coil[1] = 1
        → Feeder B breaker opens
        → total loss of load: RPM climbs rapidly
        → overspeed alarm → auto-trip → turbine offline

write actuator_fuel_valve HR[0] = 0
        → fuel cut immediately
        → RPM drops toward 0
        → governor fights back; write PLC setpoint = 0 to prevent recovery

write actuator_cooling_pump HR[0] = 0
        → cooling stops
        → temperature rises over time (minutes)
        → overtemp alarm → auto-trip if threshold reached
```

The actuators also serve as a second opinion on breaker state: an attacker can
read `actuator_breaker_a IR[0]` to confirm a trip worked, even if the PLC has
not yet polled and updated its own state.
