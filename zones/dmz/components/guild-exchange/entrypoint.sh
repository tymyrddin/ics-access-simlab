#!/bin/bash
set -e

# umatiGateway with startOPCConnection=True crashes at boot if guild-register's
# OPC-UA endpoint is not yet listening. Wait for it (up to 60s) using bash's
# /dev/tcp builtin before exec.
for i in {1..60}; do
    if (exec 3<>/dev/tcp/10.10.5.13/4840) 2>/dev/null; then
        exec 3>&-
        break
    fi
    sleep 1
done

exec /app/umatiGateway
