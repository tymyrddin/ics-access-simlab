"""
UU P&L Admin Status Endpoint
Minimal Flask service — default credentials never changed from provisioning.
"""
import base64
from flask import Flask, request, jsonify

app = Flask(__name__)

ADMIN_USER = "admin"
ADMIN_PASS = "admin"


@app.route("/")
def index():
    return ("Unauthorized", 401, {"WWW-Authenticate": 'Basic realm="UUPL Admin"'})


@app.route("/status")
def status():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Basic "):
        return ("Unauthorized", 401, {"WWW-Authenticate": 'Basic realm="UUPL Admin"'})
    try:
        creds = base64.b64decode(auth[6:]).decode()
    except Exception:
        return ("Bad Request", 400, {})
    if creds != f"{ADMIN_USER}:{ADMIN_PASS}":
        return ("Forbidden", 403, {})
    return jsonify({
        "host": "wizzards-retreat",
        "network": "uupl-enterprise",
        "vpn": "active",
        "user": "rincewind",
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
