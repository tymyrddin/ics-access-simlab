#!/usr/bin/env bash
# One-time Hetzner host preparation for the attacker machine container.
# Run as root on a fresh Debian/Ubuntu instance before deploying.
#
# After this script completes, the host sshd listens on port 2222.
# The attacker machine container takes port 22.
#
# Usage: bash zones/internet/components/attacker-machine/setup.sh

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

# Allow the deploy user to apply Docker firewall rules without a full root shell.
# Only the two iptables commands used by infrastructure/firewall.sh are permitted.
DEPLOY_USER="${SUDO_USER:-$(logname)}"
SUDOERS_FILE="/etc/sudoers.d/ics-access-simlab-firewall"
cat > "$SUDOERS_FILE" <<EOF
# ICS-Access-SimLab: allow $DEPLOY_USER to apply inter-zone Docker firewall rules only.
$DEPLOY_USER ALL=(root) NOPASSWD: /usr/sbin/iptables -F DOCKER-USER, /usr/sbin/iptables -A DOCKER-USER *
EOF
chmod 0440 "$SUDOERS_FILE"
echo "[setup] Sudoers rule written: $SUDOERS_FILE"

echo ""
echo "[setup] Host preparation complete."
echo ""
echo "Next steps:"
echo "  1. Copy adversary-keys.example → zones/internet/components/attacker-machine/adversary-keys"
echo "     and fill in real public keys."
echo "  2. Run: ./ctl up"
echo "  3. Run: make up && make firewall"
echo ""
echo "Adversary SSH access: ssh <username>@<hetzner-ip>  (port 22, key auth only)"
