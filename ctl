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
#   verify    print Step 2 verification commands
#   generate  regenerate compose files from config (no start)
#   clean     down + remove generated files
#   purge     clean + remove all images

set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

# BuildKit attaches OCI provenance attestations to every image by default.
# This requires fetching metadata from the registry and hangs in lab environments.
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

CONFIG="${CONFIG:-orchestrator/ctf-config.yaml}"
CMD="${1:-help}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ssh_port() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG'))
print(c['attacker_machine'].get('ssh_host_port', 22))
" 2>/dev/null || echo 2222
}

_auth_mode() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG'))
print(c.get('attacker_machine', {}).get('auth_mode', 'key'))
" 2>/dev/null || echo key
}

_attacker_ip() {
    python3 -c "
import yaml
c = yaml.safe_load(open('$CONFIG'))
print(c['attacker_machine'].get('internet_ip', '10.10.0.5'))
" 2>/dev/null || echo 10.10.0.5
}

_compose_up() {
    local f="$1"; shift
    [ -f "$f" ] || return 0
    docker compose -f "$f" up -d --build "$@"
}

_compose_down() {
    local f="$1"
    [ -f "$f" ] && docker compose -f "$f" down -v || true
}

_compose_purge() {
    local f="$1"
    [ -f "$f" ] && docker compose -f "$f" down --rmi all 2>/dev/null || true
}

# Build the application images for a zone via compose. clab/clab-up.sh
# starts them later from the topology files; compose never does.
_compose_build() {
    local f="$1"
    [ -f "$f" ] || return 0
    docker compose -f "$f" build
}

_reset_relay_state() {
    # Smoke tests can leave entries in the relay trip log (HR[10:19]). Zero
    # them so the lab presents a deterministic baseline regardless of prior
    # runs. The relay's pymodbus server starts before the protection loop's
    # 10-second startup grace, so this lands without contention.
    for relay in uupl-relay-a uupl-relay-b; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${relay}$"; then
            continue
        fi
        for _ in $(seq 1 15); do
            if docker exec "$relay" python3 -c "
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient('127.0.0.1', port=502, timeout=2)
if not c.connect():
    raise SystemExit(1)
c.write_registers(address=10, values=[0]*10, slave=1)
c.close()
" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    done
}

_ensure_keys() {
    local keys="zones/internet/components/unseen-gate/adversary-keys"
    # Fix Docker-created directory (happens on first run before file exists)
    [ -d "$keys" ] && rmdir "$keys" 2>/dev/null || true

    # Generate a dedicated lab keypair if not present.
    # This avoids conflicts with keys already in the user's ssh-agent.
    if [ ! -f lab-key ]; then
        ssh-keygen -t ed25519 -f lab-key -N "" -C "ics-simlab-lab-key" -q
        echo "[ctl] Generated lab-key / lab-key.pub (gitignored)"
    fi

    # Always ensure the lab key is present for ponder — idempotent.
    # Checks key content, not file emptiness, so cohort or other entries are preserved.
    # For Hetzner deployments, run ./ctl cohort-keys to generate participant keys.
    local pubkey
    pubkey=$(cat lab-key.pub)
    if ! grep -qF "$pubkey" "$keys" 2>/dev/null; then
        printf 'ponder %s\n' "$pubkey" >> "$keys"
        echo "[ctl] Added lab-key.pub to adversary-keys for user 'ponder'"
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

    echo "[ctl] Building application images ..."
    for z in enterprise operational control dmz internet; do
        _compose_build "zones/$z/docker-compose.yml"
    done

    echo "[ctl] Bringing clab zones up ..."
    if [ ! -x infrastructure/clab-up.sh ]; then
        echo "[ctl] ERROR: infrastructure/clab-up.sh missing or not executable. Did generate.py succeed?" >&2
        exit 1
    fi
    bash infrastructure/clab-up.sh

    echo "[ctl] Resetting relay trip log to baseline ..."
    _reset_relay_state

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
    ;;

  down)
    # Tear clab labs down first. Use the generated helper if it exists,
    # otherwise iterate the topology files directly so we still clean up
    # if generate.py has not been run since the last edit.
    if [ -x infrastructure/clab-down.sh ]; then
        echo "[ctl] Tearing clab zones down ..."
        bash infrastructure/clab-down.sh
    else
        # Fallback path: clab-down.sh has not been generated yet. Use the
        # same --cleanup flag so a stale state dir cannot block redeploy.
        for t in clab/*-zone.clab.yaml; do
            [ -f "$t" ] && containerlab destroy --cleanup --topo "$t" 2>/dev/null || true
        done
    fi
    # Defensive compose-down for anything that compose might have started
    # (host port mappings, leftover services from earlier hybrid runs).
    echo "[ctl] Stopping zones ..."
    _compose_down zones/internet/docker-compose.yml
    _compose_down zones/dmz/docker-compose.yml
    _compose_down zones/control/docker-compose.yml
    _compose_down zones/operational/docker-compose.yml
    _compose_down zones/enterprise/docker-compose.yml
    _compose_down infrastructure/routers/generated/docker-compose.yml
    _compose_down infrastructure/networks/docker-compose.yml
    docker network prune -f
    ;;

  ssh)
    USER="${2:-ponder}"
    IP="$(_attacker_ip)"
    echo "[ctl] Connecting as ${USER}@${IP} ..."
    if [ -f "$REPO/lab-key" ] && [ "$(_auth_mode)" = "key" ]; then
        exec ssh -o IdentitiesOnly=yes -i "$REPO/lab-key" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${USER}@${IP}"
    else
        exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${USER}@${IP}"
    fi
    ;;

  cohort-keys)
    KEYS="zones/internet/components/unseen-gate/adversary-keys"

    ssh-keygen -t ed25519 -f "$REPO/cohort-key" -N "" -C "ics-simlab-cohort-key" -q
    echo "[ctl] Generated cohort-key / cohort-key.pub (gitignored)"

    COHORT_PUB=$(cat "$REPO/cohort-key.pub")

    # Rebuild adversary-keys: operator entry (lab-key) + fresh cohort entry per account.
    # Running again replaces the previous cohort key cleanly.
    : > "$KEYS"
    if [ -f "$REPO/lab-key.pub" ]; then
        printf 'ponder %s\n' "$(cat "$REPO/lab-key.pub")" >> "$KEYS"
    fi
    for u in ponder hex ridcully librarian dean; do
        printf '%s %s\n' "$u" "$COHORT_PUB" >> "$KEYS"
    done

    echo "[ctl] adversary-keys rebuilt: operator (lab-key) + cohort key for all accounts"
    echo ""
    echo "  Distribute to participants:  $REPO/cohort-key"
    echo "  SSH command:  ssh -i cohort-key <user>@<server-ip>"
    echo ""
    echo "  cohort-key is gitignored. Regenerate before each new cohort: ./ctl cohort-keys"
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
    rm -f infrastructure/clab-up.sh infrastructure/clab-down.sh
    rm -rf infrastructure/routers/generated/
    rm -f zones/enterprise/docker-compose.yml
    rm -f zones/operational/docker-compose.yml
    rm -f zones/control/docker-compose.yml
    rm -f zones/internet/docker-compose.yml
    rm -f zones/dmz/docker-compose.yml
    rm -f zones/internet/components/unseen-gate/docker-compose.yml
    rm -f zones/internet/components/unseen-gate/adversary-readme.txt
    echo "[ctl] Clean."
    echo "[ctl] Note: lab-key, cohort-key, and adversary-keys preserved, run './ctl purge' to remove them."
    ;;

  purge)
    echo "[ctl] Removing containers and images ..."
    _compose_purge zones/internet/components/unseen-gate/docker-compose.yml
    _compose_purge zones/internet/docker-compose.yml
    _compose_purge zones/dmz/docker-compose.yml
    _compose_purge zones/control/docker-compose.yml
    _compose_purge zones/operational/docker-compose.yml
    _compose_purge zones/enterprise/docker-compose.yml
    _compose_purge infrastructure/routers/generated/docker-compose.yml
    _compose_purge infrastructure/networks/docker-compose.yml
    echo "[ctl] Pruning Docker build cache ..."
    docker builder prune -f
    "$0" clean
    echo "[ctl] Removing lab keypair, cohort keypair, and adversary-keys ..."
    rm -f lab-key lab-key.pub cohort-key cohort-key.pub
    rm -f zones/internet/components/unseen-gate/adversary-keys
    ;;

  help|*)
    cat <<EOF
Usage: ./ctl <command>

  up            generate + start everything, print SSH command
  down          stop and remove all containers
  ssh           SSH into unseen-gate  (./ctl ssh [user], default: ponder)
  cohort-keys   generate a participant keypair for Hetzner deployments
  verify        print Step 2 verification commands
  generate      regenerate compose files without starting
  clean         down + remove generated files
  purge         clean + remove all images

  CONFIG=orchestrator/configs/smart-grid.yaml ./ctl up
EOF
    ;;

esac
