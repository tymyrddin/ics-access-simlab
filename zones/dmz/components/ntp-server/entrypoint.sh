#!/bin/sh
# guild-clock chrony entrypoint.
#
# The cturra/ntp default startup script generates a chrony.conf that uses
# external pool servers as upstreams. With the lab isolated from the internet,
# chronyd never synchronises and returns stratum 0 to every client, which
# ntpsec's ntpdig (the modern ntpdate) correctly treats as a KOD packet and
# refuses. A real OT-site NTP server either has a GPS or local-clock source;
# we model that with `local stratum 2`, advertising a synthetic stratum so
# clients accept the server.
#
# `allow all` and `cmdallow all` are the deliberate misconfigurations the
# runbook exercises (open recursion, open mode 6 queries).
set -e

cat > /etc/chrony/chrony.conf <<'EOF'
# Synthetic stratum advertisement: no real upstream is reachable in the lab.
# A real OT site would have a GPS or refclock here.
local stratum 2

# Open access (deliberate misconfigurations the runbook exercises)
allow all
cmdallow all

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF

exec /usr/sbin/chronyd -d -f /etc/chrony/chrony.conf
