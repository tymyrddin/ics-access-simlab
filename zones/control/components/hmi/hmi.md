# HMI: Hex Turbine Control System

## Device description

The HMI is the human-machine interface for the UU P&L Hex Turbine Control
System. It provides two interfaces for operators: an SSH terminal shell
presenting a restricted operator console, and an HTTP web interface on port
8080. Both connect to the PLC via Modbus and forward operator commands.

Operationally, the HMI is the legitimate control surface for turbine operators.
Engineers use it to adjust the governor setpoint, monitor alarms, and execute
emergency stops. It is not designed to be reachable from outside the control
network, but in practice it is dual-accessible from the operational zone via
the engineering workstation.

From an attacker's perspective, the HMI is the only device in the control zone
that presents a shell interface and accepts SSH connections. It is therefore
the natural pivot target after reaching the control network:

* SSH with a weak, default password
* web interface with the same credentials
* restricted shell that can be escaped
* Modbus proxy on port 502 that accepts writes and forwards them to the PLC
* access to the HMI is equivalent to operator-level control of the turbine

## Container behaviour

The container exposes three network services:

* SSH on port 22: operator account with restricted Python shell as login shell
* HTTP on port 8080: Flask web interface, cookie-based session authentication
* Modbus TCP on port 502: mirror of PLC state, also accepts writes and proxies them to the PLC

The SSH shell (`hmi_shell.py`) is the login shell for the `operator` account.
It connects to the PLC, renders a live ANSI terminal display refreshing every
3 seconds, and accepts a small command set. Standard shell commands are not
available unless the shell is escaped.

The web interface auto-refreshes every 3 seconds and displays all process
values read directly from the PLC. Operator controls (setpoint, emergency stop,
reset) are behind a login form.

The Modbus server on port 502 maintains a mirrored copy of PLC state and
accepts coil and register writes, forwarding them to the PLC. This means an
attacker who finds the HMI before the PLC can still issue control commands
through it.

## Deliberately introduced vulnerabilities

### Default SSH credentials

```
operator : operator
```

The account uses the provisioned username as its password. This is a common
result of operational urgency during commissioning, credentials set for testing
and never changed.

SSH password authentication is enabled. The account is accessible to any host
that can reach port 22.

### Restricted shell with escape potential

The `operator` account uses `hmi_shell.py` as its login shell. The shell
accepts only: `setpoint`, `fuel`, `estop`, `reset`, `help`, `exit`.

However, the shell is a Python script. Standard shell escape techniques apply:

* `CTRL-C` followed by input after exception handling
* `os.system()` not available via normal commands, but the shell does not sandbox the Python interpreter
* Sending a crafted input that causes an unhandled exception may drop to a Python REPL or expose the underlying OS

Escaping the restricted shell gives bash access to the container as the
`operator` user.

### Web interface with default credentials

```
operator : operator
```

The web interface uses Flask with a hardcoded secret key:

```python
app.secret_key = "uuplhmi2003"
```

A known secret key allows session cookie forgery: an attacker who knows or
guesses the key can craft a valid session cookie without providing credentials.

The login endpoint does not rate-limit attempts.

### Modbus proxy accepts unauthenticated writes

The Modbus server on port 502 accepts write requests and forwards them to the
PLC. There is no authentication, no rate limiting, and no validation beyond
register bounds. An attacker who discovers this service can issue any Modbus
command the PLC would accept, without needing to reach the PLC directly.

### Flask debug mode disabled, but app.secret_key is static

The secret key never changes between restarts. Once known, it is valid
indefinitely. The key is visible in the source file.

## Real-world vulnerabilities / CVEs

| Component                                | CVE / Reference                                 | Notes                                                                               |
|------------------------------------------|-------------------------------------------------|-------------------------------------------------------------------------------------|
| Default HMI credentials                  | CVE-2018-7513                                   | Emerson DeltaV HMI default accounts                                                 |
| Flask session forgery (known secret_key) | CVE-2018-1000656                                | Flask session cookie signing with weak/known key                                    |
| Restricted shell escape                  | General class: documented in MITRE ATT&CK T1059 | Restricted shells are not security boundaries                                       |
| Unauthenticated Modbus proxy             | ICS-CERT Advisory ICSA-10-090-01                | Forwarding Modbus writes without auth                                               |
| SSH with password auth enabled           | CVE-2016-6210                                   | Timing attack on SSH user enumeration; combined with weak password = trivial access |

## Artefacts attackers should find

### Port scan

```
22/tcp   open  ssh     OpenSSH
502/tcp  open  modbus
8080/tcp open  http    (Hex Turbine HMI)
```

The SSH banner and HTTP title identify the device as the HMI.

### Web interface

Visiting `http://10.10.3.10:8080/` would show:

* live turbine process values (read without authentication)
* PLC IP address displayed in the page header: `10.10.3.21`
* operator login form with `operator` pre-filled in the username field
* SSH connection hint in the page: `SSH: operator@10.10.3.10`

The page reveals the PLC IP, the operator username, and the SSH address before
any login is required.

### SSH shell

```
ssh operator@10.10.3.10
password: operator
```

Lands in the operator terminal showing turbine state. Available commands:

```
setpoint <rpm>   set governor setpoint (0-3600)
fuel <0-100>     set fuel valve position directly
estop            activate emergency stop
reset            clear emergency stop flag
help
exit
```

### Modbus proxy on port 502

An attacker scanning all open ports finds Modbus on the HMI container as well
as the PLC. Writes to this service are forwarded to the PLC. This provides a
second path to the PLC without requiring direct network access to 10.10.3.21.

## Role in the simulator

The HMI is the intended initial target within the control zone. It is reachable
from the operational zone via the engineering workstation and presents the most
accessible entry point:

```
engineering workstation (10.10.3.100)
        ↓
SSH to HMI: ssh operator@10.10.3.10
        ↓
restricted operator shell
        ↓
option A: issue control commands directly (estop, setpoint)
option B: escape shell → full container access
option C: discover PLC IP (10.10.3.21) → attack PLC directly
option D: use Modbus proxy (:502) to issue PLC commands from HMI
```

The HMI also reveals the full network topology of the control zone through its
web interface and shell display: IP addresses, device names, and the register
structure of the PLC.

## HMI command reference

Commands available in the SSH operator shell:

| Command                    | Effect                                | Notes                  |
|----------------------------|---------------------------------------|------------------------|
| `setpoint <rpm>`           | Write governor setpoint to PLC HR[0]  | Clamped 0–3600         |
| `fuel <0-100>`             | Write fuel valve command to PLC HR[1] | Bypasses governor      |
| `estop`                    | Write coil 0 = 1 on PLC               | Immediate turbine trip |
| `reset`                    | Write coil 0 = 0 on PLC               | Clears emergency stop  |
| `help`                     | Show command list                     |                        |
| `exit` / `quit` / `logout` | Disconnect                            |                        |
