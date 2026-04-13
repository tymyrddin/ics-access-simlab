# Legacy actuator

The `actuator` component is the original field actuator container from the first
development phase. It has been superseded by `actuator-modbus-sim`, which uses
`iotechsys/pymodbus-sim:1.0.6-x86_64` and provides separate valve, pump, and
breaker profiles.

This directory is preserved but the `actuator` container is not wired into
`ctf-config.yaml` in the current scenario.

## Container details

Base image: `python:3.11-slim`. Custom Python pymodbus server. Port 502.

## In short

Deprecated. Use `actuator-modbus-sim` instead.
