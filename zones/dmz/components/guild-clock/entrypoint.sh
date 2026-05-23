#!/bin/sh
# guild-clock chrony entrypoint.
#
# cturra/ntp's default startup script generates a chrony.conf that uses
# external pool servers as upstreams. With the lab DMZ isolated from the
# internet, chronyd never synchronises and returns stratum 0 to every
# client, which ntpdate correctly treats as a KOD packet and refuses. Real
# OT-site NTP appliances either have a GPS or local-clock source; we model
# that with `local stratum 2` so clients accept the server.
#
# The config is COPY'd into /etc/chrony/chrony.conf at build time.
set -e
exec /usr/sbin/chronyd -d -f /etc/chrony/chrony.conf
