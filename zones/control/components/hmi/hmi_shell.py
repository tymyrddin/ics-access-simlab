#!/usr/bin/env python3
"""
UU P&L Hex Turbine Control System — Operator Terminal
Hex Computing Division HMI v2.3.1

This script is the login shell for the 'operator' account.
Connects to the PLC via Modbus and presents an interactive operator interface.
"""

import os
import sys
import time

from pymodbus.client import ModbusTcpClient

PLC_IP    = os.environ.get("PLC_IP", "10.10.3.21")
RELAY_A   = "10.10.3.31"
RELAY_B   = "10.10.3.32"
METER_IP  = "10.10.3.33"

# ANSI
R  = "\033[31m"
G  = "\033[32m"
Y  = "\033[33m"
C  = "\033[36m"
B  = "\033[1m"
RS = "\033[0m"

FC_CO = 1
FC_HR = 3
FC_IR = 4


def _plc():
    return ModbusTcpClient(PLC_IP, port=502, timeout=2)


def read_state():
    s = {}
    try:
        with _plc() as c:
            if not c.connect():
                return None
            ir = c.read_input_registers(0, 11, slave=1)
            hr = c.read_holding_registers(0, 4,  slave=1)
            co = c.read_coils(0, 7,               slave=1)
            if not ir.isError():
                r = ir.registers
                s.update({
                    "rpm": r[0], "temp": r[1], "pressure": r[2],
                    "v_a": r[3], "i_a": r[4], "v_b": r[5], "i_b": r[6],
                    "freq": r[7] / 10.0, "power": r[8],
                    "oil": r[9], "vib": r[10] / 10.0,
                })
            if not hr.isError():
                h = hr.registers
                s.update({"setpoint": h[0], "fuel": h[1], "cooling": h[2], "oc_thresh": h[3]})
            if not co.isError():
                b = co.bits
                s.update({
                    "estop": b[0], "alm_speed": b[1], "alm_temp": b[2],
                    "alm_press": b[3], "alm_volt": b[4],
                    "breaker_a": b[5], "breaker_b": b[6],
                })
    except Exception:
        return None
    return s


def render(s):
    os.system("clear")
    print(f"{B}╔══════════════════════════════════════════════════════════════╗{RS}")
    print(f"{B}║  UU P&L HEX TURBINE CONTROL SYSTEM  —  OPERATOR TERMINAL    ║{RS}")
    print(f"{B}║  Hex Computing Division HMI v2.3.1   {C}10.10.3.10{RS}{B}             ║{RS}")
    print(f"{B}╠══════════════════════════════════════════════════════════════╣{RS}")

    if s is None:
        print(f"{B}║  {R}** PLC OFFLINE — CANNOT REACH {PLC_IP} **{RS}{B}               ║{RS}")
        print(f"{B}╚══════════════════════════════════════════════════════════════╝{RS}")
        return

    def ac(flag):
        return R if flag else G

    state_str  = f"{R}** EMERGENCY STOP **{RS}" if s.get("estop") else f"{G}RUNNING{RS}"
    rpm_c      = R if s.get("alm_speed") else (Y if s.get("rpm", 0) < 2800 else G)
    temp_c     = R if s.get("alm_temp")  else G
    press_c    = R if s.get("alm_press") else G
    ba_s       = f"{G}CLOSED{RS}" if s.get("breaker_a") else f"{R}OPEN{RS}"
    bb_s       = f"{G}CLOSED{RS}" if s.get("breaker_b") else f"{R}OPEN{RS}"

    print(f"{B}║  TURBINE: {state_str}{B:<52}║{RS}")
    print(f"{B}║                                                              ║{RS}")
    print(f"{B}║  SPEED     {rpm_c}{s.get('rpm','---'):>5}{RS}{B} RPM   SETPOINT: {s.get('setpoint','---'):>4} RPM           ║{RS}")
    print(f"{B}║  TEMP      {temp_c}{s.get('temp','---'):>5}{RS}{B} °C    FUEL VALVE: {s.get('fuel','---'):>3}%             ║{RS}")
    print(f"{B}║  PRESSURE  {press_c}{s.get('pressure','---'):>5}{RS}{B} bar   COOLING: {s.get('cooling','---'):>3}%               ║{RS}")
    print(f"{B}║  FREQUENCY {s.get('freq',0.0):>7.1f} Hz   OIL: {s.get('oil','---'):>2} bar   VIB: {s.get('vib',0.0):.1f} mm/s ║{RS}")
    print(f"{B}║  OUTPUT    {s.get('power','---'):>4} kW                                        ║{RS}")
    print(f"{B}╠══════════════════════════════════════════════════════════════╣{RS}")
    print(f"{B}║  FEEDER A: {s.get('v_a','---'):>4}V  {s.get('i_a','---'):>4}A   BREAKER: {ba_s}{B:<31}║{RS}")
    print(f"{B}║  FEEDER B: {s.get('v_b','---'):>4}V  {s.get('i_b','---'):>4}A   BREAKER: {bb_s}{B:<31}║{RS}")

    alarms = []
    if s.get("alm_speed"): alarms.append("OVERSPEED")
    if s.get("alm_temp"):  alarms.append("OVERTEMP")
    if s.get("alm_press"): alarms.append("OVERPRESSURE")
    if s.get("alm_volt"):  alarms.append("UNDERVOLTAGE")
    alm_s = f"{R}{'  '.join(alarms)}{RS}" if alarms else f"{G}NONE{RS}"

    print(f"{B}╠══════════════════════════════════════════════════════════════╣{RS}")
    print(f"{B}║  ALARMS: {alm_s}{B:<52}║{RS}")
    print(f"{B}╠══════════════════════════════════════════════════════════════╣{RS}")
    print(f"{B}║  setpoint <rpm>  estop  reset  fuel <0-100>  help  exit      ║{RS}")
    print(f"{B}╚══════════════════════════════════════════════════════════════╝{RS}")


def cmd_setpoint(args):
    if not args:
        print("Usage: setpoint <rpm>")
        return
    try:
        sp = max(0, min(3600, int(args[0])))
        with _plc() as c:
            if c.connect():
                c.write_register(0, sp, slave=1)
                print(f"Setpoint → {sp} RPM")
    except Exception as e:
        print(f"Error: {e}")


def cmd_fuel(args):
    if not args:
        print("Usage: fuel <0-100>")
        return
    try:
        pct = max(0, min(100, int(args[0])))
        with _plc() as c:
            if c.connect():
                c.write_register(1, pct, slave=1)
                print(f"Fuel valve → {pct}%")
    except Exception as e:
        print(f"Error: {e}")


def cmd_estop(_):
    try:
        with _plc() as c:
            if c.connect():
                c.write_coil(0, True, slave=1)
                print(f"{R}Emergency stop activated.{RS}")
    except Exception as e:
        print(f"Error: {e}")


def cmd_reset(_):
    try:
        with _plc() as c:
            if c.connect():
                c.write_coil(0, False, slave=1)
                print(f"{G}Emergency stop cleared.{RS}")
    except Exception as e:
        print(f"Error: {e}")


HELP = f"""
{B}Commands:{RS}
  setpoint <rpm>   set governor setpoint (0-3600)
  fuel <0-100>     set fuel valve position directly
  estop            activate emergency stop (trips turbine)
  reset            clear emergency stop flag
  help             show this help
  exit / quit      disconnect
"""


def main():
    print(f"\n{B}UU P&L Hex Turbine Control System{RS}")
    print("Hex Computing Division HMI v2.3.1")
    print(f"Connecting to PLC at {PLC_IP}...\n")
    time.sleep(1)

    refresh_interval = 3.0
    last_refresh = 0.0
    state = None

    while True:
        now = time.monotonic()
        if now - last_refresh >= refresh_interval:
            state = read_state()
            render(state)
            last_refresh = now

        try:
            sys.stdout.write(f"\n{C}HMI>{RS} ")
            sys.stdout.flush()
            line = sys.stdin.readline()
            if not line:
                break
            parts = line.strip().split()
            if not parts:
                continue
            cmd, *args = parts
            cmd = cmd.lower()

            if cmd in ("exit", "quit", "logout"):
                print("Disconnecting.")
                break
            elif cmd == "setpoint":
                cmd_setpoint(args)
            elif cmd == "fuel":
                cmd_fuel(args)
            elif cmd == "estop":
                cmd_estop(args)
            elif cmd == "reset":
                cmd_reset(args)
            elif cmd == "help":
                print(HELP)
            else:
                print(f"Unknown command: {cmd}. Type 'help' for commands.")

        except (EOFError, KeyboardInterrupt):
            print("\nDisconnecting.")
            break

    sys.exit(0)


if __name__ == "__main__":
    main()
