#!/usr/bin/env python3
"""
UU P&L Revenue Meter — MTR-100
Hex Computing Division, firmware 1.3.0

Passive revenue meter. Reads from PLC, derives power and power factor.
No control outputs. No authentication on Modbus.

Protocols:
  Modbus TCP  :502
  SNMP        :161  (snmpd, community: public/private)

Modbus register map (FC4, input registers, read-only):
  0  voltage_v
  1  current_a
  2  frequency_hz_x10
  3  power_kw
  4  power_factor_pct   (0-100, e.g. 95 = 0.95)
"""

import asyncio
import logging
import os

from pymodbus.client import ModbusTcpClient
from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartAsyncTcpServer

logging.basicConfig(level=logging.WARNING)

PLC_IP = os.environ.get("PLC_IP", "10.10.3.21")

FC_IR = 4


def _make_store():
    return ModbusSlaveContext(
        co=ModbusSequentialDataBlock(0, [0] * 10),
        di=ModbusSequentialDataBlock(0, [0] * 10),
        hr=ModbusSequentialDataBlock(0, [0] * 10),
        ir=ModbusSequentialDataBlock(0, [0] * 10),
    )


async def poll_loop(store):
    """Poll PLC for voltage, current, frequency; derive power and power factor."""
    while True:
        try:
            regs = await asyncio.get_event_loop().run_in_executor(None, _read_plc)
            if regs:
                v      = regs[3]   # line_voltage_a
                i      = regs[4]   # line_current_a
                freq   = regs[7]   # frequency_x10
                power  = max(0, int(v * i * 0.95 / 1000))
                pf     = 95        # fixed 0.95 power factor (simplified)
                store.setValues(FC_IR, 0, [v, i, freq, power, pf])
        except Exception:
            pass
        await asyncio.sleep(2.0)


def _read_plc():
    try:
        with ModbusTcpClient(PLC_IP, port=502, timeout=3) as c:
            if c.connect():
                r = c.read_input_registers(0, count=11, slave=1)
                if not r.isError():
                    return r.registers
    except Exception:
        pass
    return None


async def main():
    store   = _make_store()
    context = ModbusServerContext(slaves=store, single=True)
    await asyncio.gather(
        StartAsyncTcpServer(context=context, address=("0.0.0.0", 502)),
        poll_loop(store),
    )


if __name__ == "__main__":
    asyncio.run(main())
