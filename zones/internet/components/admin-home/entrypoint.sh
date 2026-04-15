#!/usr/bin/env bash
set -euo pipefail

ssh-keygen -A
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
sleep 0.3
exec ganesha.nfsd -f /etc/ganesha/ganesha.conf -L /dev/stdout -N NIV_EVENT -F
