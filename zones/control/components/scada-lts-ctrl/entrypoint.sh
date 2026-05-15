#!/bin/bash
# Control Scada-LTS entrypoint.
# Sets cert permissions, starts stunnel client, hands off to Scada-LTS.
set -euo pipefail

GATEWAY_HOST="${STUNNEL_GW_IP:-10.10.3.50}"
CERT_DIR="/run/stunnel-certs"
CONF_TEMPLATE="/run/stunnel-client/stunnel-client.conf"
CONF="/etc/stunnel/scadalts-ctrl-client.conf"

sed "s|GATEWAY_HOST|${GATEWAY_HOST}|g" "${CONF_TEMPLATE}" > "${CONF}"

# World-readable key, HEX-5103 (risk accepted 2020).
chmod 644 "${CERT_DIR}/client.key"
chmod 644 "${CERT_DIR}/client.crt"
chmod 644 "${CERT_DIR}/ca.crt"

echo "[scada-lts-ctrl] Starting stunnel Modbus-TLS client → ${GATEWAY_HOST}:8502"
stunnel "${CONF}"

# Wait for MySQL on scada-db:3306 before letting Tomcat boot. Without
# this the WAR's Spring context fails on the first connection attempt and
# Tomcat happily serves 404s for the rest of its life.
DB_HOST="${MYSQL_HOST:-scada-db}"
DB_PORT="${MYSQL_PORT:-3306}"
echo "[scada-lts-ctrl] Waiting for ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
    if (exec 3<>/dev/tcp/${DB_HOST}/${DB_PORT}) 2>/dev/null; then
        exec 3>&- 3<&-
        echo "[scada-lts-ctrl] ${DB_HOST}:${DB_PORT} is up after ${i}s"
        break
    fi
    sleep 1
done

echo "[scada-lts-ctrl] Starting control SCADA on :8080 (admin/admin)"
echo "[scada-lts-ctrl] Modbus data source: 127.0.0.1:5020 → PLC via TLS gateway"

# Scada-LTS V1.1 migration is buggy upstream (both release-2.8.1 and
# nightly): the SQL succeeds (the views_category_views_hierarchy table
# is created) but Flyway throws after, marking the migration failed and
# blocking subsequent migrations. Without those, the WAR's queries
# reference columns (typeRef3, assigneeTs, ...) that don't exist and
# every UI page 500s.
#
# Watchdog: launch Tomcat, watch the flyway log; on migration failure,
# patch schema_version and relaunch. One automatic retry, then give up.
DB_HOST="${MYSQL_HOST:-scada-db}"
DB_USER="${MYSQL_USER:-scadalts}"
DB_PASS="${MYSQL_PASSWORD:-scada2015}"

# V1.1 is the one upstream migration we know is cosmetically buggy: the
# SQL succeeds (views_category_views_hierarchy exists) but Flyway throws
# after, marking the row failed and blocking everything else. Patching
# this one row gets the schema from "blocked at V1.1" to "as far as
# Flyway's other bugs let it go". Later migrations may themselves fail
# for reasons we have not investigated; see clab/README.md, "Scada-LTS
# schema migration" for the full caveat. We do not chase the cascade.
flyway_patch_v1_1() {
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" scadalts \
        -e "UPDATE schema_version SET success=1 WHERE version='1.1' AND success=0;" \
        >/dev/null 2>&1 || true
}

set +e

run_tomcat() {
    catalina.sh run &
    local pid=$!
    local waited=0
    local rc
    while [ "$waited" -lt 180 ]; do
        if grep -q 'Migration of schema .* version 1.1' /usr/local/tomcat/logs/flyway.log 2>/dev/null \
                && grep -q 'failed' /usr/local/tomcat/logs/flyway.log 2>/dev/null; then
            echo "[scada-lts-ctrl] V1.1 marked failed by Flyway; patching and restarting"
            flyway_patch_v1_1
            kill "$pid" >/dev/null 2>&1
            wait "$pid" >/dev/null 2>&1
            return 42
        fi
        if grep -q 'Server startup' /usr/local/tomcat/logs/catalina.*.log 2>/dev/null; then
            wait "$pid"; rc=$?
            return "$rc"
        fi
        sleep 3
        waited=$((waited + 3))
    done
    wait "$pid"; rc=$?
    return "$rc"
}

run_tomcat
rc=$?
if [ "$rc" -eq 42 ]; then
    rm -f /usr/local/tomcat/logs/catalina.*.log
    exec catalina.sh run
fi
exit "$rc"
