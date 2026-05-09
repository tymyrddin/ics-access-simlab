#!/bin/sh
set -e
exec su-exec mosquitto "$@"
