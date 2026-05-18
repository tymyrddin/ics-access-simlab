FROM scadalts/scadalts:nightly

# Scada-LTS, control-zone SCADA/HMI (Purdue L2).
# Connects directly to field devices via Modbus through the stunnel gateway.
# Operators use this to view process state and issue control commands.
#
# Default credentials: admin / admin (never changed post-commissioning).
# Certs volume-mounted at runtime from generated certs/ directory.
# Client key made world-readable by entrypoint, HEX-5103 (risk accepted 2020).

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 stunnel4 default-mysql-client \
 && rm -rf /var/lib/apt/lists/*

COPY stunnel-client.conf /run/stunnel-client/stunnel-client.conf
COPY entrypoint.sh /scadalts-entrypoint.sh
RUN chmod +x /scadalts-entrypoint.sh

# The upstream WAR's META-INF/context.xml ships the upstream demo's
# defaults: host `database`, user `root`, password `root`. None match this
# lab's scada-db container (host `scada-db`, user `scadalts`,
# password `scada2015`). Rewrite all three at build time so Spring's
# DataSource bean can finish wiring; without this Tomcat serves only a
# 404 and visitors never see the SCADA UI.
RUN sed -i \
        -e 's|//database:|//scada-db:|g' \
        -e 's|username="root"|username="scadalts"|' \
        -e 's|password="root"|password="scada2015"|' \
        /usr/local/tomcat/webapps/Scada-LTS/META-INF/context.xml

EXPOSE 8080

ENTRYPOINT ["/scadalts-entrypoint.sh"]
