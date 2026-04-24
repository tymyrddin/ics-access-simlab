#!/usr/bin/env sh
# Zone router entrypoint.
# Hardens the router itself, then applies the generated ACL policy from /acl.sh.
# /acl.sh is bind-mounted from infrastructure/routers/generated/ by docker-compose.
set -e

if [ ! -f /acl.sh ]; then
    echo "[router] ERROR: /acl.sh not found — run ./ctl generate first." >&2
    exit 1
fi

# Harden the router's own INPUT/OUTPUT chains so it cannot be used as a pivot.
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
iptables -P INPUT  DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Allow replies to connections the router itself originated (e.g. DNS if ever needed).
iptables -A INPUT  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Apply generated FORWARD policy + static routes.
. /acl.sh

echo "[router] $(hostname) ready."

# Signal handling: reload ACL on SIGHUP, clean exit on SIGTERM/SIGINT.
_reload() {
    echo "[router] SIGHUP received — reloading ACL."
    iptables -F FORWARD
    . /acl.sh
}
_exit() {
    echo "[router] Shutting down."
    exit 0
}
trap '_reload' HUP
trap '_exit'   TERM INT

while true; do
    sleep 60 &
    wait $!
done
