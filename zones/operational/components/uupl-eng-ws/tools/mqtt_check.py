#!/usr/bin/env python3
"""
MQTT telemetry subscriber.
Usage: python3 mqtt_check.py [broker_ip [topic]]
Default: 10.10.3.60, topic uupl/turbine/telemetry
"""
import sys, warnings
warnings.filterwarnings('ignore')
import paho.mqtt.client as mqtt

BROKER = sys.argv[1] if len(sys.argv) > 1 else "10.10.3.60"
TOPIC  = sys.argv[2] if len(sys.argv) > 2 else "uupl/turbine/telemetry"

def on_message(client, userdata, msg):
    print(msg.topic, msg.payload.decode(), flush=True)

c = mqtt.Client()
c.on_message = on_message
c.connect(BROKER, 1883)
c.subscribe(TOPIC)
print(f"Subscribed to {TOPIC} on {BROKER}:1883  (Ctrl-C to stop)", flush=True)
try:
    c.loop_forever()
except KeyboardInterrupt:
    pass
