#!/bin/bash
# Scada-LTS entrypoint.
# Sets cert permissions, starts stunnel client, then hands off to Scada-LTS.
set -euo pipefail

GATEWAY_HOST="${STUNNEL_GW_IP:-10.10.2.50}"
CERT_DIR="/run/stunnel-certs"
CONF_TEMPLATE="/run/stunnel-client/stunnel-client.conf"
CONF="/etc/stunnel/scadalts-client.conf"

# Substitute gateway IP
sed "s|GATEWAY_HOST|${GATEWAY_HOST}|g" "${CONF_TEMPLATE}" > "${CONF}"

# World-readable key, HEX-5103 (risk accepted 2020): monitoring user needs
# access. The mount source already has 644 on the certs; the chmod fails on
# read-only volume mounts, so it is best-effort here.
chmod 644 "${CERT_DIR}/client.key" 2>/dev/null || true
chmod 644 "${CERT_DIR}/client.crt" 2>/dev/null || true
chmod 644 "${CERT_DIR}/ca.crt"     2>/dev/null || true

echo "[scada-lts] Starting stunnel Modbus-TLS client → ${GATEWAY_HOST}:8502"
stunnel "${CONF}"

# Generate host keys on first start, then run sshd in the background. The
# scada_admin SSH login is what the stunnel-client-key-theft runbook uses
# to read the world-readable client cert and key.
ssh-keygen -A
/usr/sbin/sshd

# Wait for MySQL on scada-db:3306 before letting Tomcat boot. Without
# this the WAR's Spring context fails on the first connection attempt
# and Tomcat happily serves 404s for the rest of its life.
DB_HOST="${MYSQL_HOST:-scada-db}"
DB_PORT="${MYSQL_PORT:-3306}"
echo "[scada-lts] Waiting for ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
    if (exec 3<>/dev/tcp/${DB_HOST}/${DB_PORT}) 2>/dev/null; then
        exec 3>&- 3<&-
        echo "[scada-lts] ${DB_HOST}:${DB_PORT} is up after ${i}s"
        break
    fi
    sleep 1
done

echo "[scada-lts] Starting Scada-LTS on :8080 (admin/admin)"

# See zones/control/components/scada-lts-ctrl/entrypoint.sh for the why:
# Scada-LTS V1.1 migration is buggy upstream; the SQL succeeds but Flyway
# marks it failed, blocking subsequent migrations. Watchdog patches
# schema_version and relaunches Tomcat once.
DB_HOST="${MYSQL_HOST:-scada-db}"
DB_USER="${MYSQL_USER:-scadalts}"
DB_PASS="${MYSQL_PASSWORD:-scada2015}"

# See zones/control/components/scada-lts-ctrl/entrypoint.sh for the why.
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
            echo "[scada-lts] V1.1 marked failed by Flyway; patching and restarting"
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
