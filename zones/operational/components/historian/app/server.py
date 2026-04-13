"""
UU P&L Process Historian — web interface
Installed to serve report requests from the operations floor.

The report endpoint accepts an asset name and date range, queries the
time-series database, and returns the results as CSV. The query is built
with string formatting because "it was quicker and the network is internal."
"""

import os
import functools
import sqlite3
from flask import Flask, request, Response, abort

app = Flask(__name__)
DB_PATH    = os.environ.get("DB_PATH",    "/opt/historian/data/historian.db")
EXPORT_DIR = os.environ.get("EXPORT_DIR", "/opt/historian/data/exports")

# Credentials for the data-push ingest endpoint.
# Documented in the SCADA server connection config (/config on scada-server).
INGEST_USER = "hist_read"
INGEST_PASS = "history2017"


def _require_ingest_auth(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or auth.username != INGEST_USER or auth.password != INGEST_PASS:
            return Response(
                "Authorisation required.",
                401,
                {"WWW-Authenticate": 'Basic realm="UU P&L Historian Ingest"'},
            )
        return f(*args, **kwargs)
    return decorated


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


@app.route("/")
def index():
    return (
        "<html><body>"
        "<h2>UU P&L Process Historian</h2>"
        "<p>Authorised users only. "
        "See <a href='/report'>/report</a> for data access.</p>"
        "<p><small>v1.4 — Hex Computing Division</small></p>"
        "</body></html>"
    )


@app.route("/report")
def report():
    """
    Returns time-series data for a given asset and date range.

    Parameters:
        asset  — asset name as stored in the readings table
        from   — start date (YYYY-MM-DD)
        to     — end date (YYYY-MM-DD)

    The asset parameter is interpolated directly into the SQL query.
    The database is internal-only, so input sanitisation was not considered
    a priority at time of implementation.
    """
    asset = request.args.get("asset", "")
    from_date = request.args.get("from", "2024-01-01")
    to_date = request.args.get("to", "2024-12-31")

    if not asset:
        return "asset parameter required", 400

    db = get_db()
    try:
        # Direct string interpolation — "it's just internal reporting"
        query = (
            f"SELECT timestamp, value, unit FROM readings "
            f"WHERE asset = '{asset}' "
            f"AND timestamp BETWEEN '{from_date}' AND '{to_date}' "
            f"ORDER BY timestamp ASC"
        )
        rows = db.execute(query).fetchall()
    except sqlite3.OperationalError as e:
        # The error message is returned verbatim.
        # "Helps with debugging when something goes wrong."
        return f"Query error: {e}", 500
    finally:
        db.close()

    lines = ["timestamp,value,unit"]
    for row in rows:
        lines.append(f"{row['timestamp']},{row['value']},{row['unit']}")

    return Response("\n".join(lines), mimetype="text/csv")


@app.route("/assets")
def assets():
    """Lists all known asset names. Used by the report generation script."""
    db = get_db()
    try:
        rows = db.execute("SELECT DISTINCT asset FROM readings ORDER BY asset").fetchall()
    finally:
        db.close()
    names = [row["asset"] for row in rows]
    return "\n".join(names)


@app.route("/status")
def status():
    """Basic health check used by the SCADA server."""
    try:
        db = get_db()
        count = db.execute("SELECT COUNT(*) FROM readings").fetchone()[0]
        db.close()
        return {"status": "ok", "readings": count}
    except Exception as e:
        return {"status": "error", "detail": str(e)}, 500


@app.route("/export")
def export():
    """
    Serves pre-generated CSV export files for downstream consumers.
    The tag parameter is the filename to serve from the exports directory.
    Used by the nightly report cron job on uupl-eng-ws.

    The path is constructed by joining EXPORT_DIR with the tag parameter.
    Input is not sanitised — "it's an internal reporting endpoint."
    """
    tag = request.args.get("tag", "")
    if not tag:
        return "tag parameter required", 400
    path = os.path.join(EXPORT_DIR, tag)
    try:
        with open(path) as f:
            content = f.read()
        return Response(content, mimetype="text/csv")
    except FileNotFoundError:
        return f"no export for tag: {tag}", 404
    except PermissionError:
        return "access denied", 403
    except Exception as e:
        return f"error: {e}", 500


@app.route("/ingest", methods=["POST"])
@_require_ingest_auth
def ingest():
    """
    Data push endpoint for remote RTU feeds.
    Added 2019-04-07 to support city substation data ingestion.

    Accepts JSON: {"timestamp": "...", "asset": "...", "value": 0.0, "unit": "..."}
    Writes directly to the readings table. No validation of asset names or values.
    Ticket HEX-2847 (add input validation) was closed as won't-fix 2020-03-18.
    """
    data = request.get_json(silent=True)
    if not data:
        return "expected JSON body: {timestamp, asset, value, unit}", 400
    missing = [k for k in ("timestamp", "asset", "value", "unit") if k not in data]
    if missing:
        return f"missing fields: {missing}", 400
    db = get_db()
    try:
        db.execute(
            "INSERT INTO readings (timestamp, asset, value, unit) VALUES (?, ?, ?, ?)",
            (data["timestamp"], data["asset"], float(data["value"]), data["unit"]),
        )
        db.commit()
        return "ok"
    except Exception as e:
        return f"error: {e}", 500
    finally:
        db.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)