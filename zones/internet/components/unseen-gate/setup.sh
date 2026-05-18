#!/usr/bin/env bash
# One-time Hetzner host preparation for the attacker machine container.
# Run as root on a fresh Debian/Ubuntu instance before deploying.
#
# After this script completes, the host sshd listens on port 2222.
# The attacker machine container takes port 22.
#
# Usage: bash zones/internet/components/unseen-gate/setup.sh

set -euo pipefail

# Move host sshd to port 2222 so the attacker machine container can claim port 22.
if ! grep -q "^Port 2222" /etc/ssh/sshd_config; then
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    # If no Port line existed, append one
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port 2222" >> /etc/ssh/sshd_config
    systemctl restart ssh
    echo "[setup] Host sshd moved to port 2222."
else
    echo "[setup] Host sshd already on port 2222."
fi

echo ""
echo "[setup] Host preparation complete."
echo ""
echo "Next steps:"
echo "  1. Copy adversary-keys.example to zones/internet/components/unseen-gate/adversary-keys"
echo "     and fill in real public keys."
echo "  2. Run: ./ctl up"
echo ""
echo "Adversary SSH access: ssh <username>@<hetzner-ip>  (port 22, key auth only)"
