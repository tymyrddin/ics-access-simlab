# Revenue meter IED: MTR-100

## Device description

The MTR-100 is the revenue-grade metering device for the UU P&L Hex Turbine
output. It measures the electrical quantities delivered to the distribution
network and provides billing-grade data to the SCADA historian.

The device is passive: it has no control outputs, no ability to open or close
breakers, and no influence over the turbine control loop. Its sole function is
measurement and reporting.

Operationally, the meter is read periodically by the historian and SCADA system
to record power generation for billing and load balancing purposes. It derives
power and power factor from voltage and current readings taken from the PLC.

From an attacker's perspective, the meter itself is not a control target. It
is a reconnaissance asset:

* confirms that the turbine is running and generating power
* reveals live process values without requiring PLC access
* fingerprints the network presence of metering infrastructure
* SNMP exposes device metadata

An attacker who has already compromised historian or SCADA will recognise the
meter as the data source for billing records.

## Container behaviour

The container exposes two network services:

* Modbus TCP on port 502: five input registers, read-only
* SNMP on port 161 (UDP): snmpd with default community strings

The container polls the PLC input registers every 2 seconds, extracts voltage
(Feeder A), current (Feeder A), and frequency, computes power as V × I × 0.95 / 1000,
and stores a fixed power factor of 95%. These five values are written to the
meter's own input registers.

There are no holding registers or coils of operational significance. There is
nothing writable that affects the physical process.

## Deliberately introduced vulnerabilities

### No authentication on Modbus

The Modbus server accepts connections and read requests from any host. An
attacker who reaches the meter can read all five registers without credentials.

This is consistent with the design of Modbus TCP and common in revenue metering
deployments where the Modbus interface is considered a "read-only" data port,
and therefore assumed safe.

### Default SNMP community strings

The snmpd configuration uses factory defaults:

```
public   (read)
private  (read-write)
```

An SNMP walk with the public community reveals device identity, firmware
version, and interface information. The private community allows write access
to SNMP-managed OIDs.

### Data derived from PLC: manipulation possible upstream

The meter does not have its own sensors. It reads from the PLC. An attacker who
manipulates the PLC's input registers (for example, by disrupting the physics
loop) will cause the meter to report false values. The historian will then
record falsified billing data.

This is not a vulnerability in the meter itself, but in the trust chain. The
meter faithfully reports what the PLC says without independent verification.

## Real-world vulnerabilities / CVEs

| Component                              | CVE / Reference                   | Notes                                              |
|----------------------------------------|-----------------------------------|----------------------------------------------------|
| Unauthenticated Modbus read            | ICS-CERT Advisory ICSA-10-090-01  | Modbus has no authentication by design             |
| Default SNMP community strings         | CVE-2002-0012                     | net-snmp default public/private                    |
| Revenue meter data integrity           | CVE-2017-9946                     | Siemens SICAM meter: data manipulation via Modbus  |
| Trust in PLC data without verification | General class: ICS-CERT AA20-205A | Cascading data integrity issues in OT environments |

## Artefacts attackers should find

### Port scan

```
502/tcp  open  modbus
161/udp  open  snmp
```

No SSH. No HTTP. No shell. The meter is the simplest device in the control zone.

### Modbus register read

```
FC4 (input registers), address 0, count 5:
  [0]  voltage_v          (e.g. 229)
  [1]  current_a          (e.g. 148)
  [2]  frequency_hz_x10   (e.g. 500 = 50.0 Hz)
  [3]  power_kw           (e.g. 32)
  [4]  power_factor_pct   (95)
```

These values confirm that the turbine is running and generating power. A
frequency of 0 or voltage of 0 indicates the turbine is offline or a breaker
has opened.

### SNMP walk

```
snmpwalk -c public -v1 10.10.3.33
```

Returns device identity as MTR-100, firmware 1.3.0, uptime, and interface
information. Community string `private` allows write access.

## Modbus register map

### Input Registers (FC4: read-only)

| Address | Name             | Unit | Notes                         |
|---------|------------------|------|-------------------------------|
| 0       | voltage_v        | V    | Line voltage, Feeder A        |
| 1       | current_a        | A    | Line current, Feeder A        |
| 2       | frequency_hz_x10 | —    | e.g. 500 = 50.0 Hz            |
| 3       | power_kw         | kW   | Computed: V × I × 0.95 / 1000 |
| 4       | power_factor_pct | %    | Fixed at 95                   |

No holding registers. No coils. No write paths.

## Role in the simulator

The meter is a reconnaissance device from the attacker's perspective. Finding
it confirms the presence of power generation infrastructure and provides a
secondary read path to process values without touching the PLC.

The meter's output is also the data source for historian billing records. An
attacker interested in covering their tracks (or creating false billing records)
would need to manipulate the PLC data upstream of the meter, as the meter has
no local write path.

```
attacker reads meter IR[0..4]
        ↓
confirms turbine is running (frequency ≈ 500, voltage ≈ 230)
        → decision: turbine is generating; attack will have measurable effect
        → or: frequency = 0, power = 0 → turbine already offline

attacker manipulates PLC register data
        ↓
meter polls PLC → reports falsified values
        ↓
historian records false generation data
```

The meter itself cannot be used to cause harm. Its value is what it reveals.
