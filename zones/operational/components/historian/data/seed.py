"""
Database seeder for the UU P&L historian.

Creates the readings table and populates it with plausible time-series data
for the selected ICS process. The data reflects normal operational ranges
so that anomalies caused by OT manipulation are visible in historian queries.

Usage:
    python3 seed.py <ics_process> <db_path>
"""

import sys
import sqlite3
import random
from datetime import datetime, timedelta

ICS_ASSETS = {
    # UU P&L IED network — Hex Steam Turbine + protective relay IEDs.
    # Asset names match the HIL physical_values and IED register names in
    # zones/control/config/uupl_ied/. Normal operating ranges derived from
    # turbine_hil.py constants: RPM_NOMINAL=3000, TEMP_NOMINAL=420, PRESSURE_NOMINAL=85,
    # VOLTAGE_NOMINAL=230, CURRENT_NOMINAL=150 (split ~50/50 across two feeders).
    "uupl_ied": [
        ("turbine_rpm",          "RPM",  3000.0, 50.0),
        ("turbine_temperature",  "C",    420.0,  10.0),
        ("turbine_pressure",     "bar",  85.0,   2.0),
        ("line_voltage_a",       "V",    230.0,  2.0),
        ("line_current_a",       "A",    75.0,   3.0),   # ~half of CURRENT_NOMINAL
        ("line_voltage_b",       "V",    230.0,  2.0),
        ("line_current_b",       "A",    75.0,   3.0),
        ("meter_power_kw",       "kW",   16.0,   1.5),   # V×I×PF/1000 ≈ 16 kW
        ("relay_a_trip",         "bool", 0.0,    0.0),   # 0 = closed (normal)
        ("relay_b_trip",         "bool", 0.0,    0.0),
    ],
    "intelligent_electronic_device": [
        ("ied_voltage_l1",       "V",    220.0, 2.0),
        ("ied_voltage_l2",       "V",    220.0, 2.0),
        ("ied_voltage_l3",       "V",    220.0, 2.0),
        ("ied_current_l1",       "A",    15.0,  1.0),
        ("ied_frequency",        "Hz",   50.0,  0.1),
        ("turbine_rpm",          "RPM",  3000.0, 50.0),
        ("turbine_temp",         "C",    420.0, 10.0),
        ("turbine_pressure",     "bar",  85.0,  2.0),
        ("distribution_load",    "kW",   450.0, 30.0),
    ],
    "water_bottle_factory": [
        ("tank_level",           "mm",   800.0, 20.0),
        ("input_valve_state",    "bool", 1.0,   0.0),
        ("output_valve_state",   "bool", 0.0,   0.0),
        ("conveyor_speed",       "rpm",  60.0,  3.0),
        ("fill_count",           "units",0.0,   0.0),
        ("water_temperature",    "C",    18.0,  1.0),
    ],
    "smart_grid": [
        ("solar_output",         "kW",   120.0, 30.0),
        ("grid_frequency",       "Hz",   50.0,  0.05),
        ("battery_soc",          "pct",  72.0,  5.0),
        ("load_demand",          "kW",   98.0,  15.0),
        ("ats_position",         "bool", 1.0,   0.0),
    ],
}


def seed(ics_process: str, db_path: str) -> None:
    assets = ICS_ASSETS.get(ics_process)
    if assets is None:
        print(f"Unknown ICS process: {ics_process!r}. Using uupl_ied defaults.")
        assets = ICS_ASSETS["uupl_ied"]

    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS readings (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT    NOT NULL,
            asset     TEXT    NOT NULL,
            value     REAL    NOT NULL,
            unit      TEXT    NOT NULL
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_asset_ts ON readings(asset, timestamp)")

    # Also store the DB credentials in the config table.
    # They have always been here. The password has never been rotated.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS config (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
    """)
    conn.execute("INSERT OR IGNORE INTO config VALUES ('db_version', '1.4')")
    conn.execute("INSERT OR IGNORE INTO config VALUES ('db_user',    'historian')")
    conn.execute("INSERT OR IGNORE INTO config VALUES ('db_pass',    'Historian2015')")
    conn.execute("INSERT OR IGNORE INTO config VALUES ('installed',  '1997-03-22')")
    conn.execute("INSERT OR IGNORE INTO config VALUES ('contact',    'ponder.stibbons@uupl.am')")

    # Alarm setpoints stored by historian since 2003.
    # Used by the alarm display and cross-referenced by the SCADA server.
    # Values match the trip thresholds baked into relay_server.py and plc_server.py.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS alarm_config (
            tag     TEXT PRIMARY KEY,
            lo_lo   REAL,
            lo      REAL,
            hi      REAL,
            hi_hi   REAL,
            unit    TEXT,
            notes   TEXT
        )
    """)
    conn.executemany(
        "INSERT OR IGNORE INTO alarm_config VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            ("turbine_rpm",         2700.0, 2850.0, 3150.0, 3300.0, "RPM", "Overspeed trip at hi_hi (coil 1 on PLC)"),
            ("turbine_temperature",  380.0,  400.0,  460.0,  490.0, "C",   "Overtemp trip at hi_hi (coil 2 on PLC)"),
            ("turbine_pressure",      70.0,   78.0,   90.0,   95.0, "bar", "Overpressure trip at hi_hi"),
            ("line_voltage_a",       184.0,  196.0,  253.0,  264.0, "V",   "Relay HR[0]=undervoltage threshold (default 196)"),
            ("line_voltage_b",       184.0,  196.0,  253.0,  264.0, "V",   "Relay HR[0]=undervoltage threshold (default 196)"),
            ("line_current_a",         0.0,    0.0,  180.0,  200.0, "A",   "Relay HR[1]=overcurrent threshold (default 200)"),
            ("line_current_b",         0.0,    0.0,  180.0,  200.0, "A",   "Relay HR[1]=overcurrent threshold (default 200)"),
        ],
    )

    # 30 days of readings at 1-minute intervals
    now = datetime.utcnow()
    start = now - timedelta(days=30)
    rows = []
    t = start
    while t <= now:
        ts = t.strftime("%Y-%m-%dT%H:%M:%S")
        for asset, unit, mean, noise in assets:
            val = round(mean + random.gauss(0, noise), 4)
            rows.append((ts, asset, val, unit))
        t += timedelta(minutes=1)

    conn.executemany(
        "INSERT INTO readings (timestamp, asset, value, unit) VALUES (?, ?, ?, ?)",
        rows,
    )
    conn.commit()
    conn.close()
    print(f"[seed] Inserted {len(rows)} readings for {ics_process} into {db_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <ics_process> <db_path>")
        sys.exit(1)
    seed(sys.argv[1], sys.argv[2])