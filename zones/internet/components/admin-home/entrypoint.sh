#!/usr/bin/env bash
set -euo pipefail

ssh-keygen -A

_add_route() {
    local dest="$1" gw="$2"
    for _i in 1 2 3 4 5; do
        ip route replace "$dest" via "$gw" 2>/dev/null && return 0
        sleep 1
    done
    echo "[entrypoint] WARNING: could not add route $dest via $gw" >&2
}
_add_route 10.10.5.0/24 10.10.0.200

/usr/sbin/sshd

# OverlayFS (Docker) does not support name_to_handle_at(), which NFS-Ganesha's
# VFS FSAL requires. Stage the work directory on tmpfs instead.
mkdir -p /nfs-export
mount -t tmpfs tmpfs /nfs-export
cp /home/rincewind/work/* /nfs-export/
chmod 755 /nfs-export
chmod 644 /nfs-export/*

mkdir -p /run/rpcbind
rpcbind -w
for i in $(seq 1 20); do
    rpcinfo -p 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.2
done
exec ganesha.nfsd -f /etc/ganesha/ganesha.conf -L /dev/stdout -N NIV_EVENT -F
