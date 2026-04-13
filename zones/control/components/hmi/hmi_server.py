#!/usr/bin/env python3
"""
HMI web interface (:8080) and Modbus mirror server (:502).

The Modbus server on :502 exposes the last-known PLC state as input registers
(read-only mirror). It also accepts writes to coils/holding registers and
forwards them to the PLC — making it a transparent proxy for operator commands.
Useful for attackers who discover the HMI before the PLC.
"""

import asyncio
import logging
import os
import threading

from flask import Flask, render_template, request, redirect, url_for, session
from pymodbus.client import ModbusTcpClient
from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartAsyncTcpServer

logging.basicConfig(level=logging.WARNING)

PLC_IP = os.environ.get("PLC_IP", "10.10.3.21")

FC_CO = 1
FC_HR = 3
FC_IR = 4

app = Flask(__name__, template_folder="templates")
app.secret_key = "uuplhmi2003"

_store = None


def _make_store():
    return ModbusSlaveContext(
        co=ModbusSequentialDataBlock(0, [0] * 20),
        di=ModbusSequentialDataBlock(0, [0] * 10),
        hr=ModbusSequentialDataBlock(0, [3000, 0, 100, 200] + [0] * 16),
        ir=ModbusSequentialDataBlock(0, [0] * 20),
    )


def _read_plc_all():
    try:
        with ModbusTcpClient(PLC_IP, port=502, timeout=2) as c:
            if not c.connect():
                return None
            ir = c.read_input_registers(0, 11, slave=1)
            hr = c.read_holding_registers(0, 4,  slave=1)
            co = c.read_coils(0, 7,               slave=1)
            result = {}
            if not ir.isError(): result["ir"] = ir.registers
            if not hr.isError(): result["hr"] = hr.registers
            if not co.isError(): result["co"] = [int(b) for b in co.bits[:7]]
            return result
    except Exception:
        return None


async def mirror_loop(store):
    """Keep local store in sync with PLC state."""
    while True:
        data = await asyncio.get_event_loop().run_in_executor(None, _read_plc_all)
        if data:
            if "ir" in data: store.setValues(FC_IR, 0, data["ir"])
            if "hr" in data: store.setValues(FC_HR, 0, data["hr"])
            if "co" in data: store.setValues(FC_CO, 0, data["co"])
        await asyncio.sleep(1.0)


# ---------------------------------------------------------------------------
# Flask
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    data = _read_plc_all() or {}
    ir   = data.get("ir", [0] * 11)
    hr   = data.get("hr", [3000, 0, 100, 200])
    co   = data.get("co", [0] * 7)
    return render_template("hmi.html",
                           ir=ir, hr=hr, co=co,
                           plc_ip=PLC_IP,
                           auth=session.get("auth"))


@app.route("/login", methods=["POST"])
def login():
    if request.form.get("password") == "operator":
        session["auth"] = True
    return redirect(url_for("index"))


@app.route("/logout")
def logout():
    session.pop("auth", None)
    return redirect(url_for("index"))


@app.route("/setpoint", methods=["POST"])
def setpoint():
    if not session.get("auth"):
        return redirect(url_for("index"))
    try:
        sp = max(0, min(3600, int(request.form["value"])))
        with ModbusTcpClient(PLC_IP, port=502, timeout=2) as c:
            if c.connect():
                c.write_register(0, sp, slave=1)
    except Exception:
        pass
    return redirect(url_for("index"))


@app.route("/estop", methods=["POST"])
def estop():
    if not session.get("auth"):
        return redirect(url_for("index"))
    try:
        with ModbusTcpClient(PLC_IP, port=502, timeout=2) as c:
            if c.connect():
                c.write_coil(0, True, slave=1)
    except Exception:
        pass
    return redirect(url_for("index"))


@app.route("/reset", methods=["POST"])
def reset():
    if not session.get("auth"):
        return redirect(url_for("index"))
    try:
        with ModbusTcpClient(PLC_IP, port=502, timeout=2) as c:
            if c.connect():
                c.write_coil(0, False, slave=1)
    except Exception:
        pass
    return redirect(url_for("index"))


def run_flask():
    app.run(host="0.0.0.0", port=8080, debug=False, use_reloader=False)


async def main():
    global _store
    _store  = _make_store()
    context = ModbusServerContext(slaves=_store, single=True)

    threading.Thread(target=run_flask, daemon=True).start()

    await asyncio.gather(
        StartAsyncTcpServer(context=context, address=("0.0.0.0", 502)),
        mirror_loop(_store),
    )


if __name__ == "__main__":
    asyncio.run(main())
