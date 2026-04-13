#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/run/sshd

AUTH_MODE="${AUTH_MODE:-key}"

if [ "$AUTH_MODE" = "password" ]; then
    # ------------------------------------------------------------------
    # Password mode — Root-Me and platforms that publish credentials.
    # No key exchange or adversary-keys file required.
    # Credentials are set from AUTH_ACCOUNTS: "user:pass user:pass ..."
    # ------------------------------------------------------------------
    cat > /etc/ssh/sshd_config.d/jumphost.conf << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
MaxAuthTries 3
EOF

    for pair in ${AUTH_ACCOUNTS:-}; do
        u="${pair%%:*}"
        p="${pair#*:}"
        if id "$u" &>/dev/null; then
            echo "${u}:${p}" | chpasswd
            echo "[entrypoint] Password set for ${u}" >&2
        fi
    done

else
    # ------------------------------------------------------------------
    # Key mode (default) — self-hosted / Hetzner deployments.
    # Public keys are mounted from adversary-keys at runtime.
    # Format: username ssh-... [comment] — one line per participant.
    # ------------------------------------------------------------------
    cat > /etc/ssh/sshd_config.d/jumphost.conf << 'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
MaxAuthTries 3
EOF

    VALID_USERS="ponder hex ridcully librarian dean"

    if [ -f /run/adversary-keys ]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            username=$(echo "$line" | awk '{print $1}')
            pubkey=$(echo "$line" | cut -d' ' -f2-)

            if echo "$VALID_USERS" | grep -qw "$username"; then
                auth_keys="/home/${username}/.ssh/authorized_keys"
                echo "$pubkey" >> "$auth_keys"
                chmod 600 "$auth_keys"
                chown "${username}:${username}" "$auth_keys"
            else
                echo "[entrypoint] Skipping unknown user: $username" >&2
            fi
        done < /run/adversary-keys
    else
        echo "[entrypoint] Warning: /run/adversary-keys not mounted — no keys distributed" >&2
    fi

fi

# Copy adversary README to each user's home directory (both modes)
if [ -f /run/adversary-readme.txt ]; then
    for u in ponder hex ridcully librarian dean; do
        cp /run/adversary-readme.txt "/home/${u}/README"
        chown "${u}:${u}" "/home/${u}/README"
    done
fi

# Plant prior-recon artifact in each adversary home dir (both modes)
for u in ponder hex ridcully librarian dean; do
    mkdir -p "/home/${u}/loot"
    cat > "/home/${u}/loot/prior-recon.txt" << 'RECON'
# Recon notes — prior engagement fragment
# Do not leave on shared systems.
10.10.0.5  ponders-machine  open: 22/tcp
10.10.0.10 wizzards-retreat open: 22/tcp 80/tcp
-- last updated by previous team
RECON
    chown -R "${u}:${u}" "/home/${u}/loot"
done

exec /usr/sbin/sshd -D
