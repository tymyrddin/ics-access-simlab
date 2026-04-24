#!/bin/sh
set -e
ip route replace default via 10.10.5.201 || {
    echo "[dmz-entrypoint] ERROR: failed to add default route via dmz-ent-fw" >&2
    exit 1
}
ip route replace 10.10.0.0/24 via 10.10.5.200 2>/dev/null || true
exec /usr/sbin/named -g -u bind
