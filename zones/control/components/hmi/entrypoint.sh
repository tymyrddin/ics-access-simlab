#!/bin/bash
set -euo pipefail

# Generate host keys if missing
ssh-keygen -A

/usr/sbin/sshd

exec python3 /opt/hmi/hmi_server.py
