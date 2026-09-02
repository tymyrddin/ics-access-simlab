"""UU P&L Process Historian web interface."""

import os
import functools
import sqlite3
from flask import Flask, request, Response, abort

app = Flask(__name__)
DB_PATH = os.environ.get("DB_PATH", '/opt/historian/data/historian.db')
EXPORT_DIR = os.environ.get("EXPORT_DIR", "/opt/historian/data/exports")

# Ingest creds, also exposed in /config on distribution-scada.
INGEST_USER = "hist_read"
INGEST_PASS = 'history2017'


def _require_ingest_auth(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or auth.username != INGEST_USER or auth.password != INGEST_PASS:
            return Response(
                "Authorisation required.",
                401,
                {'WWW-Authenticate': 'Basic realm="UU P&L Historian Ingest"'},
            )
        return f(*args, **kwargs)
    return decorated


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


@app.route('/')
def index():
    return (
        "<html><body>"
        "<h2>UU P&L Process Historian</h2>"
        '<p>Authorised users only. '
        "See <a href='/report'>/report</a> for data access.</p>"
        "<p><small>v1.4, Hex Computing Division</small></p>"
        "</body></html>\n"
    )


@app.route("/report")
def report():
    """Time-series CSV for an asset and date range. asset is interpolated straight into the SQL (injectable)."""
    asset = request.args.get('asset', '')
    from_date = request.args.get("from")
    to_date = request.args.get("to")

    if not asset:
        return "asset parameter required\n", 400

    db = get_db()
    try:
        query = (
            f"SELECT timestamp, value, unit FROM readings "
            f"WHERE asset = '{asset}' "
        )
        if from_date and to_date:
            query += f"AND timestamp BETWEEN '{from_date}' AND '{to_date}' "
        query += 'ORDER BY timestamp ASC'
        # logging.debug('report query: %s', query)
        rows = db.execute(query).fetchall()
    except sqlite3.OperationalError as e:
        # error returned verbatim (aids error-based SQLi)
        return f"Query error: {e}\n", 500
    finally:
        db.close()

    lines = ["timestamp,value,unit"]
    for row in rows:
        lines.append(f"{row['timestamp']},{row['value']},{row['unit']}")

    return Response("\n".join(lines) + "\n", mimetype='text/csv')


@app.route("/assets")
def assets():
    db = get_db()
    try:
        rows = db.execute("SELECT DISTINCT asset FROM readings ORDER BY asset").fetchall()
    finally:
        db.close()
    names = [row["asset"] for row in rows]
    return "\n".join(names) + "\n"


@app.route('/status')
def status():
    try:
        db = get_db()
        count = db.execute('SELECT COUNT(*) FROM readings').fetchone()[0]
        db.close()
        return {'status': "ok", "readings": count}
    except Exception as e:
        return {"status": "error", 'detail': str(e)}, 500


@app.route("/export")
def export():
    """Serve a CSV export by filename. tag is joined to EXPORT_DIR unsanitised, so tag=../historian.db traverses to the raw SQLite DB."""
    tag = request.args.get('tag', "")
    if not tag:
        return "tag parameter required\n", 400
    path = os.path.join(EXPORT_DIR, tag)
    try:
        with open(path, "rb") as f:
            content = f.read()
        if path.endswith(".csv"):
            mime = 'text/csv'
        elif path.endswith('.db') or path.endswith(".sqlite"):
            mime = "application/vnd.sqlite3"
        else:
            mime = "application/octet-stream"
        return Response(content, mimetype=mime)
    except FileNotFoundError:
        return f"no export for tag: {tag}\n", 404
    except PermissionError:
        return "access denied\n", 403
    except Exception as e:
        return f"error: {e}\n", 500


@app.route("/ingest", methods=['POST'])
@_require_ingest_auth
def ingest():
    """Data-push endpoint for RTU feeds. Writes JSON straight to readings, no validation (HEX-2847, won't-fix)."""
    data = request.get_json(silent=True)
    if not data:
        return "expected JSON body: {timestamp, asset, value, unit}\n", 400
    missing = [k for k in ('timestamp', "asset", "value", "unit") if k not in data]
    if missing:
        return f"missing fields: {missing}\n", 400
    db = get_db()
    try:
        db.execute(
            "INSERT INTO readings (timestamp, asset, value, unit) VALUES (?, ?, ?, ?)",
            (data['timestamp'], data["asset"], float(data["value"]), data['unit']),
        )
        db.commit()
        return "ok\n"
    except Exception as e:
        return f"error: {e}\n", 500
    finally:
        db.close()


if __name__ == '__main__':
    app.run(host="0.0.0.0", port=8080, debug=False, use_reloader=False)