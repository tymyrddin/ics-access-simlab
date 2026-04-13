#!/usr/bin/env bash
# ctl — ICS-SimLab lab control
#
# Usage:
#   ./ctl <command>
#   CONFIG=orchestrator/configs/smart-grid.yaml ./ctl <command>
#
# Commands:
#   up        generate + start everything, print SSH command
#   down      stop and remove all containers
#   ssh       SSH into unseen-gate  (./ctl ssh [user], default: ponder)
#   firewall  apply inter-zone iptables rules (needs sudo)
#   verify    print Step 2 verification commands
#   generate  regenerate compose files from config (no start)
#   clean     down + remove generated files
#   purge     clean + remove all images

set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

CONFIG="${CONFIG:-orchestrator/ctf-config.yaml}"
CMD="${1:-help}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ssh_port() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG'))
print(c['jump_host'].get('ssh_host_port', 22))
" 2>/dev/null || echo 2222
}

_auth_mode() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG'))
print(c.get('jump_host', {}).get('auth_mode', 'key'))
" 2>/dev/null || echo key
}

_compose_up() {
    local f="$1"; shift
    [ -f "$f" ] && docker compose -f "$f" up -d "$@"
}

_compose_down() {
    local f="$1"
    [ -f "$f" ] && docker compose -f "$f" down || true
}

_compose_purge() {
    local f="$1"
    [ -f "$f" ] && docker compose -f "$f" down --rmi all 2>/dev/null || true
}

_ensure_keys() {
    local keys="zones/internet/components/attacker-machine/adversary-keys"
    # Fix Docker-created directory (happens on first run before file exists)
    [ -d "$keys" ] && rmdir "$keys" 2>/dev/null || true

    # Generate a dedicated lab keypair if not present.
    # This avoids conflicts with keys already in the user's ssh-agent.
    if [ ! -f lab-key ]; then
        ssh-keygen -t ed25519 -f lab-key -N "" -C "ics-simlab-lab-key" -q
        echo "[ctl] Generated lab-key / lab-key.pub (gitignored)"
    fi

    # Populate adversary-keys from lab key if the file is absent or empty.
    # For Hetzner/shared deployments, pre-populate adversary-keys from
    # adversary-keys.example before running ./ctl up — this step is skipped
    # if the file already has content.
    if [ ! -s "$keys" ]; then
        echo "ponder $(cat lab-key.pub)" > "$keys"
        echo "[ctl] Wrote lab-key.pub → adversary-keys for user 'ponder'"
        echo "[ctl] For shared deployments: edit adversary-keys directly (see adversary-keys.example)"
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

case "$CMD" in

  up)
    if [ "$(_auth_mode)" = "key" ]; then
        _ensure_keys
    fi
    echo "[ctl] Generating compose files from $CONFIG ..."
    python3 orchestrator/generate.py "$CONFIG"

    echo "[ctl] Starting shared networks ..."
    docker compose -f infrastructure/networks/docker-compose.yml up -d

    echo "[ctl] Starting enterprise zone ..."
    docker compose -f zones/enterprise/docker-compose.yml up -d

    echo "[ctl] Starting operational zone ..."
    docker compose -f zones/operational/docker-compose.yml up -d

    echo "[ctl] Starting control zone ..."
    docker compose -f zones/control/docker-compose.yml up -d

    echo "[ctl] Starting internet zone (unseen-gate + wizzards-retreat) ..."
    _compose_up zones/internet/docker-compose.yml

    PORT="$(_ssh_port)"
    MODE="$(_auth_mode)"
    echo ""
    echo "  Lab is up."
    echo ""
    if [ "$MODE" = "password" ]; then
        echo "  SSH in:   ssh ponder@localhost -p $PORT  (password: see accounts in ctf-config.yaml)"
    else
        echo "  SSH in:   ./ctl ssh ponder"
    fi
    echo "  Stop:     ./ctl down"
    echo "  Verify:   ./ctl verify"
    echo ""
    echo "  Run './ctl firewall' (sudo) to enforce inter-zone routing rules."
    ;;

  down)
    echo "[ctl] Stopping internet zone ..."
    _compose_down zones/internet/docker-compose.yml
    echo "[ctl] Stopping zones ..."
    _compose_down zones/control/docker-compose.yml
    _compose_down zones/operational/docker-compose.yml
    _compose_down zones/enterprise/docker-compose.yml
    _compose_down infrastructure/networks/docker-compose.yml
    ;;

  ssh)
    USER="${2:-ponder}"
    PORT="$(_ssh_port)"
    echo "[ctl] Connecting as ${USER}@localhost:${PORT} ..."
    if [ -f "$REPO/lab-key" ] && [ "$(_auth_mode)" = "key" ]; then
        exec ssh -o IdentitiesOnly=yes -i "$REPO/lab-key" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${USER}@localhost" -p "$PORT"
    else
        exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${USER}@localhost" -p "$PORT"
    fi
    ;;

  firewall)
    echo "[ctl] Applying firewall rules (sudo) ..."
    sudo bash infrastructure/firewall.sh
    ;;

  verify)
    PORT="$(_ssh_port)"
    cat <<EOF

Step 2 verification
───────────────────

1. SSH into the attacker machine from your local machine:
   ./ctl ssh ponder

2. From inside unseen-gate (10.10.0.5), run:

   # Discover wizzards-retreat
   nmap 10.10.0.10

   # HTTP path (admin:admin)
   curl -u admin:admin http://10.10.0.10/status

   # SSH path (rincewind / wizzard)
   ssh rincewind@10.10.0.10

   # After SSH login — loot should be present:
   ls ~/.vpn/ ~/.ssh-keys/ ~/notes.txt

   # Use the loot key to reach eng-workstation:
   ssh -i ~/.ssh-keys/uupl_eng_key engineer@10.10.2.30

3. Firewall checks (from inside unseen-gate):

   # Must FAIL — attacker machine is blocked from enterprise:
   nc -zv 10.10.1.10 22

   # Must SUCCEED — run from wizzards-retreat (10.10.0.10):
   ssh rincewind@10.10.0.10
   nc -zv 10.10.1.10 22

EOF
    ;;

  generate)
    echo "[ctl] Generating compose files from $CONFIG ..."
    python3 orchestrator/generate.py "$CONFIG"
    echo "[ctl] Done."
    ;;

  clean)
    "$0" down
    echo "[ctl] Removing generated files ..."
    rm -f start.sh stop.sh
    rm -f infrastructure/networks/docker-compose.yml
    rm -f infrastructure/firewall.sh
    rm -f zones/enterprise/docker-compose.yml
    rm -f zones/operational/docker-compose.yml
    rm -f zones/control/docker-compose.yml
    rm -f zones/internet/docker-compose.yml
    rm -f zones/internet/components/attacker-machine/docker-compose.yml
    rm -f zones/internet/components/attacker-machine/adversary-readme.txt
    echo "[ctl] Clean."
    echo "[ctl] Note: lab-key and adversary-keys preserved — run './ctl purge' to remove them."
    ;;

  purge)
    echo "[ctl] Removing containers and images ..."
    _compose_purge zones/internet/components/attacker-machine/docker-compose.yml
    _compose_purge zones/internet/docker-compose.yml
    _compose_purge zones/control/docker-compose.yml
    _compose_purge zones/operational/docker-compose.yml
    _compose_purge zones/enterprise/docker-compose.yml
    _compose_purge infrastructure/networks/docker-compose.yml
    echo "[ctl] Pruning Docker build cache ..."
    docker builder prune -f
    "$0" clean
    echo "[ctl] Removing lab keypair and adversary-keys ..."
    rm -f lab-key lab-key.pub
    rm -f zones/internet/components/attacker-machine/adversary-keys
    ;;

  help|*)
    cat <<EOF
Usage: ./ctl <command>

  up        generate + start everything, print SSH command
  down      stop and remove all containers
  ssh       SSH into unseen-gate  (./ctl ssh [user], default: ponder)
  firewall  apply inter-zone iptables rules (needs sudo)
  verify    print Step 2 verification commands
  generate  regenerate compose files without starting
  clean     down + remove generated files
  purge     clean + remove all images

  CONFIG=orchestrator/configs/smart-grid.yaml ./ctl up
EOF
    ;;

esac
