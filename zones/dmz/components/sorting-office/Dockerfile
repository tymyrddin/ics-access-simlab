FROM emqx/neuron:2.11.5
# Northbound MQTT output to clacks-relay (10.10.5.12:1883) configured at first start.
# Password changed from factory default (admin/0000) to admin/uupl2015 on first run.
# Same password as the ssh-bastion root account (deliberate credential reuse, discoverable).
# No southbound device at build time. The attacker adds one after gaining a foothold
# from which the control zone is reachable (eng-ws or uupl-modbus-gw), then configures
# Neuron as a covert exfil path back out through the DMZ MQTT broker.
# Attack path: admin/uupl2015 -> add Modbus south device -> bridge to turbine_plc:502
#              -> subscribe to clacks-relay -> exfil PLC data over internet.

RUN apt-get update && apt-get install -y --no-install-recommends iproute2 && rm -rf /var/lib/apt/lists/*
COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh
EXPOSE 7000
ENTRYPOINT ["/bootstrap.sh"]
