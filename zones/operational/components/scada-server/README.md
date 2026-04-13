# Legacy SCADA server

The `scada-server` component is an earlier custom Python SCADA implementation.
It has been superseded by `scada-lts` (operational zone) and `scada-lts-ctrl`
(control zone), which use the Scada-LTS image and carry realistic CVEs.

This directory is preserved and the Dockerfile is functional, but `scada-server`
is not wired into `ctf-config.yaml` in the current scenario.

## Container details

Base image: `debian:bookworm-slim`. Flask web interface on port 8080. SSH on
port 22 with a Windows Server 2016 facade (`winserver2016_shell.sh`).

User: `scada_admin`, password `W1nd0ws@2016`. The web interface credentials
are `admin` / `admin`.

Environment variable `HISTORIAN_IP` defaults to 10.10.2.10.

Exposed ports: 22 (SSH), 8080 (web UI).

## What the credentials mean

The `scada_admin` SSH password `W1nd0ws@2016` and the web credentials `admin /
admin` are still referenced in the engineering workstation profile
(`Documents\engineering_notes.txt`) and in the legacy workstation shares
(`C:\UUPL\NETWORK.TXT`). If this component were active at 10.10.2.20, those
credentials would work. In the current scenario, 10.10.2.20 is the Scada-LTS
instance, which uses `admin / admin` for the web UI and a different SSH setup.

## Summary

Deprecated custom SCADA server. Use `scada-lts` for the operational zone or
`scada-lts-ctrl` for the control zone. The credentials in the engineering notes
(`scada_admin` / `W1nd0ws@2016`) refer to this component's design.
