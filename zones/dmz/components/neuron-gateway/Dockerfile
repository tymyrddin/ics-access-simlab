FROM emqx/neuron:2.11.5
# Northbound MQTT output to clacks-relay (10.10.5.12:1883) pre-configured at build time.
# Password changed from factory default (admin/0000) to admin/uupl2015 — same password
# as the ssh-bastion root account (deliberate credential reuse, discoverable).
# No southbound device. The attacker adds that after gaining a foothold from which
# the control zone is reachable (eng-ws or uupl-modbus-gw), then configures Neuron
# as a covert exfil path back out through the DMZ MQTT broker.
# Attack path: admin/uupl2015 → add Modbus south device → bridge to turbine_plc:502
#              → subscribe to clacks-relay → exfil PLC data over internet.
# curl is pre-installed in the Ubuntu 20.04 base image.
RUN /usr/bin/entrypoint.sh 2>/dev/null & \
    sleep 10 && \
    TOKEN=$(curl -sf -X POST http://127.0.0.1:7000/api/v2/login \
      -H 'Content-Type: application/json' \
      -d '{"name":"admin","pass":"0000"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4) && \
    curl -sf -X POST http://127.0.0.1:7000/api/v2/node \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"uupl-mqtt-north","plugin":"MQTT"}' && \
    curl -sf -X POST http://127.0.0.1:7000/api/v2/node/setting \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"node":"uupl-mqtt-north","params":{"version":4,"client-id":"neuron-sorting-office","qos":0,"format":0,"upload_err":true,"enable_topic":true,"write-req-topic":"/neuron/sorting-office/write/req","write-resp-topic":"/neuron/sorting-office/write/resp","upload_drv_state":false,"offline-cache":false,"host":"10.10.5.12","port":1883,"username":"","password":"","ssl":false}}' && \
    curl -sf -X POST http://127.0.0.1:7000/api/v2/password \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"admin","old_pass":"0000","new_pass":"uupl2015"}' && \
    echo "Neuron bootstrap complete"
EXPOSE 7000
