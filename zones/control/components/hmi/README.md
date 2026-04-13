# Legacy HMI

The `hmi` component is the original operator workstation from the first
development phase. It has been superseded by `scada-lts-ctrl`, which provides
the same control-zone SCADA/HMI function using the Scada-LTS image with
realistic CVEs.

This directory is preserved but the `hmi` container is not wired into
`ctf-config.yaml` in the current scenario. It will not start unless manually
added.

## Container details

Base image: `python:3.11-slim`. Flask web interface on port 8080. SSH on port 22.

User: `operator`, password `operator`. Login shell is `hmi_shell.py`, a
restricted Python REPL that accepts a small set of HMI-style commands.

The Flask interface reads from and writes to the turbine PLC via Modbus TCP and
renders a basic operator view.

Exposed ports: 22 (SSH), 502 (Modbus mirror, forwarded to PLC), 8080 (web UI).

## Quirks

The engineering workstation documentation refers to `operator / operator` at
10.10.3.10 with a web interface at `http://10.10.3.10:8080/`. If a scenario
uses the legacy HMI instead of scada-lts-ctrl, those credentials and that address
remain correct. If scada-lts-ctrl is active, the address is the same but the
credentials are `admin / admin`.

## In short

Deprecated. Use `scada-lts-ctrl` instead.
