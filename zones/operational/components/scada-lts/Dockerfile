FROM scadalts/scadalts:nightly

# Scada-LTS, open-source SCADA/HMI (Mango Automation base).
# Runs on port 8080. Default credentials: admin / admin.
# Connects to turbine PLC via stunnel TLS gateway.
#
# Certs are volume-mounted at runtime from the generated certs/ directory.
# Client key is made world-readable at container start by entrypoint.sh ,
# see HEX-5103 (OPEN, risk accepted 2020).

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        iproute2 \
        stunnel4 \
        openssh-server \
        default-mysql-client \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# scada_admin: SSH login the runbook's stunnel-client-key-theft chain
# expects. Password documented in ENGINEER.LOG and ops-access.conf.
RUN useradd -m -s /bin/bash scada_admin \
 && echo "scada_admin:W1nd0ws@2016" | chpasswd

COPY stunnel-client.conf /run/stunnel-client/stunnel-client.conf
COPY entrypoint.sh /scadalts-entrypoint.sh
RUN chmod +x /scadalts-entrypoint.sh

# Same upstream WAR defaults as the control-zone Scada-LTS, see
# zones/control/components/scada-lts-ctrl/Dockerfile for the discussion.
# Operational SCADA points at scada-db / scadalts / scada2015.
RUN sed -i \
        -e 's|//database:|//scada-db:|g' \
        -e 's|username="root"|username="scadalts"|' \
        -e 's|password="root"|password="scada2015"|' \
        /usr/local/tomcat/webapps/Scada-LTS/META-INF/context.xml

EXPOSE 22 8080

ENTRYPOINT ["/scadalts-entrypoint.sh"]
