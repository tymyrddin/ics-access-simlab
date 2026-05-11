#!/bin/sh
set -e
exec gosu syslog /usr/sbin/syslog-ng -F --no-caps
