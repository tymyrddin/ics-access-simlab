#!/usr/bin/env bash
# Shared helpers for smoke test scripts.
# Source this file: source "$(dirname "$0")/lib.sh"

PASS=0
FAIL=0

ok() {
    echo "  ✔ $*"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $*"
    FAIL=$((FAIL + 1))
}

summary() {
    echo ""
    echo "$PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

# Guard: compose files must already exist (run 'make generate' first).
require_generated() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "[skip] Required generated file not found: $file"
        echo "       Run 'make generate' before running smoke tests."
        exit 0
    fi
}

# Map a zone (or docker-network-name) to a representative in-zone container
# the test framework can `docker exec` into for probes. The data plane no
# longer runs on docker networks; probes execute from a real lab node.
_probe_runner() {
    case "$1" in
        ics_internet|internet)       echo attacker-machine ;;
        ics_enterprise|enterprise)   echo enterprise-workstation ;;
        ics_operational|operational) echo engineering-workstation ;;
        ics_control|control)         echo turbine_plc ;;
        ics_dmz|dmz)                 echo ssh_bastion ;;
        *) echo "$1" ;;  # already a container name
    esac
}

# TCP connectivity probe from inside a representative in-zone container.
# bash /dev/tcp avoids needing nc inside every image.
# Usage: probe_tcp <zone-or-runner> <host> <port>
probe_tcp() {
    local runner; runner=$(_probe_runner "$1")
    local host="$2" port="$3"
    docker exec "$runner" timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# Inverse probe, succeeds when the port is NOT reachable.
# Usage: probe_tcp_blocked <zone-or-runner> <host> <port>
probe_tcp_blocked() {
    ! probe_tcp "$@"
}

# UDP probe via SNMP GET (OID sysDescr) from a representative in-zone
# container. snmpget needs to live inside that container, see Dockerfiles.
# Usage: probe_udp_snmp <zone-or-runner> <host> <community>
probe_udp_snmp() {
    local runner; runner=$(_probe_runner "$1")
    local host="$2" community="${3:-public}"
    docker exec "$runner" snmpget \
        -v2c -c "$community" -t 3 -r 1 \
        "$host" 1.3.6.1.2.1.1.1.0 2>/dev/null
}

# Check a container is running.
# Usage: container_running <name>
container_running() {
    local name="$1"
    [ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]
}

# Get a container's IP on a given network.
# Usage: container_ip <name> <network>
container_ip() {
    local name="$1"
    local zone="$2" prefix
    case "$zone" in
        ics_internet|internet)       prefix='10\.10\.0\.' ;;
        ics_enterprise|enterprise)   prefix='10\.10\.1\.' ;;
        ics_operational|operational) prefix='10\.10\.2\.' ;;
        ics_control|control)         prefix='10\.10\.3\.' ;;
        ics_wan|wan)                 prefix='10\.10\.4\.' ;;
        ics_dmz|dmz)                 prefix='10\.10\.5\.' ;;
        *)                           prefix="$zone" ;;
    esac
    docker exec "$name" ip -4 -o addr show 2>/dev/null \
        | awk '{print $4}' \
        | sed 's@/.*@@' \
        | grep -E "^${prefix}" \
        | head -1
}

# Run a command inside an existing container.
# Usage: in_container <name> <cmd...>
in_container() {
    local name="$1"; shift
    docker exec "$name" "$@" 2>&1
}

# Default Python interpreter that has paramiko available.
# attacker-machine ships paramiko in /opt/attacker-env (a venv).
# These helpers always run inside attacker-machine. The lab containers do not
# carry paramiko or any other test-only dependency.
SSH_RUNNER_PY="${SSH_RUNNER_PY:-/opt/attacker-env/bin/python3}"

# SSH password login probe via paramiko, run inside <runner>.
# Prints "SSH_OK" on successful auth, "AUTH_FAILED" or "CONNECT_ERROR: ..." otherwise.
# When <remote-cmd> is given, prints the command's stdout instead of "SSH_OK"
# (only useful when the remote shell honours non-interactive command exec).
# Usage: ssh_password_login <runner> <user> <host> <pass> [remote-cmd]
ssh_password_login() {
    local runner="$1" user="$2" host="$3" pass="$4"
    local cmd="${5:-}"
    docker exec "$runner" "$SSH_RUNNER_PY" -c "
import sys, time, paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
last_err = None
for _ in range(3):
    try:
        c.connect('$host', username='$user', password='$pass', timeout=5,
                  allow_agent=False, look_for_keys=False)
        last_err = None
        break
    except paramiko.AuthenticationException:
        # Real auth failure: do not retry, do not mask.
        print('AUTH_FAILED'); sys.exit(1)
    except Exception as e:
        last_err = e
        time.sleep(1)
if last_err is not None:
    print('CONNECT_ERROR:', last_err); sys.exit(1)
cmd = '''$cmd'''
if cmd:
    _, out, _ = c.exec_command(cmd, timeout=5)
    sys.stdout.write(out.read().decode('utf-8', errors='replace'))
else:
    print('SSH_OK')
c.close()
" 2>&1
}

# SSH key login probe via paramiko, run inside <runner>.
# Same return semantics as ssh_password_login.
# Usage: ssh_key_login <runner> <user> <host> <key-path> [remote-cmd]
ssh_key_login() {
    local runner="$1" user="$2" host="$3" keypath="$4"
    local cmd="${5:-}"
    docker exec "$runner" "$SSH_RUNNER_PY" -c "
import sys, time, paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
k = paramiko.Ed25519Key.from_private_key_file('$keypath')
last_err = None
for _ in range(3):
    try:
        c.connect('$host', username='$user', pkey=k, timeout=5,
                  allow_agent=False, look_for_keys=False)
        last_err = None
        break
    except paramiko.AuthenticationException:
        print('AUTH_FAILED'); sys.exit(1)
    except Exception as e:
        last_err = e
        time.sleep(1)
if last_err is not None:
    print('CONNECT_ERROR:', last_err); sys.exit(1)
cmd = '''$cmd'''
if cmd:
    _, out, _ = c.exec_command(cmd, timeout=5)
    sys.stdout.write(out.read().decode('utf-8', errors='replace'))
else:
    print('SSH_OK')
c.close()
" 2>&1
}

# SSH password login probe through a jump host (paramiko chained transport).
# Mirrors what 'ssh -J jump_user@jump_host target_user@target_host' does
# interactively. The lab does not need any extra software for this to work.
# Prints "SSH_OK" on successful auth to the target, error tags otherwise.
# Usage: ssh_password_login_via_jump <runner> <jump-user> <jump-host> <jump-pass> \
#                                    <target-user> <target-host> <target-pass> [remote-cmd]
ssh_password_login_via_jump() {
    local runner="$1"
    local juser="$2" jhost="$3" jpass="$4"
    local tuser="$5" thost="$6" tpass="$7"
    local cmd="${8:-}"
    docker exec "$runner" "$SSH_RUNNER_PY" -c "
import sys, time, paramiko

def connect_with_retry(client, host, **kwargs):
    last = None
    for _ in range(3):
        try:
            client.connect(host, **kwargs)
            return None
        except paramiko.AuthenticationException as e:
            return ('auth', e)
        except Exception as e:
            last = e
            time.sleep(1)
    return ('connect', last)

jump = paramiko.SSHClient()
jump.set_missing_host_key_policy(paramiko.AutoAddPolicy())
err = connect_with_retry(jump, '$jhost', username='$juser', password='$jpass',
                         timeout=5, allow_agent=False, look_for_keys=False)
if err and err[0] == 'auth':
    print('JUMP_AUTH_FAILED'); sys.exit(1)
if err:
    print('JUMP_CONNECT_ERROR:', err[1]); sys.exit(1)

try:
    chan = jump.get_transport().open_channel(
        'direct-tcpip', ('$thost', 22), ('', 0), timeout=5)
except Exception as e:
    print('JUMP_CHANNEL_ERROR:', e); sys.exit(1)

target = paramiko.SSHClient()
target.set_missing_host_key_policy(paramiko.AutoAddPolicy())
err = connect_with_retry(target, '$thost', username='$tuser', password='$tpass',
                         sock=chan, timeout=5, allow_agent=False, look_for_keys=False)
if err and err[0] == 'auth':
    print('AUTH_FAILED'); sys.exit(1)
if err:
    print('CONNECT_ERROR:', err[1]); sys.exit(1)

cmd = '''$cmd'''
if cmd:
    _, out, _ = target.exec_command(cmd, timeout=5)
    sys.stdout.write(out.read().decode('utf-8', errors='replace'))
else:
    print('SSH_OK')
target.close(); jump.close()
" 2>&1
}

# TCP reachability probe via a paramiko jump-host channel.
# Useful for "from inside the enterprise zone, can we reach <host>:<port>"
# without installing any tooling on the jump host.
# Prints "PORT_OPEN" or "PORT_CLOSED: <reason>".
# Usage: tcp_probe_via_jump <runner> <jump-user> <jump-host> <jump-pass> <target-host> <port>
tcp_probe_via_jump() {
    local runner="$1"
    local juser="$2" jhost="$3" jpass="$4"
    local thost="$5" port="$6"
    docker exec "$runner" "$SSH_RUNNER_PY" -c "
import sys, paramiko
jump = paramiko.SSHClient()
jump.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    jump.connect('$jhost', username='$juser', password='$jpass', timeout=5,
                 allow_agent=False, look_for_keys=False)
except Exception as e:
    print('JUMP_CONNECT_ERROR:', e); sys.exit(1)
try:
    chan = jump.get_transport().open_channel(
        'direct-tcpip', ('$thost', $port), ('', 0), timeout=5)
    chan.close()
    print('PORT_OPEN')
except Exception as e:
    print('PORT_CLOSED:', e); sys.exit(1)
jump.close()
" 2>&1
}

# Assert that a given pattern appears in output.
# Usage: assert_contains "<output>" "<pattern>" "<description>"
assert_contains() {
    local output="$1" pattern="$2" desc="$3"
    # Here-string avoids the printf|grep pipeline. With `set -o pipefail`, a
    # large output (> pipe buffer) plus an early `grep -q` match triggers
    # SIGPIPE on printf, which propagates as a non-zero pipeline exit and the
    # if-branch incorrectly takes the false path.
    if grep -qE -- "$pattern" <<< "$output"; then
        ok "$desc"
    else
        fail "$desc (pattern '$pattern' not found)"
    fi
}

# Assert that a given pattern does NOT appear in output.
assert_absent() {
    local output="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" <<< "$output"; then
        ok "$desc"
    else
        fail "$desc (pattern '$pattern' unexpectedly found)"
    fi
}

# Require a container to be running. Exits 2 (not 0) so a driver script can
# distinguish a real pass from a skip.
require_running() {
    local name="$1"
    if ! container_running "$name"; then
        echo "[skip] container '$name' is not running. Run './ctl up' first."
        exit 2
    fi
}

# Wait for a TCP port on <host> to accept connections, by probing from inside
# <runner>. Returns 0 once the port answers, 1 if <timeout> seconds pass first.
# Used to bridge the gap between 'docker container running' and 'service ready'
# (NFS-Ganesha + sshd take a few seconds after admin-home enters its entrypoint).
# Uses bash explicitly: /dev/tcp is a bash builtin and is missing in dash, which
# is the default 'sh' on debian-slim images.
# Usage: wait_for_port <runner> <host> <port> [timeout-seconds]
wait_for_port() {
    local runner="$1" host="$2" port="$3" timeout="${4:-30}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        # Each attempt is bounded by 'timeout 2' so a hung TCP connect on a
        # filtered port does not consume the whole window.
        if docker exec "$runner" timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}
