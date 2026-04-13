#!/usr/bin/env python3
"""
Generic actuator container for UU P&L control zone.
Parameterised by environment variables:

  ACTUATOR_NAME  fuel_valve | cooling_pump | breaker_a | breaker_b
  ACTUATOR_TYPE  valve | pump | breaker
  FEEDER         (breakers only) feeder name for logging

Modbus register map
-------------------
valve  (ACTUATOR_TYPE=valve):
  holding[0]  valve_position  0-100%  writable (no auth)
  input[0]    valve_position  echo-back

pump   (ACTUATOR_TYPE=pump):
  holding[0]  pump_speed      0-100%  writable
  coil[0]     pump_running    1 if speed > 0
  input[0]    pump_speed      echo-back

breaker (ACTUATOR_TYPE=breaker):
  coil[0]     breaker_state   1=closed 0=open  writable directly
  coil[1]     trip_command    write 1 to open breaker
  coil[2]     close_command   write 1 to close breaker
  input[0]    breaker_state   echo-back

No authentication on any register. An attacker with Modbus access can
write any of these values directly, bypassing the PLC control loop.
"""

import asyncio
import logging
import os

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartAsyncTcpServer

logging.basicConfig(level=logging.WARNING)

NAME  = os.environ.get("ACTUATOR_NAME", "unknown")
ATYPE = os.environ.get("ACTUATOR_TYPE", "valve")

FC_CO = 1
FC_HR = 3
FC_IR = 4


def _make_store():
    if ATYPE == "breaker":
        # Start closed (1)
        co = ModbusSequentialDataBlock(0, [1, 0, 0] + [0] * 17)
        hr = ModbusSequentialDataBlock(0, [0] * 20)
        ir = ModbusSequentialDataBlock(0, [1] + [0] * 19)
    elif ATYPE == "pump":
        co = ModbusSequentialDataBlock(0, [0] * 20)
        hr = ModbusSequentialDataBlock(0, [100] + [0] * 19)  # default 100% speed
        ir = ModbusSequentialDataBlock(0, [100] + [0] * 19)
    else:  # valve
        co = ModbusSequentialDataBlock(0, [0] * 20)
        hr = ModbusSequentialDataBlock(0, [0] * 20)  # starts closed
        ir = ModbusSequentialDataBlock(0, [0] * 20)
    return ModbusSlaveContext(
        co=co, di=ModbusSequentialDataBlock(0, [0] * 10), hr=hr, ir=ir,
    )


async def sync_loop(store):
    """Keep echo-back input registers in sync with writable registers/coils."""
    while True:
        if ATYPE == "breaker":
            state = store.getValues(FC_CO, 0, count=1)[0]
            trip  = store.getValues(FC_CO, 1, count=1)[0]
            close = store.getValues(FC_CO, 2, count=1)[0]
            if trip:
                state = 0
                store.setValues(FC_CO, 0, [0])
                store.setValues(FC_CO, 1, [0])  # clear command
            if close:
                state = 1
                store.setValues(FC_CO, 0, [1])
                store.setValues(FC_CO, 2, [0])  # clear command
            store.setValues(FC_IR, 0, [state])

        elif ATYPE == "pump":
            speed = store.getValues(FC_HR, 0, count=1)[0]
            speed = max(0, min(100, speed))
            store.setValues(FC_CO, 0, [1 if speed > 0 else 0])
            store.setValues(FC_IR, 0, [speed])

        else:  # valve
            pos = store.getValues(FC_HR, 0, count=1)[0]
            pos = max(0, min(100, pos))
            store.setValues(FC_IR, 0, [pos])

        await asyncio.sleep(0.1)


async def main():
    store   = _make_store()
    context = ModbusServerContext(slaves=store, single=True)
    await asyncio.gather(
        StartAsyncTcpServer(context=context, address=("0.0.0.0", 502)),
        sync_loop(store),
    )


if __name__ == "__main__":
    asyncio.run(main())
