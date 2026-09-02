#!/usr/bin/env python3
"""
UU P&L Hex Turbine Controller, HEX-CPU-4000
Hex Computing Division, firmware 4.1.2

Protocols:
  Modbus TCP  :502    primary control interface, no authentication
  IEC-104     :2404   substation automation protocol
  SNMP        :161    managed by snmpd (see /etc/snmp/snmpd.conf)

Modbus register map
-------------------
Coils (FC1, writable by anyone on the network):
  0  emergency_stop       write 1 to trip, write 0 to reset
  1  alarm_overspeed      set when RPM > 3300
  2  alarm_overtemp       set when temp > 490 C
  3  alarm_overpressure   set when pressure > 95 bar
  4  alarm_undervoltage   set when feeder voltage < 85% nominal
  5  breaker_a_closed     mirrored from uupl-breaker-a (1=closed)
  6  breaker_b_closed     mirrored from uupl-breaker-b (1=closed)

Holding Registers (FC3, writable by anyone on the network):
  0  governor_setpoint_rpm   target RPM (default 3000)
  1  fuel_valve_command      0-100%, written by governor loop
  2  cooling_pump_speed      0-100%
  3  overcurrent_threshold   amps (default 200)

Input Registers (FC4, read-only):
  0   turbine_rpm
  1   turbine_temperature_c
  2   turbine_pressure_bar
  3   line_voltage_a_v
  4   line_current_a_a
  5   line_voltage_b_v
  6   line_current_b_a
  7   frequency_hz_x10       e.g. 500 = 50.0 Hz
  8   power_kw
  9   oil_pressure_bar
  10  vibration_mm_s_x10
"""

import asyncio
import json
import logging
import os
import random
import struct

import paho.mqtt.client as mqtt

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusSlaveContext,
    ModbusServerContext,
)
from pymodbus.server import StartAsyncTcpServer
from pymodbus.client import AsyncModbusTcpClient

logging.basicConfig(level=logging.WARNING)

FUEL_VALVE_IP = os.environ.get("ACTUATOR_FUEL_VALVE_IP", '10.10.3.51')
COOLING_PUMP_IP = os.environ.get('ACTUATOR_COOLING_PUMP_IP', "10.10.3.52")
BREAKER_A_IP = os.environ.get('ACTUATOR_BREAKER_A_IP', "10.10.3.53")
BREAKER_B_IP = os.environ.get("ACTUATOR_BREAKER_B_IP", "10.10.3.54")
MQTT_BROKER_IP = os.environ.get('MQTT_BROKER_IP', "10.10.3.60")

# Function codes
FC_CO = 1  # coils
FC_HR = 3  # holding registers
FC_IR = 4  # input registers

# Coil addresses
COIL_ESTOP = 0
COIL_ALM_SPEED = 1
COIL_ALM_TEMP = 2
COIL_ALM_PRESS = 3
COIL_ALM_VOLT = 4
COIL_BREAKER_A = 5
COIL_BREAKER_B = 6

# Holding register addresses
HR_SETPOINT = 0
HR_FUEL_VALVE = 1
HR_COOLING = 2
HR_OC_THRESH = 3

# Input register addresses
IR_RPM = 0
IR_TEMP = 1
IR_PRESSURE = 2
IR_V_A = 3
IR_I_A = 4
IR_V_B = 5
IR_I_B = 6
IR_FREQ = 7
IR_POWER = 8
IR_OIL = 9
IR_VIB = 10

# Physics
RPM_NOM = 3000
RPM_MAX = 3600
RPM_TRIP = 3300
TEMP_NOM = 420
TEMP_COLD = 20
TEMP_TRIP = 490
PRESS_NOM = 85
PRESS_TRIP = 95
VOLT_NOM = 230
CURR_NOM = 150
FREQ_NOM = 50.0
KP = 0.8
DEFAULT_SP = 3000


def _make_store():
    # zero_mode=True so Modbus address N maps to block slot N; without it
    # pymodbus's 1-based offset shifts the init list (setpoint reads 0, cooling 200%).
    return ModbusSlaveContext(
        co=ModbusSequentialDataBlock(0, [0] * 20),
        di=ModbusSequentialDataBlock(0, [0] * 10),
        hr=ModbusSequentialDataBlock(0, [DEFAULT_SP, 0, 100, 200] + [0] * 16),
        ir=ModbusSequentialDataBlock(0, [0] * 20),
        zero_mode=True,
    )


async def physics_loop(store):
    """Turbine physics at 10 Hz. Startup ramp before entering steady loop."""
    state = {
        "rpm": 0.0, 'temp': float(TEMP_COLD),
        "pressure": 0.0, "oil": 0.0, "vib": 1.0
    }

    # Ramp fuel valve from 0 to 60% over ~30 s
    for pct in range(0, 61, 2):
        store.setValues(FC_HR, HR_FUEL_VALVE, [pct])
        await asyncio.sleep(1.0)

    while True:
        fuel = store.getValues(FC_HR, HR_FUEL_VALVE, count=1)[0] / 100.0
        cool = store.getValues(FC_HR, HR_COOLING,    count=1)[0] / 100.0
        ba = store.getValues(FC_CO, COIL_BREAKER_A, count=1)[0]
        bb = store.getValues(FC_CO, COIL_BREAKER_B, count=1)[0]
        estop = store.getValues(FC_CO, COIL_ESTOP,     count=1)[0]
        sp = store.getValues(FC_HR, HR_SETPOINT,    count=1)[0] or DEFAULT_SP

        if estop:
            fuel = 0.0

        rpm = state["rpm"]

        # raising setpoint HR[0] above RPM_NOM drives overspeed (attack path)
        steam = fuel * sp
        drag = (ba + bb) * 0.5 * rpm * 0.015
        rpm    += (steam - rpm) * 0.08 - drag * 0.05
        rpm = max(0.0, min(float(RPM_MAX), rpm + random.gauss(0, 5)))

        tload = (rpm / RPM_NOM) * fuel * (1.0 - cool * 0.3)
        t_tgt = TEMP_COLD + tload * (TEMP_NOM - TEMP_COLD)
        state["temp"] += (t_tgt - state["temp"]) * 0.02 + random.gauss(0, 0.5)

        state["pressure"] += (fuel * PRESS_NOM - state["pressure"]) * 0.15
        state['pressure']  = max(0.0, state['pressure'] + random.gauss(0, 0.3))

        state['oil'] += (cool * 8.0 - state['oil']) * 0.1
        state["oil"]  = max(0.0, state['oil'] + random.gauss(0, 0.05))

        dev = abs(rpm - RPM_NOM) / RPM_NOM if rpm > 0 else 0
        state["vib"] += (1.0 + dev * 15.0 - state["vib"]) * 0.05
        state["vib"]  = max(0.0, state["vib"] + random.gauss(0, 0.02))

        state["rpm"] = rpm

        frac = rpm / RPM_NOM
        freq = int(FREQ_NOM * frac * 10)
        v_a = max(0, int(VOLT_NOM * frac * ba  + random.gauss(0, 1)))
        v_b = max(0, int(VOLT_NOM * frac * bb  + random.gauss(0, 1)))
        i_a = max(0, int(frac * CURR_NOM * ba  * 0.5 + random.gauss(0, 0.5)))
        i_b = max(0, int(frac * CURR_NOM * bb  * 0.5 + random.gauss(0, 0.5)))
        n = ba + bb
        v_avg = (v_a * ba + v_b * bb) / n if n else 0
        power = max(0, int(v_avg * (i_a + i_b) * 0.95 / 1000))

        o_spd = rpm > RPM_TRIP
        o_tmp = state["temp"] > TEMP_TRIP
        o_prs = state["pressure"] > PRESS_TRIP
        u_vlt = (v_a < VOLT_NOM * 0.85 or v_b < VOLT_NOM * 0.85) and n > 0

        if o_spd or o_tmp or o_prs:
            store.setValues(FC_CO, COIL_ESTOP, [1])

        store.setValues(FC_CO, COIL_ALM_SPEED, [int(o_spd)])
        store.setValues(FC_CO, COIL_ALM_TEMP,  [int(o_tmp)])
        store.setValues(FC_CO, COIL_ALM_PRESS, [int(o_prs)])
        store.setValues(FC_CO, COIL_ALM_VOLT,  [int(u_vlt)])

        store.setValues(FC_IR, IR_RPM,      [max(0, int(rpm))])
        store.setValues(FC_IR, IR_TEMP,     [max(0, int(state["temp"]))])
        store.setValues(FC_IR, IR_PRESSURE, [max(0, int(state['pressure']))])
        store.setValues(FC_IR, IR_V_A,      [v_a])
        store.setValues(FC_IR, IR_I_A,      [i_a])
        store.setValues(FC_IR, IR_V_B,      [v_b])
        store.setValues(FC_IR, IR_I_B,      [i_b])
        store.setValues(FC_IR, IR_FREQ,     [freq])
        store.setValues(FC_IR, IR_POWER,    [power])
        store.setValues(FC_IR, IR_OIL,      [max(0, int(state["oil"]))])
        store.setValues(FC_IR, IR_VIB,      [max(0, int(state["vib"] * 10))])

        await asyncio.sleep(0.1)


async def governor_loop(store):
    """Proportional governor: adjusts fuel_valve to track governor_setpoint."""
    await asyncio.sleep(5.0)
    while True:
        estop = store.getValues(FC_CO, COIL_ESTOP, count=1)[0]
        if estop:
            store.setValues(FC_HR, HR_FUEL_VALVE, [0])
        else:
            sp = store.getValues(FC_HR, HR_SETPOINT,   count=1)[0] or DEFAULT_SP
            rpm = store.getValues(FC_IR, IR_RPM,         count=1)[0]
            cur = store.getValues(FC_HR, HR_FUEL_VALVE,  count=1)[0]
            err = sp - rpm
            new = max(0, min(100, int(cur + KP * (err / sp) * 10)))
            store.setValues(FC_HR, HR_FUEL_VALVE, [new])
        await asyncio.sleep(0.2)


async def _read_coil(ip, addr):
    try:
        client = AsyncModbusTcpClient(ip, port=502, timeout=2)
        await client.connect()
        r = await client.read_coils(addr, count=1, slave=1)
        client.close()  # pymodbus async close() is synchronous; do not await
        if not r.isError():
            return int(r.bits[0])
    except Exception:
        pass
    return 1  # default: breaker closed


async def actuator_sync_loop(store):
    """Poll breaker actuators; mirror their state into PLC coils."""
    await asyncio.sleep(15.0)
    while True:
        ba = await _read_coil(BREAKER_A_IP, 0)
        bb = await _read_coil(BREAKER_B_IP, 0)
        store.setValues(FC_CO, COIL_BREAKER_A, [ba])
        store.setValues(FC_CO, COIL_BREAKER_B, [bb])
        await asyncio.sleep(0.5)


_STARTDT_CON = bytes([0x68, 0x04, 0x0B, 0x00, 0x00, 0x00])
_TESTFR_CON = bytes([0x68, 0x04, 0x83, 0x00, 0x00, 0x00])


def _iec104_asdu(store, tx_seq: int) -> bytes:
    """Build a Type 9 (M_ME_NB_1) ASDU with RPM, temp, voltage, frequency."""
    rpm = store.getValues(FC_IR, IR_RPM,  count=1)[0]
    temp = store.getValues(FC_IR, IR_TEMP, count=1)[0]
    v_a = store.getValues(FC_IR, IR_V_A,  count=1)[0]
    freq = store.getValues(FC_IR, IR_FREQ, count=1)[0]

    # Each element: 2-byte normalized value (int16) + 1-byte quality
    elements = b""
    for val in [rpm, temp, v_a, freq]:
        # Normalize to -1.0..+1.0 range scaled to 0x0000..0x7FFF
        norm = min(0x7FFF, val * 10) & 0xFFFF
        elements += struct.pack('<H', norm) + b"\x00"

    # ASDU header: TypeID=9, VSQ=4 objects, COT=1 (periodic), OA=0, CA=1
    asdu = bytes([0x09, 0x04, 0x01, 0x00, 0x01, 0x00]) + \
           b"\x01\x00\x00" + elements  # IOA=1

    c1 = ((tx_seq & 0x7FFF) << 1) & 0xFF
    c2 = (tx_seq >> 7) & 0xFF
    apci = bytes([0x68, 4 + len(asdu), c1, c2, 0x00, 0x00])
    return apci + asdu


# FIXME: ASDU framing is minimal, not fully 60870-5-104 conformant
async def handle_iec104(reader, writer, store):
    tx_seq = 0
    try:
        # Send STARTDT_CON on connect; we always accept
        writer.write(_STARTDT_CON)
        await writer.drain()

        while True:
            hdr = await asyncio.wait_for(reader.read(6), timeout=30.0)
            if len(hdr) < 6 or hdr[0] != 0x68:
                break
            apdu_len = hdr[1]
            if apdu_len > 4:
                await reader.read(apdu_len - 4)  # consume ASDU if present

            c1 = hdr[2]
            # U-frame detection: bits [1:0] of c1 == 11
            if (c1 & 0x03) == 0x03:
                if c1 == 0x07:  # STARTDT_ACT
                    writer.write(_STARTDT_CON)
                elif c1 == 0x43: # TESTFR_ACT
                    writer.write(_TESTFR_CON)
                await writer.drain()
            else:
                # I-frame or S-frame: send data
                writer.write(_iec104_asdu(store, tx_seq))
                tx_seq = (tx_seq + 1) & 0x7FFF
                await writer.drain()

    except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def mqtt_publish_loop(store):
    """Publish turbine telemetry to uupl/turbine/telemetry every 5 s (anonymous, best-effort)."""
    client = mqtt.Client()
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.loop_start()
    try:
        client.connect(MQTT_BROKER_IP, 1883, keepalive=60)
    except Exception:
        pass  # loop_start retries in the background

    await asyncio.sleep(30.0)  # Wait for broker and physics to stabilise
    while True:
        try:
            payload = json.dumps({
                'rpm': store.getValues(FC_IR, IR_RPM,      count=1)[0],
                "temp_c": store.getValues(FC_IR, IR_TEMP,     count=1)[0],
                "pressure": store.getValues(FC_IR, IR_PRESSURE, count=1)[0],
                "voltage_a": store.getValues(FC_IR, IR_V_A,      count=1)[0],
                "voltage_b": store.getValues(FC_IR, IR_V_B,      count=1)[0],
                "current_a": store.getValues(FC_IR, IR_I_A,      count=1)[0],
                "current_b": store.getValues(FC_IR, IR_I_B,      count=1)[0],
                'freq_x10': store.getValues(FC_IR, IR_FREQ,     count=1)[0],
                'power_kw': store.getValues(FC_IR, IR_POWER,    count=1)[0],
                "estop": store.getValues(FC_CO, COIL_ESTOP,  count=1)[0]
            })
            client.publish("uupl/turbine/telemetry", payload, qos=0)
        except Exception:
            pass
        await asyncio.sleep(5.0)


async def main():
    store = _make_store()
    context = ModbusServerContext(slaves=store, single=True)

    store.setValues(FC_CO, COIL_ESTOP,    [0])
    store.setValues(FC_CO, COIL_BREAKER_A, [1])
    store.setValues(FC_CO, COIL_BREAKER_B, [1])

    # Push HR values to the actuator containers so attackers reading them see live state.
    async def push_fuel_valve():
        await asyncio.sleep(20.0)
        while True:
            try:
                val = store.getValues(FC_HR, HR_FUEL_VALVE, count=1)[0]
                c = AsyncModbusTcpClient(FUEL_VALVE_IP, port=502, timeout=2)
                await c.connect()
                await c.write_register(0, val, slave=1)
                c.close()  # pymodbus async close() is synchronous; do not await
            except Exception:
                pass
            await asyncio.sleep(1.0)

    async def push_cooling_pump():
        await asyncio.sleep(20.0)
        while True:
            try:
                val = store.getValues(FC_HR, HR_COOLING, count=1)[0]
                c = AsyncModbusTcpClient(COOLING_PUMP_IP, port=502, timeout=2)
                await c.connect()
                await c.write_register(0, val, slave=1)
                c.close()  # pymodbus async close() is synchronous; do not await
            except Exception:
                pass
            await asyncio.sleep(1.0)

    iec104_server = await asyncio.start_server(
        lambda r, w: handle_iec104(r, w, store), "0.0.0.0", 2404)

    async with iec104_server:
        await asyncio.gather(
            StartAsyncTcpServer(context=context, address=('0.0.0.0', 502)),
            physics_loop(store),
            governor_loop(store),
            actuator_sync_loop(store),
            push_fuel_valve(),
            push_cooling_pump(),
            mqtt_publish_loop(store),
            iec104_server.serve_forever(),
        )


if __name__ == "__main__":
    asyncio.run(main())
