#!/usr/bin/env python3
"""
MQTT telemetry bridge.
Subscribes to uupl/turbine/telemetry on the internal control-zone broker and
republishes under relay/ on the DMZ clacks-relay broker.
"""
import sys, warnings
warnings.filterwarnings('ignore')
import paho.mqtt.client as mqtt

INT_BROKER = "10.10.3.60"
EXT_BROKER = "10.10.5.12"
TOPIC      = "uupl/turbine/telemetry"

pub = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="relay-pub")
pub.connect(EXT_BROKER, 1883)
pub.loop_start()

def on_message(client, userdata, msg):
    pub.publish("relay/" + msg.topic, msg.payload)

sub = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="relay-sub")
sub.on_message = on_message
sub.connect(INT_BROKER, 1883)
sub.subscribe(TOPIC)
print(f"Bridging {TOPIC} -> {EXT_BROKER}:1883  (Ctrl-C to stop)", flush=True)
try:
    sub.loop_forever()
except KeyboardInterrupt:
    pass
