#!/usr/bin/env python3
"""
Simple status endpoint for admin home VPN box.
Provides basic system info for recon purposes.
"""
from flask import Flask, request
import subprocess
import datetime
import socket

app = Flask(__name__)

@app.route('/status')
def status():
    # Basic auth check (weak creds: admin/admin)
    auth = request.authorization
    if not auth or auth.username != 'admin' or auth.password != 'admin':
        return 'Authentication required', 401, {'WWW-Authenticate': 'Basic realm="Admin Status"'}

    # Gather basic system info
    try:
        uptime = subprocess.check_output(['uptime'], text=True).strip()
    except:
        uptime = 'unknown'

    try:
        hostname = socket.gethostname()
    except:
        hostname = 'wizzards-retreat'

    status_info = {
        'hostname': hostname,
        'uptime': uptime,
        'timestamp': datetime.datetime.now().isoformat(),
        'vpn_status': 'connected',
        'interfaces': ['eth1', 'eth2', 'eth3'],
        'services': ['ssh', 'nfs', 'vpn']
    }

    # Return as simple text for basic recon
    lines = [f"{k}: {v}" for k, v in status_info.items()]
    return '\n'.join(lines) + '\n', 200, {'Content-Type': 'text/plain'}

@app.route('/')
def index():
    return 'Admin Home Status Server - use /status endpoint', 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)