#!/usr/bin/env bash
# Engineering workstation, Windows 10 Enterprise LTSC facade
# Presents a Windows 10 LTSC PowerShell prompt over SSH.
# Virtual C: drive lives at /opt/win10/C.
# Machine is dual-homed: 10.10.2.30 (ops) and 10.10.3.100 (control).

VIRT_ROOT="/opt/win10/C"
VIRT_CWD="Users/engineer"

stty icrnl 2>/dev/null || true

# ── path helpers ──────────────────────────────────────────────────────────────

_resolve_ci() {
    local parent="$1" component="$2"
    [[ -e "$parent/$component" ]] && { echo "$component"; return; }
    local match
    match=$(find "$parent" -maxdepth 1 -mindepth 1 -iname "$component" \
            -printf '%f\n' 2>/dev/null | head -1)
    echo "${match:-$component}"
}

_real() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then
        echo "$VIRT_ROOT/$VIRT_CWD"; return
    fi
    v="${v//\\//}"
    v="${v#\"}"; v="${v%\"}"
    v="${v#\'}"; v="${v%\'}"
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"
        echo "$VIRT_ROOT/$v"; return
    fi
    if [[ "$v" == "~" || "$v" == "~/"* ]]; then
        v="Users/engineer/${v:2}"
        echo "$VIRT_ROOT/$v"; return
    fi
    echo "$VIRT_ROOT/$VIRT_CWD/$v"
}

_disp() {
    if [[ -z "$VIRT_CWD" ]]; then
        echo 'C:\'
    else
        echo "C:\\${VIRT_CWD//\//\\}"
    fi
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_dir() {
    local arg="${1:-}"
    local real show
    if [[ -n "$arg" ]]; then
        real="$(_real "$arg")"
        local v="${arg//\\//}"; v="${v#\"}"; v="${v%\"}"
        if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
            v="${v:2}"; v="${v#/}"
        else
            v="$VIRT_CWD/${v%/}"
        fi
        show="C:\\${v//\//\\}"
    else
        real="$(_real)"
        show="$(_disp)"
    fi
    if [[ ! -e "$real" ]]; then
        printf "Get-ChildItem: Cannot find path '%s' because it does not exist.\n" "$show"
        return
    fi
    if [[ -f "$real" ]]; then
        local parent; parent=$(dirname "$real")
        local pshow="C:\\${parent#$VIRT_ROOT/}"; pshow="${pshow//\//\\}"
        printf '\n\n    Directory: %s\n\n\n' "$pshow"
        echo 'Mode                 LastWriteTime         Length Name'
        echo '----                 -------------         ------ ----'
        printf '%s        14/03/2024   9:15 AM  %10s  %s\n' \
            '-a----' "$(stat -L -c%s "$real")" "$(basename "$real")"
        printf '\n'
        return
    fi
    printf '\n\n    Directory: %s\n\n\n' "$show"
    echo 'Mode                 LastWriteTime         Length Name'
    echo '----                 -------------         ------ ----'
    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            printf '%s        14/03/2024   9:15 AM                %s\n' 'd-----' "$name"
        else
            printf '%s        14/03/2024   9:15 AM  %10s  %s\n' \
                '-a----' "$(stat -L -c%s "$entry")" "$name"
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 -print0 | sort -z)
    printf '\n'
}

cmd_cd() {
    local arg="${1:-}"
    if [[ -z "$arg" || "$arg" == "~" ]]; then
        VIRT_CWD="Users/engineer"; return
    fi
    local v="${arg//\\//}"; v="${v#\"}"; v="${v%\"}"
    if [[ "$v" == ".." ]]; then
        local parent="${VIRT_CWD%/*}"
        [[ "$parent" == "$VIRT_CWD" ]] && parent=""
        VIRT_CWD="$parent"; return
    fi
    [[ "$v" == "." ]] && return
    local new_cwd
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"
        new_cwd="$v"
    else
        new_cwd="$VIRT_CWD/$v"
    fi
    if [[ -d "$VIRT_ROOT/$new_cwd" ]]; then
        VIRT_CWD="$new_cwd"
    else
        printf "Set-Location: Cannot find path 'C:\\%s' because it does not exist.\n" \
            "${new_cwd//\//\\}"
    fi
}

cmd_cat() {
    local arg="${1:-}"
    if [[ -z "$arg" ]]; then
        echo "Get-Content: Cannot bind argument to parameter 'Path' because it is null."
        return
    fi
    local real; real="$(_real "$arg")"
    if [[ ! -f "$real" ]]; then
        printf "Get-Content: Cannot find path '%s' because it does not exist.\n" "$arg"
        return
    fi
    cat "$real"
}

cmd_pwd() { _disp; }

cmd_whoami() { echo "ot.local\\engineer"; }

cmd_hostname() { echo "ENG-WS01"; }

cmd_ipconfig() {
    cat << 'EOF'

Windows IP Configuration


Ethernet adapter Ethernet0 (Operational Network):

   Connection-specific DNS Suffix  . : ot.local
   IPv4 Address. . . . . . . . . . . : 10.10.2.30
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . : 10.10.2.1

Ethernet adapter Ethernet1 (Control Network):

   Connection-specific DNS Suffix  . : ot.local
   IPv4 Address. . . . . . . . . . . : 10.10.3.100
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . :

EOF
}

cmd_netstat() {
    local show_pid=0
    [[ "$*" == *o* ]] && show_pid=1
    printf '\nActive Connections\n\n'
    if [[ $show_pid -eq 1 ]]; then
        printf '  Proto  Local Address          Foreign Address        State           PID\n'
        printf '  TCP    0.0.0.0:22             0.0.0.0:0              LISTENING       488\n'
        netstat -tn 2>/dev/null \
          | awk 'NR>2 && /ESTABLISHED/ {
                printf "  %-6s %-22s %-22s %-16s %s\n", "TCP", $4, $5, $6, int(1000+rand()*3000)
            }' | head -10
    else
        printf '  Proto  Local Address          Foreign Address        State\n'
        printf '  TCP    0.0.0.0:22             0.0.0.0:0              LISTENING\n'
        netstat -tn 2>/dev/null \
          | awk 'NR>2 && /ESTABLISHED/ {
                printf "  %-6s %-22s %-22s %s\n", "TCP", $4, $5, $6
            }' | head -10
    fi
    printf '\n'
}

cmd_ping() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then echo "Usage: ping hostname"; return; fi
    printf '\nPinging %s with 32 bytes of data:\n' "$target"
    if ping -c 4 -W 1 "$target" &>/dev/null; then
        for _ in 1 2 3 4; do
            printf 'Reply from %s: bytes=32 time<1ms TTL=128\n' "$target"
        done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 4, Lost = 0 (0%% loss),\n' "$target"
        printf 'Approximate round trip times in milli-seconds:\n    Minimum = 0ms, Maximum = 1ms, Average = 0ms\n\n'
    else
        for _ in 1 2 3 4; do printf 'Request timed out.\n'; done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 0, Lost = 4 (100%% loss),\n\n' "$target"
    fi
}

cmd_net() {
    local sub="${1^^}"
    case "$sub" in
        USER)
            printf '\nUser accounts for \\\\ENG-WS01\n\n'
            printf -- '-------------------------------------------------------------------------------\n'
            printf 'Administrator            engineer                 Guest\n'
            printf 'The command completed successfully.\n\n'
            ;;
        VIEW)
            printf '\nServer Name            Remark\n\n'
            printf -- '-------------------------------------------------------------------------------\n'
            printf '\\\\OT-DC-01              OT Domain Controller\n'
            printf '\\\\SCADA-SRV01           Distribution SCADA\n'
            printf '\\\\HIST-SRV01            Process Historian\n'
            printf 'The command completed successfully.\n\n'
            ;;
        USE)
            printf '\nStatus       Local     Remote                             Network\n'
            printf -- '-------------------------------------------------------------------------------\n'
            printf 'OK           P:        \\\\OT-DC-01\\projects$               Microsoft Windows Network\n'
            printf 'The command completed successfully.\n\n'
            ;;
        *)
            echo "The syntax of this command is incorrect."
            ;;
    esac
}

cmd_python() {
    local args="${1:-}"
    if [[ -z "$args" ]]; then
        echo "Python 3.11.2 (default)"
        echo "Type 'exit()' or Ctrl+D to quit."
        return
    fi
    # Handle -c "code", strip one layer of surrounding quotes if present
    if [[ "$args" == "-c "* || "$args" == "-c	"* ]]; then
        local code="${args#-c }"
        code="${code#-c	}"
        if [[ "$code" == '"'*'"' ]]; then code="${code#\"}"; code="${code%\"}"; fi
        if [[ "$code" == "'"*"'" ]]; then code="${code#\'}"; code="${code%\'}"; fi
        /venv/bin/python3 -c "$code"
        return
    fi
    # File mode: first word is the script path, remainder are args
    local script="${args%% *}"
    local script_args=""
    [[ "$args" == *" "* ]] && script_args="${args#* }"
    local real; real="$(_real "$script")"
    if [[ ! -f "$real" ]]; then
        printf "python: can't open file '%s': [Errno 2] No such file or directory\n" "$script"
        return
    fi
    /venv/bin/python3 "$real" $script_args
}

cmd_ip() { /sbin/ip "$@"; }

cmd_ssh()  { /usr/bin/ssh -o StrictHostKeyChecking=no "$@"; }
cmd_curl() { /usr/bin/curl "$@"; }
cmd_nmap() { /usr/bin/nmap "$@"; }
cmd_nc()   { /usr/bin/nc "$@"; }

# Bash functions used by eval "$line" dispatch, handle quoted args correctly
ssh()  { /usr/bin/ssh -o StrictHostKeyChecking=no "$@"; }
curl() { /usr/bin/curl "$@"; printf '\n'; }
wget() { /usr/bin/wget "$@"; printf '\n'; }
nmap() { /usr/bin/nmap "$@"; }
nc()   { /usr/bin/nc "$@"; }

cmd_schtasks() {
    # Vendor-default Windows Task Scheduler CLI surface. The facade pipes
    # everything through the user's crontab, so a "scheduled task" is a
    # cron entry tagged with `# SCHTASK:<name>` for identification on
    # delete and query. Real Windows uses Task Scheduler XML; we keep the
    # surface argument-compatible enough that runbook visitors who know
    # `schtasks /create /tn ... /tr ... /sc minute` find what they expect.
    local args="$*"
    local action=""
    case "${args,,}" in
        /create*) action=create ;;
        /delete*) action=delete ;;
        /query*)  action=query  ;;
        ""|/?|/help)
            cat <<'HLP'
SCHTASKS /Create /TN <taskname> /TR "<command>" /SC MINUTE [/MO <n>]
SCHTASKS /Delete /TN <taskname> [/F]
SCHTASKS /Query
HLP
            return
            ;;
        *) printf 'ERROR: Invalid argument/option - %s.\n' "${args%% *}"; return ;;
    esac

    if [[ "$action" == "create" ]]; then
        local name="" cmd=""
        local rest="${args#/[Cc][Rr][Ee][Aa][Tt][Ee]}"
        # /TN <name>
        if [[ "$rest" =~ /[Tt][Nn][[:space:]]+([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[1]}"
        fi
        # /TR "..."  (quoted) or unquoted single token
        if [[ "$rest" =~ /[Tt][Rr][[:space:]]+\"([^\"]+)\" ]]; then
            cmd="${BASH_REMATCH[1]}"
        elif [[ "$rest" =~ /[Tt][Rr][[:space:]]+([^[:space:]]+) ]]; then
            cmd="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$name" || -z "$cmd" ]]; then
            echo "ERROR: /TN and /TR are required."
            return
        fi
        local marker="# SCHTASK:$name"
        local current; current="$(/usr/bin/crontab -l 2>/dev/null)"
        # Drop any existing entry with the same name, then append fresh.
        current="$(printf '%s\n' "$current" | grep -v "$marker"'$' || true)"
        { [[ -n "$current" ]] && printf '%s\n' "$current"
          printf '* * * * * %s  %s\n' "$cmd" "$marker"
        } | /usr/bin/crontab -
        printf 'SUCCESS: The scheduled task "%s" has successfully been created.\n' "$name"
    elif [[ "$action" == "delete" ]]; then
        local name=""
        if [[ "$args" =~ /[Tt][Nn][[:space:]]+([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$name" ]]; then
            echo "ERROR: /TN is required."
            return
        fi
        local marker="# SCHTASK:$name"
        local current; current="$(/usr/bin/crontab -l 2>/dev/null | grep -v "$marker"'$' || true)"
        if [[ -z "$current" ]]; then
            /usr/bin/crontab -r 2>/dev/null
        else
            printf '%s\n' "$current" | /usr/bin/crontab -
        fi
        printf 'SUCCESS: The scheduled task "%s" was successfully deleted.\n' "$name"
    elif [[ "$action" == "query" ]]; then
        local listing; listing="$(/usr/bin/crontab -l 2>/dev/null | grep '# SCHTASK:' || true)"
        if [[ -z "$listing" ]]; then
            echo "INFO: There are no scheduled tasks on the computer."
            return
        fi
        printf '\n%-32s %-9s\n' "TaskName" "Schedule"
        printf '%-32s %-9s\n' "--------" "--------"
        while IFS= read -r line; do
            local n="${line##*# SCHTASK:}"
            printf '%-32s %-9s\n' "$n" "Per Minute"
        done <<< "$listing"
    fi
}

cmd_route() {
    /venv/bin/python3 << 'PYEOF'
import subprocess, ipaddress

FAKE_MACS = ['aac1ab3f18f2', 'aac1ab8520f9']

def iface_mac(iface, _c=[0]):
    m = FAKE_MACS[_c[0]] if _c[0] < len(FAKE_MACS) else '000000000000'
    _c[0] += 1
    return m

def iface_addr(iface):
    try:
        out = subprocess.check_output(['ip','-4','addr','show',iface], text=True,
                                      stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            if 'inet ' in line:
                return line.split()[1].split('/')[0]
    except Exception:
        pass
    return ''

routes_raw = subprocess.check_output(['ip','-4','route','show'], text=True,
                                     stderr=subprocess.DEVNULL)
addr_raw   = subprocess.check_output(['ip','-4','addr','show'], text=True,
                                     stderr=subprocess.DEVNULL)

ifaces = []
cur_iface = ''
for line in addr_raw.splitlines():
    if line and line[0].isdigit():
        cur_iface = line.split(':')[1].strip().split('@')[0]
    elif 'inet ' in line and cur_iface and cur_iface != 'lo':
        ifaces.append((cur_iface, iface_mac(cur_iface), iface_addr(cur_iface)))

rows = []
for line in routes_raw.splitlines():
    parts = line.split()
    if not parts: continue
    dest = parts[0]; gw = src = dev = ''
    i = 1
    while i < len(parts):
        if   parts[i] == 'via':  gw  = parts[i+1]; i += 2
        elif parts[i] == 'dev':  dev = parts[i+1]; i += 2
        elif parts[i] == 'src':  src = parts[i+1]; i += 2
        else: i += 1
    if dest == 'default': net, mask = '0.0.0.0', '0.0.0.0'; metric = 25
    else:
        n = ipaddress.ip_network(dest, strict=False)
        net, mask = str(n.network_address), str(n.netmask); metric = 281
    if not gw:  gw  = 'On-link'
    if not src and dev: src = iface_addr(dev)
    rows.append((net, mask, gw, src, metric))
    if net != '0.0.0.0' and src:
        bcast = str(ipaddress.ip_network(f'{src}/{mask}', strict=False).broadcast_address)
        rows.append((src,   '255.255.255.255', 'On-link', src, 281))
        rows.append((bcast, '255.255.255.255', 'On-link', src, 281))

for r in [('127.0.0.0','255.0.0.0','On-link','127.0.0.1',331),
          ('127.0.0.1','255.255.255.255','On-link','127.0.0.1',331),
          ('127.255.255.255','255.255.255.255','On-link','127.0.0.1',331),
          ('224.0.0.0','240.0.0.0','On-link','127.0.0.1',331),
          ('255.255.255.255','255.255.255.255','On-link','127.0.0.1',331)]:
    rows.append(r)

sep = '=' * 75
print(sep)
print('Interface List')
for num, (nm, mac, _) in enumerate(ifaces):
    label = f' #{num+1}' if num > 0 else ''
    print(f' {num+2:>2}...{mac} ......Intel(R) PRO/1000 MT Network Connection{label}')
print('  1...........................Software Loopback Interface 1')
print(sep)
print()
print('IPv4 Route Table')
print(sep)
print('Active Routes:')
print(f"{'Network Destination':>27} {'Netmask':>16} {'Gateway':>14} {'Interface':>14} {'Metric':>6}")
for net, mask, gw, src, metric in rows:
    print(f"{net:>27} {mask:>16} {gw:>14} {src:>14} {metric:>6}")
print(sep)
print()
print('Persistent Routes:')
print('  None')
PYEOF
}

cmd_iwr() {
    local uri="" outfile="" infile="" method="GET" body="" content_type="" auth_header=""
    while [[ $# -gt 0 ]]; do
        case "${1,,}" in
            -uri)            shift; uri="$1" ;;
            -outfile)        shift; outfile="$(_real "$1")" ;;
            -infile)         shift; infile="$(_real "$1")" ;;
            -method)         shift; method="${1^^}" ;;
            -body)           shift; body="$1" ;;
            -contenttype)    shift; content_type="$1" ;;
            -headers)
                shift
                if [[ "$1" =~ [Aa]uthorization=([^}]+) ]]; then
                    auth_header="Authorization: ${BASH_REMATCH[1]%\}}"
                    auth_header="${auth_header%\"}"
                    auth_header="${auth_header% }"
                fi
                ;;
            -maximumredirection|-disablekeepalive|-usebasicparsing|-sessionvariable)
                shift ;;
            http://*|https://*) uri="$1" ;;
        esac
        shift
    done
    [[ -z "$uri" ]] && { echo "Invoke-WebRequest: URI parameter required."; return; }
    local -a curl_args=(-s)
    [[ "$method" != "GET" ]] && curl_args+=(-X "$method")
    [[ -n "$body" ]]         && curl_args+=(-d "$body")
    [[ -n "$infile" ]]       && curl_args+=(--data-binary "@$infile")
    [[ -n "$content_type" ]] && curl_args+=(-H "Content-Type: $content_type")
    [[ -n "$auth_header" ]]  && curl_args+=(-H "$auth_header")
    if [[ -n "$outfile" ]]; then
        /usr/bin/curl "${curl_args[@]}" "$uri" -o "$outfile"
        return
    fi
    local raw
    raw=$(/usr/bin/curl "${curl_args[@]}" -i --max-redirs 0 "$uri" 2>/dev/null)
    IWR_RAW="$raw" /venv/bin/python3 << 'PYEOF'
import os

raw = os.environ.get('IWR_RAW', '')
if '\r\n\r\n' in raw:
    hdr_raw, body = raw.split('\r\n\r\n', 1)
elif '\n\n' in raw:
    hdr_raw, body = raw.split('\n\n', 1)
else:
    hdr_raw, body = raw, ''

body = body.rstrip('\n')
lines = [l.rstrip('\r') for l in hdr_raw.splitlines()]
status_line = lines[0] if lines else ''
parts = status_line.split(None, 2)
code = parts[1] if len(parts) > 1 else '0'
desc = parts[2] if len(parts) > 2 else ''
hdr_lines = [l for l in lines[1:] if l]
body_lines = body.splitlines() if body else ['']

print()
print(f'StatusCode        : {code}')
print(f'StatusDescription : {desc}')
print(f'Content           : {body_lines[0]}')
for l in body_lines[1:]:
    print(f'                    {l}')
print(f'RawContent        : {status_line}')
for h in hdr_lines:
    print(f'                    {h}')
print('                    ')
for l in body_lines:
    print(f'                    {l}')
print('Forms             : {}')
hdict = ', '.join(f'[{h.split(": ",1)[0]}, {h.split(": ",1)[1]}]'
                  for h in hdr_lines if ': ' in h)
print(f'Headers           : {{{hdict}}}')
print('Images            : {}')
print('InputFields       : {}')
print('Links             : {}')
print('ParsedHtml        : mshtml.HTMLDocumentClass')
print(f'RawContentLength  : {len(body.encode())}')
print()
PYEOF
}

cmd_help() {
    cat << 'EOF'

Name                          Alias            Description
----                          -----            -----------
Set-Location                  cd, sl           Change the current directory
Get-ChildItem                 dir, ls, gci     List directory contents
Get-Content                   cat, type, gc    Display file contents
Get-Location                  pwd, gl          Show current path
Clear-Host                    cls, clear       Clear the screen
Invoke-WebRequest             iwr, curl, wget  Send an HTTP/HTTPS request

System commands available on this machine:
  whoami, hostname, ipconfig, netstat, ping, net, ssh, nmap, nc
  python, python3

EOF
}

# ── command dispatch ──────────────────────────────────────────────────────────
# _dispatch handles a single command line. Used by both the interactive REPL
# and by the -c "<cmd>" non-interactive path. Real Windows shells accept
# inline commands (PowerShell -Command, cmd /c); this facade matches that so
# `ssh user@host '<cmd>'` works without forcing visitors into the prompt
# first.

_dispatch() {
    local line="$1"
    line="${line//$'\r'/}"
    line="${line%"${line##*[^ ]}"}"

    if [[ "$line" =~ ^\$[A-Za-z_][A-Za-z0-9_]*= ]]; then
        eval "${line:1}" 2>/dev/null || true
        return
    fi

    line="${line#.\\}"; line="${line#./}"
    local cmd rest
    read -r cmd rest <<< "$line"

    case "${cmd,,}" in
        cd|set-location|sl)         cmd_cd "$rest" ;;
        dir|ls|get-childitem|gci)   cmd_dir "$rest" ;;
        cat|type|get-content|gc)    cmd_cat "$rest" ;;
        pwd|get-location|gl)        cmd_pwd ;;
        cls|clear|clear-host)       clear ;;
        whoami)                     cmd_whoami ;;
        hostname)                   cmd_hostname ;;
        ipconfig)                   cmd_ipconfig ;;
        netstat)                    cmd_netstat $rest ;;
        ip)                         cmd_ip $rest ;;
        ping)                       cmd_ping $rest ;;
        net)    read -r sub _ <<< "$rest"; cmd_net "$sub" ;;
        ssh)                        eval "$line" ;;
        curl|wget)                  eval "${line//-o NUL/-o /dev/null}" ;;
        socat)                      eval "$line" ;;
        openssl)                    eval "$line" ;;
        route)                      [[ "${rest,,}" == "print"* ]] && cmd_route || printf "'route %s' is not recognised\n" "$rest" ;;
        invoke-webrequest|iwr)      eval cmd_iwr "${rest//\\/\\\\}" ;;
        nmap)                       eval "$line" ;;
        nc)                         eval "$line" ;;
        python|python3)             cmd_python "$rest" ;;
        *.py)                       cmd_python "$cmd $rest" ;;
        schtasks)                   cmd_schtasks $rest ;;
        help|get-help)              cmd_help ;;
        exit|quit|logout)           printf '\n'; exit 0 ;;
        "")                         true ;;
        *)
            printf "'%s' is not recognized as the name of a cmdlet, function, script file,\nor operable program. Check the spelling of the name, or if a path was\nincluded, verify that the path is correct and try again.\n" "$cmd" ;;
    esac
}

# Non-interactive command exec: ssh user@host '<cmd>' invokes the shell as
# `<shell> -c '<cmd>'`. Dispatch the single line and exit.
if [[ "${1:-}" == "-c" && $# -ge 2 ]]; then
    _dispatch "$2"
    exit
fi

# ── banner ────────────────────────────────────────────────────────────────────

clear
cat << 'BANNER'
Windows PowerShell
Copyright (C) Microsoft Corporation. All rights reserved.

Try the new cross-platform PowerShell https://aka.ms/pscore6

BANNER

cat << 'LOGON'
*******************************************************************************
*                                                                             *
*   Unseen University Power & Light Co.                                       *
*   ENG-WS01, Engineering Workstation (Windows 10 Enterprise LTSC)          *
*                                                                             *
*   WARNING: This system has direct access to ICS/OT plant equipment.        *
*   Authorised engineers only. All activity is logged.                        *
*   Contact: Ponder Stibbons, ext 201 / ponder.stibbons@uupl.am             *
*                                                                             *
*******************************************************************************

LOGON

# ── main loop ─────────────────────────────────────────────────────────────────
# Ctrl+C kills the foreground command and returns to the prompt.
# trap ':' INT (not '') keeps children using the default SIGINT disposition,
# so nmap / python die normally. The shell itself runs ':' and stays alive.
trap ':' INT

while true; do
    printf 'PS %s> ' "$(_disp)"
    IFS= read -r line
    case $? in
        0) ;;                              # normal input
        1) break ;;                        # EOF or Ctrl-D, exit shell
        *) printf '\n'; continue ;;        # signal-interrupted read, re-prompt
    esac

    # Line continuation: trailing backtick joins the next line (PowerShell convention)
    while [[ "$line" == *\` ]]; do
        line="${line%\`}"
        printf '>> '
        IFS= read -r cont || break
        cont="${cont//$'\r'/}"
        cont="${cont%"${cont##*[^ ]}"}"
        line="${line} ${cont}"
    done

    _dispatch "$line"
done
