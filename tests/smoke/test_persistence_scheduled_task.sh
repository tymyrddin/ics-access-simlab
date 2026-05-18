#!/usr/bin/env bash
# Persistence probe. The engineering workstation is themed as Windows 10
# Enterprise LTSC; visitors with engineer SSH access reach a PowerShell
# facade that supports `schtasks /create`. The facade pipes scheduled
# tasks through the user's crontab (cron is running on the host as part
# of the lab's normal plc-poll machinery), so a "scheduled task" lands as
# a vendor-default-tagged crontab entry. Persistence is independent of
# the existing plc-poll cron, the visitor owns their own implant.
#
# Coverage:
#   Stage 1  baseline: schtasks /query returns "no scheduled tasks"
#   Stage 2  visitor schedules a per-minute task with /create
#   Stage 3  schtasks /query lists the implant under "Per Minute"
#   Stage 4  wait up to 75s for the task to fire; marker file appears
#   Stage 5  cleanup: visitor /delete /tn ... /f the implant
#   Stage 6  schtasks /query no longer lists the implant
#
# Usage: bash tests/smoke/test_persistence_scheduled_task.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
JUMP_HOST="10.10.0.10"
JUMP_USER="rincewind"
JUMP_PASS="wizzard"
TARGET_HOST="10.10.2.30"
TARGET_USER="engineer"
TARGET_PASS="spanner99"
TASK_NAME="uupl-implant"
MARKER="/tmp/uupl_scht_marker"

require_running "$ATTACKER"
require_running "wizzards-retreat"
require_running "uupl-eng-ws"

run_on_engws() {
    local cmd="$1"
    ssh_password_login_via_jump "$ATTACKER" \
        "$JUMP_USER" "$JUMP_HOST" "$JUMP_PASS" \
        "$TARGET_USER" "$TARGET_HOST" "$TARGET_PASS" \
        "$cmd"
}

echo "[persist-sch] Stage 1: baseline schtasks /query is empty"
# Ensure no leftover implant from a previous run.
run_on_engws "schtasks /delete /tn $TASK_NAME /f" >/dev/null 2>&1 || true
docker exec uupl-eng-ws rm -f "$MARKER" >/dev/null 2>&1 || true
Q="$(run_on_engws 'schtasks /query')"
assert_contains "$Q" "no scheduled tasks" "schtasks /query is empty at start"

echo "[persist-sch] Stage 2: visitor schedules a per-minute task"
CREATE="$(run_on_engws "schtasks /create /tn $TASK_NAME /tr \"touch $MARKER\" /sc minute")"
assert_contains "$CREATE" "SUCCESS: The scheduled task \"$TASK_NAME\" has successfully been created" \
    "schtasks /create returns success"

echo "[persist-sch] Stage 3: schtasks /query lists the implant"
Q2="$(run_on_engws 'schtasks /query')"
assert_contains "$Q2" "$TASK_NAME" "task name appears in /query listing"
assert_contains "$Q2" "Per Minute"  "schedule is Per Minute"

echo "[persist-sch] Stage 4: wait up to 75s for the task to fire"
START_EPOCH=$(date +%s)
MARKER_FOUND=""
for _ in $(seq 1 75); do
    if docker exec uupl-eng-ws test -f "$MARKER" 2>/dev/null; then
        MARKER_FOUND="yes"
        break
    fi
    sleep 1
done
[ -n "$MARKER_FOUND" ] || fail "marker $MARKER never appeared in 75s"
ok "marker $MARKER created by scheduled task tick"

# Sanity check: marker mtime is within the test window.
MARKER_MTIME="$(docker exec uupl-eng-ws stat -c '%Y' "$MARKER" 2>&1)"
AGE=$((MARKER_MTIME - START_EPOCH))
if [ "$AGE" -ge -5 ] && [ "$AGE" -le 80 ]; then
    ok "marker mtime $MARKER_MTIME is within window (age ${AGE}s)"
else
    fail "marker mtime $MARKER_MTIME outside expected window (age ${AGE}s)"
fi

echo "[persist-sch] Stage 5: cleanup, /delete the implant"
DEL="$(run_on_engws "schtasks /delete /tn $TASK_NAME /f")"
assert_contains "$DEL" "SUCCESS: The scheduled task \"$TASK_NAME\" was successfully deleted" \
    "schtasks /delete returns success"
docker exec uupl-eng-ws rm -f "$MARKER" >/dev/null 2>&1 || true

echo "[persist-sch] Stage 6: schtasks /query confirms removal"
Q3="$(run_on_engws 'schtasks /query')"
assert_absent  "$Q3" "$TASK_NAME"        "task no longer in /query listing"
assert_contains "$Q3" "no scheduled tasks" "schtasks /query is empty after cleanup"

summary
