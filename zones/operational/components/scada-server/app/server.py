"""
UU P&L Distribution SCADA — operator dashboard

Pulls current plant state from the historian and displays it.
Protected by HTTP Basic Auth. Credentials: admin / admin.

The authentication was added after the Patrician's office asked whether
the power grid status page "really needed to be on the network like that."
The password was set by whoever had time to do it. It was not changed.
"""

import os
import functools
import requests
from flask import Flask, request, Response, render_template_string

app = Flask(__name__)
HISTORIAN_IP  = os.environ.get("HISTORIAN_IP", "10.10.2.10")
HISTORIAN_URL = f"http://{HISTORIAN_IP}:8080"

# Credentials. Set at installation. Documented nowhere except
# the ops-access.conf on the Bursar's workstation.
WEB_USER = "admin"
WEB_PASS = "admin"


def require_auth(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or auth.username != WEB_USER or auth.password != WEB_PASS:
            return Response(
                "Authorisation required.",
                401,
                {"WWW-Authenticate": 'Basic realm="UU P&L SCADA"'},
            )
        return f(*args, **kwargs)
    return decorated


@app.route("/")
@require_auth
def dashboard():
    # Pull asset list from historian
    try:
        assets_resp = requests.get(f"{HISTORIAN_URL}/assets", timeout=3)
        assets = assets_resp.text.strip().splitlines()
    except Exception:
        assets = ["(historian unreachable)"]

    # Pull the latest reading for each asset
    status_rows = []
    for asset in assets[:20]:  # cap to avoid a wall of data
        try:
            resp = requests.get(
                f"{HISTORIAN_URL}/report",
                params={"asset": asset, "from": "2024-01-01", "to": "2099-01-01"},
                timeout=3,
            )
            lines = resp.text.strip().splitlines()
            if len(lines) >= 2:
                last = lines[-1].split(",")
                status_rows.append({
                    "asset": asset,
                    "timestamp": last[0],
                    "value": last[1],
                    "unit": last[2] if len(last) > 2 else "",
                })
        except Exception:
            status_rows.append({"asset": asset, "timestamp": "—", "value": "error", "unit": ""})

    return render_template_string(DASHBOARD_TEMPLATE, rows=status_rows, historian=HISTORIAN_IP)


DASHBOARD_TEMPLATE = """
<!DOCTYPE html>
<html>
<head><title>UU P&L Distribution SCADA</title></head>
<body>
<h2>Unseen University Power &amp; Light Co.</h2>
<h3>City-Wide Distribution — Operator Dashboard</h3>
<p>Historian: {{ historian }} &nbsp;|&nbsp;
   <a href="/historian-pass">historian credentials</a></p>
<table border="1" cellpadding="4">
  <tr><th>Asset</th><th>Last Value</th><th>Unit</th><th>Timestamp</th></tr>
  {% for row in rows %}
  <tr>
    <td>{{ row.asset }}</td>
    <td>{{ row.value }}</td>
    <td>{{ row.unit }}</td>
    <td>{{ row.timestamp }}</td>
  </tr>
  {% endfor %}
</table>
<p><small>UU P&L SCADA v2.1 — Hex Computing Division</small></p>
</body>
</html>
"""


@app.after_request
def add_version_header(response):
    response.headers["X-Powered-By"] = "UU-SCADA/2.1 Flask/2.3 Python/3.11"
    return response


@app.route("/config")
@require_auth
def config_dump():
    """
    Connection configuration dump for the monitoring agent integration.
    Added 2021-08-14. Was supposed to be removed after commissioning.
    Access requires the same credentials as the operator dashboard.

    Contains historian read credentials and alarm SMTP relay settings.
    """
    return Response(
        "# UU P&L SCADA — Connection Configuration\n"
        "# Written: 2021-08-14  Author: I. Devious, Hex IT\n"
        "# DO NOT DISTRIBUTE — contains service credentials\n"
        "\n"
        f"[historian]\n"
        f"host     = {HISTORIAN_IP}\n"
        "port     = 8080\n"
        "user     = hist_read\n"
        "password = history2017\n"
        "\n"
        "[alarm_smtp]\n"
        "host     = mail.uu.am\n"
        "port     = 587\n"
        "user     = alarms@uupl.am\n"
        "password = plantmail123\n"
        "\n"
        f"[scada]\n"
        f"web_user = {WEB_USER}\n"
        f"web_pass = {WEB_PASS}\n"
        "alarm_script = /opt/scada/scripts/send_alarm.sh\n",
        mimetype="text/plain",
    )


@app.route("/historian-pass")
@require_auth
def historian_pass():
    """
    Added by Ponder so he wouldn't have to look up the historian
    password every time someone called asking why reports weren't working.
    The route was never removed.
    """
    try:
        resp = requests.get(f"{HISTORIAN_URL}/report?asset=config&from=0&to=9", timeout=3)
        # Just proxy whatever the historian returns
        return Response(resp.text, mimetype="text/plain")
    except Exception as e:
        return f"Could not reach historian: {e}", 503


if __name__ == "__main__":
    port = int(os.environ.get("WEB_PORT", 8080))
    app.run(host="0.0.0.0", port=port)
