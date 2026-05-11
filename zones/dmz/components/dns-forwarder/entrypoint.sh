#!/bin/sh
set -e
exec /usr/sbin/named -g -u bind
