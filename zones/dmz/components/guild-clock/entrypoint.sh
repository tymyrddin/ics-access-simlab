#!/bin/sh
# guild-clock chrony entrypoint.
#
# The cturra/ntp default startup script generates a chrony.conf that uses
# external pool servers as upstreams. With the lab DMZ isolated from the
# internet, chronyd never synchronises and returns stratum 0 to every
# client, which ntpdate correctly treats as a KOD packet and refuses. Real
# OT-site NTP appliances either have a GPS or local-clock source; we model
# that with `local stratum 2` so clients accept the server.
#
# `allow all`         -> open UDP/123 mode-3 (NTP time-sync) to any caller
# `cmdallow all`      -> open UDP/323 (chronyc command protocol) to any caller
# `bindcmdaddress 0.0.0.0` -> make chronyd listen for chronyc on every
#                              interface (default: 127.0.0.1 only, which
#                              would silently drop remote chronyc queries)
#
# Authentication is not configured (no `keyfile` directive); chronyc remote
# queries succeed without credentials, matching the runbook's "vendor-default
# leaky NTP, no auth" claim.
set -e

cat > /etc/chrony/chrony.conf <<'EOF'
# Synthetic stratum advertisement: no real upstream is reachable in the lab.
# A real OT site would have a GPS or refclock here.
local stratum 2

# Vendor-default leaky access (the runbook's misconfiguration target).
allow all
cmdallow all
bindcmdaddress 0.0.0.0
bindcmdaddress ::

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF

exec /usr/sbin/chronyd -d -f /etc/chrony/chrony.conf
