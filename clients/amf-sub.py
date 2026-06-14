#!/usr/bin/env python3
# =============================================================================
# Script:  amf-sub.py
# Purpose: MQTT subscriber/logger for the ToD (Teleoperated Driving) testbed.
#          Subscribes to a "set/<topic_suffix>" topic on the broker and appends
#          every received message (with a millisecond timestamp) to a log file,
#          while also echoing it to the console. Used to capture the actuation
#          commands sent to the vehicle/AMF during fault-injection experiments.
#
# Usage:   ./amf-sub.py <topic_suffix> [log_file]
#          e.g. ./amf-sub.py speed                  -> topic "set/speed",
#                                                       logs to mqtt_log_speed.txt
#               ./amf-sub.py direction mylog.txt    -> topic "set/direction",
#                                                       logs to mylog.txt
#
# Config:  BROKERIP   env var (default 127.0.0.1) - MQTT broker host
#          BROKERPORT env var (default 1883)       - MQTT broker port
# Output:  Appends to the log file (default mqtt_log_<topic_suffix>.txt) in the
#          current directory.
# Stop:    Ctrl-C (clean disconnect).
#
# NOTE: This single script replaces the former amf-sub.py / amf-sub-speed-2.py /
#   amf-sub-direction.py trio, which differed only in their log file name.
# =============================================================================
import os
import sys
import paho.mqtt.client as mqtt
from datetime import datetime

# --- Configuration ---
BROKER = os.environ.get('BROKERIP', '127.0.0.1')
PORT = int(os.environ.get('BROKERPORT', 1883))

if len(sys.argv) < 2:
    print("Usage: ./amf-sub.py <topic_suffix> [log_file]")
    sys.exit(1)

TOPIC_SUFFIX = sys.argv[1]
TOPIC = f"set/{TOPIC_SUFFIX}"
LOG_FILE = sys.argv[2] if len(sys.argv) > 2 else f"mqtt_log_{TOPIC_SUFFIX}.txt"

def on_message(client, userdata, message):
    payload = message.payload.decode("utf-8")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    
    log_entry = f"[{timestamp}] Topic: {message.topic} | Payload: {payload}\n"
    
    # Append to file
    with open(LOG_FILE, "a") as f:
        f.write(log_entry)
    
    # Also print to console so you can see it working
    print(log_entry.strip())

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"Connected! Logging {TOPIC} to {LOG_FILE}...")
        client.subscribe(TOPIC)
    else:
        print(f"Failed to connect, return code {rc}")

# --- Main ---
client = mqtt.Client()
client.on_connect = on_connect
client.on_message = on_message

try:
    client.connect(BROKER, PORT)
    client.loop_forever()
except KeyboardInterrupt:
    print("\nStopping logger...")
    client.disconnect()
