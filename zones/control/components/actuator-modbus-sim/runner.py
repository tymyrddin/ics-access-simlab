"""
Minimal Modbus-TCP simulator for the lab's actuators.

Reads a JSON profile that describes named resources mapped to Modbus
register/coil addresses, exposes them over TCP/502, and optionally runs a
companion Python tick script that ticks state forward every `--delay`
seconds (set_initial on start, update_values on each tick).

Replaces the upstream iotechsys/pymodbus-sim image: same observable
behaviour from the wire, no upstream version drift.
"""
import argparse
import importlib.util
import json
import threading
import time

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusServerContext,
    ModbusSlaveContext,
)
from pymodbus.server import StartTcpServer


_FC = {
    "COILS":             1,
    "DISCRETE_INPUTS":   2,
    "HOLDING_REGISTERS": 3,
    "INPUT_REGISTERS":   4,
}


class _Resource:
    def __init__(self, slave, table, addr):
        self._slave = slave
        self._fc = _FC[table]
        self._addr = addr

    def get_value(self):
        return self._slave.getValues(self._fc, self._addr, count=1)[0]

    def set_value(self, value):
        self._slave.setValues(self._fc, self._addr, [int(value)])


class _Resources(dict):
    def __init__(self, slave, profile):
        super().__init__()
        for r in profile.get("deviceResources", []):
            attrs = r["attributes"]
            self[r["name"]] = _Resource(slave, attrs["primaryTable"],
                                        attrs["startingAddress"])


def _load_script(path):
    spec = importlib.util.spec_from_file_location("actuator_logic", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _tick_loop(resources, module, delay):
    while True:
        try:
            module.update_values(resources)
        except Exception as exc:
            print(f"[actuator] tick error: {exc}", flush=True)
        time.sleep(delay)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port",    type=int, default=502)
    p.add_argument("--profile", required=True)
    p.add_argument("--script",  default=None)
    p.add_argument("--delay",   type=float, default=0.1)
    args = p.parse_args()

    with open(args.profile) as f:
        profile = json.load(f)

    slave = ModbusSlaveContext(
        di=ModbusSequentialDataBlock(0, [0] * 100),
        co=ModbusSequentialDataBlock(0, [0] * 100),
        hr=ModbusSequentialDataBlock(0, [0] * 100),
        ir=ModbusSequentialDataBlock(0, [0] * 100),
    )
    server_context = ModbusServerContext(slaves=slave, single=True)
    resources = _Resources(slave, profile)

    if args.script:
        module = _load_script(args.script)
        if hasattr(module, "set_initial"):
            module.set_initial(resources)
            print("[actuator] set_initial: " +
                  ", ".join(f"{n}={r.get_value()}" for n, r in resources.items()),
                  flush=True)
        if hasattr(module, "update_values"):
            t = threading.Thread(target=_tick_loop,
                                 args=(resources, module, args.delay),
                                 daemon=True)
            t.start()

    name = profile.get("name", "actuator")
    print(f"[actuator] {name} listening on :{args.port}", flush=True)
    StartTcpServer(context=server_context, address=("0.0.0.0", args.port))


if __name__ == "__main__":
    main()
