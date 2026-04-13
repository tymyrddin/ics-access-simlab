#!/usr/bin/env bash
set -euo pipefail

ssh-keygen -A
/usr/sbin/sshd

exec /opt/status-env/bin/python3 /opt/status.py
