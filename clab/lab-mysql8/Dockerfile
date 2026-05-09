# mysql:8 + iproute2 so clab's exec: lines (`ip addr add`, `ip route replace`)
# work inside scada-db and hmi_main-db.
#
# Pinned to 8.0 (not the rolling :8 tag, which today resolves to 8.4):
# Scada-LTS ships Flyway 6.5.5 which supports up to MySQL 8.0. On 8.4 the
# V1.1 migration silently fails and every subsequent migration is blocked,
# leaving columns like `eventHandlers.typeRef3` and `events.assigneeTs`
# missing. WAR queries against those columns then throw 500s.

FROM mysql:8.0

USER root
RUN microdnf install -y iproute || \
    (apt-get update && apt-get install -y --no-install-recommends iproute2 && rm -rf /var/lib/apt/lists/*)
USER mysql
