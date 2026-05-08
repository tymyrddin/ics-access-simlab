"""
UU P&L substation RTU. Serves the Dolly Sisters / Nap Hill feeder segment.

Two interfaces, both deliberately permissive:

  :2404  IEC 60870-5-104 protocol (no auth, default for the standard)
  :8080  REST management API (no auth, for the operator's "engineer's PC")

Both surfaces share the same in-memory datapoint table. A POST to
/datapoints/<id> updates the table; the IEC-104 server picks up the new
value on the next periodic report. The vendor management UI mutating values
behind the protocol is a real pattern: many substation RTUs ship a web
configurator that engineers use during commissioning, then forget to firewall.
"""

import json
import threading
import logging
from pathlib import Path

import c104
from flask import Flask, jsonify, request, abort


CONFIG_PATH = Path("/app/rtu_config.json")
COMMON_ADDRESS = 20  # IEC-104 ASDU common address used by all datapoints

# c104.Type maps to the IEC-104 type IDs the runbook references:
#   M_ME_NC_1 (type 13): measured value, short floating point
#   M_SP_NA_1 (type 1):  single-point information (boolean)
TYPE_MAP = {
    13: c104.Type.M_ME_NC_1,
    1:  c104.Type.M_SP_NA_1,
}


def load_config():
    return json.loads(CONFIG_PATH.read_text())


# Shared state. DATAPOINTS holds the dict the REST API serves; POINTS_BY_ID
# holds the live c104.Point objects so a REST write can also push the value
# spontaneously over IEC-104. Both are guarded by STATE_LOCK.
DATAPOINTS = {}
POINTS_BY_ID = {}
STATE_LOCK = threading.Lock()


def _coerce(type_id, raw):
    """Normalise a JSON value to the type the IEC-104 point expects."""
    if type_id == 1:
        if isinstance(raw, bool):
            return raw
        if isinstance(raw, str):
            return raw.lower() in ("true", "1", "yes", "on")
        return bool(raw)
    return float(raw)


# ── REST API ──────────────────────────────────────────────────────────────────

app = Flask(__name__)
app.logger.setLevel(logging.INFO)


@app.route("/")
def index():
    return jsonify({
        "rtu":   "uupl-substation",
        "feeder": "Dolly Sisters / Nap Hill",
        "endpoints": [
            "GET  /datapoints         list all",
            "GET  /datapoints/<id>    read one",
            "POST /datapoints/<id>    write one (body: {\"value\": ...})",
        ],
    })


@app.route("/datapoints", methods=["GET"])
def list_datapoints():
    with STATE_LOCK:
        return jsonify(list(DATAPOINTS.values()))


@app.route("/datapoints/<int:dpid>", methods=["GET"])
def get_datapoint(dpid):
    with STATE_LOCK:
        dp = DATAPOINTS.get(dpid)
    if dp is None:
        abort(404, description=f"no datapoint with id {dpid}")
    return jsonify(dp)


@app.route("/datapoints/<int:dpid>", methods=["POST"])
def write_datapoint(dpid):
    body = request.get_json(silent=True) or {}
    if "value" not in body:
        abort(400, description="body needs a 'value' field")

    with STATE_LOCK:
        dp = DATAPOINTS.get(dpid)
        if dp is None:
            abort(404, description=f"no datapoint with id {dpid}")
        new_value = _coerce(dp["type"], body["value"])
        dp["value"] = new_value
        point = POINTS_BY_ID.get(dpid)

    if point is not None:
        try:
            point.value = new_value
            point.transmit(cause=c104.Cot.SPONTANEOUS)
        except Exception as exc:
            app.logger.warning("transmit failed for dp %s: %s", dpid, exc)

    return jsonify({"status": "ok", "id": dpid, "value": new_value})


# ── IEC-104 server ────────────────────────────────────────────────────────────

def start_iec104_server(config):
    server = c104.Server(ip="0.0.0.0", port=2404)
    station = server.add_station(common_address=COMMON_ADDRESS)

    for dp in config["datapoints"]:
        c104_type = TYPE_MAP[dp["type"]]
        point = station.add_point(
            io_address=dp["id"],
            type=c104_type,
            report_ms=10000,
        )
        point.value = _coerce(dp["type"], dp["value"])
        with STATE_LOCK:
            DATAPOINTS[dp["id"]] = dict(dp)
            POINTS_BY_ID[dp["id"]] = point

    server.start()
    return server


def main():
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=logging.INFO,
    )
    config = load_config()
    server = start_iec104_server(config)
    app.logger.info(
        "RTU up: IEC-104 :2404 (CA=%d), REST :8080 with %d datapoints",
        COMMON_ADDRESS, len(DATAPOINTS),
    )
    try:
        app.run(host="0.0.0.0", port=8080, threaded=True)
    finally:
        server.stop()


if __name__ == "__main__":
    main()