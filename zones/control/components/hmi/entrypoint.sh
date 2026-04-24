#!/bin/bash
set -euo pipefail

# Generate host keys if missing
ssh-keygen -A

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.2.30/32 10.10.3.203

/usr/sbin/sshd

exec python3 /opt/hmi/hmi_server.py
