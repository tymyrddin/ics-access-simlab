#!/usr/bin/env python3
"""
UU P&L Protective Relay IED, REL-200A/B
Hex Computing Division, firmware 2.0.1

Protocols:
  Modbus TCP  :502   read relay state, write protection thresholds (no auth)
  HTTP        :8081  relay web interface, default credentials admin/relay1234
  SNMP        :161   managed by snmpd

Modbus register map
-------------------
Holding Registers (FC3, writable, changing these disables protection):
  0  undervoltage_threshold_v   default 196 (85% of 230V)
  1  overspeed_threshold_rpm    default 3300
  2  overcurrent_threshold_a    default 200

Input Registers (FC4):
  0  line_voltage_v    (mirrored from PLC)
  1  line_current_a    (mirrored from PLC)
  2  frequency_hz_x10  (mirrored from PLC)
  3  turbine_rpm       (mirrored from PLC)

Coils (FC1):
  0  relay_trip_status   1=tripped, writable (force-trip attack vector)
"""

import asyncio
import json
import logging
import os
import threading
import time

import paho.mqtt.client as mqtt

from flask import Flask, request, render_template, redirect, url_for, session
from pymodbus.client import ModbusTcpClient
from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartAsyncTcpServer

logging.basicConfig(level=logging.WARNING)

RELAY_ID       = os.environ.get("RELAY_ID",       "a")
FEEDER         = os.environ.get("FEEDER",         "Unknown Feeder")
PLC_IP         = os.environ.get("PLC_IP",         "10.10.3.21")
BREAKER_IP     = os.environ.get("BREAKER_IP",     "10.10.3.53")
MQTT_BROKER_IP = os.environ.get("MQTT_BROKER_IP", "10.10.3.60")
VOLTAGE_REG = int(os.environ.get("VOLTAGE_REG", "3"))
CURRENT_REG = int(os.environ.get("CURRENT_REG", "4"))
FREQ_REG    = 7
RPM_REG     = 0

FC_CO = 1
FC_HR = 3
FC_IR = 4

HR_UV_THRESH  = 0
HR_OS_THRESH  = 1
HR_OC_THRESH  = 2

IR_VOLTAGE = 0
IR_CURRENT = 1
IR_FREQ    = 2
IR_RPM     = 3

COIL_TRIP     = 0
COIL_BREAKER  = 1

RECLOSE_DELAY = 10.0

app = Flask(__name__, template_folder="templates")
app.secret_key = "hex1234unseen"

_store = None       # set in main()
_mqtt_client = None # set in main()
_trip_log = []


def _make_store():
    # zero_mode=True: Modbus protocol address N reads block slot N. Without
    # this, pymodbus's ModbusSlaveContext applies a 1-based offset that shifts
    # everything by one, so HR_UV_THRESH=0 reads what looks like HR[1] in the
    # init list (3300) instead of HR[0] (196). That misalignment had the
    # relay reading bogus thresholds and self-tripping at every startup.
    return ModbusSlaveContext(
        co=ModbusSequentialDataBlock(0, [0] * 10),
        di=ModbusSequentialDataBlock(0, [0] * 10),
        hr=ModbusSequentialDataBlock(0, [196, 3300, 200] + [0] * 17),
        ir=ModbusSequentialDataBlock(0, [0] * 20),
        zero_mode=True,
    )


def _update_trip_log_registers(store, cause, voltage, current, rpm):
    """Update HR[10:20] with latest trip events (5 events × 2 registers each)."""
    timestamp = int(time.time())
    cause_codes = {
        "undervoltage": 1, "overcurrent": 2, "overspeed": 3,
        "manual": 4, "reclose-failed": 5, "remote": 6
    }
    cause_code = cause_codes.get(cause, 0)

    # Shift existing entries down: HR[10:14] → HR[12:16], HR[12:16] → HR[14:18], etc.
    existing = store.getValues(FC_HR, 10, count=10)
    store.setValues(FC_HR, 12, existing[:8])  # Shift 4 oldest entries down

    # Write new entry at HR[10:11]
    # Entry format: [timestamp_high, timestamp_low, cause_code, voltage_v, current_a]
    # But we only have 2 registers, so pack: [time_low, (cause_code<<8)|voltage_low]
    time_low = timestamp & 0xFFFF
    packed = (cause_code << 12) | (voltage & 0xFFF)
    store.setValues(FC_HR, 10, [time_low, packed])


def _plc_read(reg, count=1):
    try:
        with ModbusTcpClient(PLC_IP, port=502, timeout=2) as c:
            if c.connect():
                r = c.read_input_registers(reg, count=count, slave=1)
                if not r.isError():
                    return r.registers
    except Exception:
        pass
    return [0] * count


def _mqtt_publish_trip(cause: str, voltage: int, current: int, rpm: int):
    """Publish a trip event to uupl/relay/{id}/trip. Best-effort, never raises."""
    try:
        payload = json.dumps({
            "relay_id": RELAY_ID,
            "feeder":   FEEDER,
            "cause":    cause,
            "voltage":  voltage,
            "current":  current,
            "rpm":      rpm,
            "time":     time.strftime("%Y-%m-%dT%H:%M:%S"),
        })
        _mqtt_client.publish(f"uupl/relay/{RELAY_ID}/trip", payload, qos=0)
    except Exception:
        pass


def _breaker_write(state: int):
    """Write breaker state coil directly to actuator_breaker container."""
    try:
        with ModbusTcpClient(BREAKER_IP, port=502, timeout=2) as c:
            if c.connect():
                # coil[1]=1 trips, coil[2]=1 closes
                if state == 0:
                    c.write_coil(1, True, slave=1)
                else:
                    c.write_coil(2, True, slave=1)
    except Exception:
        pass


async def poll_plc_loop(store):
    """Pull measurements from PLC and update local input registers."""
    while True:
        regs = await asyncio.get_running_loop().run_in_executor(
            None, lambda: _plc_read(0, 11)
        )
        if len(regs) >= 11:
            store.setValues(FC_IR, IR_VOLTAGE, [regs[VOLTAGE_REG]])
            store.setValues(FC_IR, IR_CURRENT, [regs[CURRENT_REG]])
            store.setValues(FC_IR, IR_FREQ,    [regs[FREQ_REG]])
            store.setValues(FC_IR, IR_RPM,     [regs[RPM_REG]])
        await asyncio.sleep(0.5)


async def relay_logic_loop(store):
    """Protection logic: check thresholds, trip/reclose breaker."""
    # Explicitly reset coils to ensure clean startup state
    store.setValues(FC_CO, COIL_TRIP, [0])
    store.setValues(FC_CO, COIL_BREAKER, [0])  # breaker closed
    # Grace period covers the PLC physics ramp. The PLC ramps fuel valve
    # 0->60% over ~30s; RPM (and therefore voltage) is proportional to
    # fuel fraction, so voltage stays well below the 85% undervoltage
    # threshold for the whole ramp plus a few seconds of RPM convergence.
    # 60s comfortably outlasts the lot. Real protective relays have
    # similar power-on blocking periods.
    await asyncio.sleep(60.0)
    tripped_at = None
    reclosed   = False

    while True:
        voltage  = store.getValues(FC_IR, IR_VOLTAGE, count=1)[0]
        current  = store.getValues(FC_IR, IR_CURRENT, count=1)[0]
        rpm      = store.getValues(FC_IR, IR_RPM,     count=1)[0]
        uv_thresh = store.getValues(FC_HR, HR_UV_THRESH, count=1)[0]
        oc_thresh = store.getValues(FC_HR, HR_OC_THRESH, count=1)[0]
        os_thresh = store.getValues(FC_HR, HR_OS_THRESH, count=1)[0]
        tripped   = store.getValues(FC_CO, COIL_TRIP,    count=1)[0]

        undervoltage = voltage < uv_thresh and current > 5
        overcurrent  = current > oc_thresh
        overspeed    = rpm > os_thresh

        fault = undervoltage or overcurrent or overspeed

        if not tripped and fault:
            cause = ("undervoltage" if undervoltage else
                     "overcurrent" if overcurrent else "overspeed")
            _trip_log.append({
                "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "cause": cause,
                "voltage": voltage,
                "current": current,
                "rpm": rpm,
            })
            if len(_trip_log) > 50:
                _trip_log.pop(0)
            store.setValues(FC_CO, COIL_TRIP, [1])
            store.setValues(FC_CO, COIL_BREAKER, [1])  # breaker open
            _update_trip_log_registers(store, cause, voltage, current, rpm)
            await asyncio.get_running_loop().run_in_executor(None, lambda: _breaker_write(0))
            await asyncio.get_running_loop().run_in_executor(
                None, lambda: _mqtt_publish_trip(cause, voltage, current, rpm)
            )
            tripped_at = time.monotonic()
            reclosed   = False

        elif tripped and tripped_at is None:
            # Coil went 0->1 but this loop did not set it. Most likely an
            # external Modbus write to COIL_TRIP. Real protective relays log
            # remote commands; emulate that so attacker activity leaves a trace.
            cause = "remote"
            _trip_log.append({
                "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "cause": cause,
                "voltage": voltage,
                "current": current,
                "rpm": rpm,
            })
            if len(_trip_log) > 50:
                _trip_log.pop(0)
            store.setValues(FC_CO, COIL_BREAKER, [1])  # breaker follows trip coil
            _update_trip_log_registers(store, cause, voltage, current, rpm)
            await asyncio.get_running_loop().run_in_executor(None, lambda: _breaker_write(0))
            await asyncio.get_running_loop().run_in_executor(
                None, lambda: _mqtt_publish_trip(cause, voltage, current, rpm)
            )
            tripped_at = time.monotonic()
            reclosed   = False

        elif tripped and tripped_at and not reclosed:
            if time.monotonic() - tripped_at >= RECLOSE_DELAY:
                store.setValues(FC_CO, COIL_TRIP, [0])
                store.setValues(FC_CO, COIL_BREAKER, [0])  # breaker closed
                await asyncio.get_running_loop().run_in_executor(None, lambda: _breaker_write(1))
                reclosed = True
                await asyncio.sleep(1.0)
                # Re-check: if fault persists, re-trip and stop reclosing
                voltage = store.getValues(FC_IR, IR_VOLTAGE, count=1)[0]
                current = store.getValues(FC_IR, IR_CURRENT, count=1)[0]
                rpm     = store.getValues(FC_IR, IR_RPM,     count=1)[0]
                if voltage < uv_thresh and current > 5 or current > oc_thresh or rpm > os_thresh:
                    store.setValues(FC_CO, COIL_TRIP, [1])
                    store.setValues(FC_CO, COIL_BREAKER, [1])  # breaker open again
                    _update_trip_log_registers(store, "reclose-failed", voltage, current, rpm)
                    await asyncio.get_running_loop().run_in_executor(None, lambda: _breaker_write(0))
                    _trip_log.append({
                        "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "cause": "reclose-failed",
                        "voltage": voltage,
                        "current": current,
                        "rpm": rpm,
                    })

        elif not tripped:
            tripped_at = None
            reclosed   = False

        await asyncio.sleep(0.2)


# ---------------------------------------------------------------------------
# Flask web interface
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    auth = session.get("auth")
    return render_template("relay.html",
                           relay_id=RELAY_ID, feeder=FEEDER,
                           store=_store, auth=auth,
                           trip_log=_trip_log[-10:])


@app.route("/login", methods=["POST"])
def login():
    u = request.form.get("username", "")
    p = request.form.get("password", "")
    if u == "admin" and p == "relay1234":
        session["auth"] = True
    return redirect(url_for("index"))


@app.route("/logout")
def logout():
    session.pop("auth", None)
    return redirect(url_for("index"))


@app.route("/config", methods=["POST"])
def config():
    if not session.get("auth"):
        return redirect(url_for("index"))
    try:
        uv = int(request.form.get("uv_thresh", 196))
        oc = int(request.form.get("oc_thresh", 200))
        os_ = int(request.form.get("os_thresh", 3300))
        _store.setValues(FC_HR, HR_UV_THRESH, [max(0, min(230, uv))])
        _store.setValues(FC_HR, HR_OC_THRESH, [max(0, min(1000, oc))])
        _store.setValues(FC_HR, HR_OS_THRESH, [max(0, min(4000, os_))])
    except (ValueError, TypeError):
        pass
    return redirect(url_for("index"))


@app.route("/trip", methods=["POST"])
def force_trip():
    if not session.get("auth"):
        return redirect(url_for("index"))
    _store.setValues(FC_CO, COIL_TRIP, [1])
    _store.setValues(FC_CO, COIL_BREAKER, [1])  # breaker open
    voltage = _store.getValues(FC_IR, IR_VOLTAGE, count=1)[0]
    current = _store.getValues(FC_IR, IR_CURRENT, count=1)[0]
    rpm = _store.getValues(FC_IR, IR_RPM, count=1)[0]
    _update_trip_log_registers(_store, "manual", voltage, current, rpm)
    _breaker_write(0)
    return redirect(url_for("index"))


def run_flask():
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False)


async def main():
    global _store, _mqtt_client
    _store = _make_store()
    context = ModbusServerContext(slaves=_store, single=True)

    _mqtt_client = mqtt.Client()
    _mqtt_client.reconnect_delay_set(min_delay=1, max_delay=30)
    _mqtt_client.loop_start()
    try:
        _mqtt_client.connect(MQTT_BROKER_IP, 1883, keepalive=60)
    except Exception:
        pass  # loop_start retries in the background

    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()

    await asyncio.gather(
        StartAsyncTcpServer(context=context, address=("0.0.0.0", 502)),
        poll_plc_loop(_store),
        relay_logic_loop(_store),
    )


if __name__ == "__main__":
    asyncio.run(main())
