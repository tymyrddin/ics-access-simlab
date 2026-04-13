#!/usr/bin/env bash
# Historian — Windows Server 2019 facade
# Presents a Windows Server 2019 PowerShell prompt over SSH.
# Virtual C: drive lives at /opt/winsvr/C.

VIRT_ROOT="/opt/winsvr/C"
VIRT_CWD="Users/hist_admin"

stty icrnl 2>/dev/null || true

# ── path helpers ──────────────────────────────────────────────────────────────

_real() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then echo "$VIRT_ROOT/$VIRT_CWD"; return; fi
    v="${v//\\//}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"; echo "$VIRT_ROOT/$v"; return
    fi
    if [[ "$v" == "~" || "$v" == "~/"* ]]; then
        echo "$VIRT_ROOT/Users/hist_admin/${v:2}"; return
    fi
    echo "$VIRT_ROOT/$VIRT_CWD/$v"
}

_disp() {
    [[ -z "$VIRT_CWD" ]] && { echo 'C:\'; return; }
    echo "C:\\${VIRT_CWD//\//\\}"
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_dir() {
    local arg="${1:-}"
    local real show
    if [[ -n "$arg" ]]; then
        real="$(_real "$arg")"
        local v="${arg//\\//}"; v="${v#\"}"; v="${v%\"}"; v="${v:2}"; v="${v#/}"
        show="C:\\${v//\//\\}"
    else
        real="$(_real)"; show="$(_disp)"
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
        printf '%s        14/03/2024   9:15 AM  %10s  %s\n' '-a----' "$(stat -c%s "$real")" "$(basename "$real")"
        printf '\n'; return
    fi
    printf '\n\n    Directory: %s\n\n\n' "$show"
    echo 'Mode                 LastWriteTime         Length Name'
    echo '----                 -------------         ------ ----'
    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            printf '%s        14/03/2024   9:15 AM                %s\n' 'd-----' "$name"
        else
            printf '%s        14/03/2024   9:15 AM  %10s  %s\n' '-a----' "$(stat -c%s "$entry")" "$name"
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 -print0 | sort -z)
    printf '\n'
}

cmd_cd() {
    local arg="${1:-}"
    if [[ -z "$arg" || "$arg" == "~" ]]; then VIRT_CWD="Users/hist_admin"; return; fi
    local v="${arg//\\//}"; v="${v#\"}"; v="${v%\"}"
    if [[ "$v" == ".." ]]; then
        local parent="${VIRT_CWD%/*}"; [[ "$parent" == "$VIRT_CWD" ]] && parent=""
        VIRT_CWD="$parent"; return
    fi
    [[ "$v" == "." ]] && return
    local new_cwd
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"; new_cwd="$v"
    else
        new_cwd="$VIRT_CWD/$v"
    fi
    if [[ -d "$VIRT_ROOT/$new_cwd" ]]; then
        VIRT_CWD="$new_cwd"
    else
        printf "Set-Location: Cannot find path 'C:\\%s' because it does not exist.\n" "${new_cwd//\//\\}"
    fi
}

cmd_cat() {
    local arg="${1:-}"
    [[ -z "$arg" ]] && { echo "Get-Content: Cannot bind argument to parameter 'Path' because it is null."; return; }
    local real; real="$(_real "$arg")"
    [[ ! -f "$real" ]] && { printf "Get-Content: Cannot find path '%s' because it does not exist.\n" "$arg"; return; }
    cat "$real"
}

cmd_pwd()      { _disp; }
cmd_whoami()   { echo "ot.local\\hist_admin"; }
cmd_hostname() { echo "HIST-SRV01"; }

cmd_ipconfig() {
    cat << 'EOF'

Windows IP Configuration


Ethernet adapter Ethernet0 (Operational Network):

   Connection-specific DNS Suffix  . : ot.local
   IPv4 Address. . . . . . . . . . . : 10.10.2.10
   Subnet Mask . . . . . . . . . . . : 255.255.255.0
   Default Gateway . . . . . . . . . : 10.10.2.1

EOF
}

cmd_netstat() {
    printf '\nActive Connections\n\n'
    printf '  Proto  Local Address          Foreign Address        State\n'
    printf '  TCP    0.0.0.0:22             0.0.0.0:0              LISTENING\n'
    printf '  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING\n'
    netstat -tn 2>/dev/null \
      | awk 'NR>2 && /ESTABLISHED/ {
            printf "  %-6s %-22s %-22s %s\n", "TCP", $4, $5, $6
        }' | head -8
    printf '\n'
}

cmd_ping() {
    local target="${1:-}"
    [[ -z "$target" ]] && { echo "Usage: ping hostname"; return; }
    printf '\nPinging %s with 32 bytes of data:\n' "$target"
    if ping -c 4 -W 1 "$target" &>/dev/null; then
        for _ in 1 2 3 4; do printf 'Reply from %s: bytes=32 time<1ms TTL=128\n' "$target"; done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 4, Lost = 0 (0%% loss),\n\n' "$target"
    else
        for _ in 1 2 3 4; do printf 'Request timed out.\n'; done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 0, Lost = 4 (100%% loss),\n\n' "$target"
    fi
}

cmd_net() {
    local sub="${1^^}"
    case "$sub" in
        USER)
            printf '\nUser accounts for \\\\HIST-SRV01\n\n'
            printf '-------------------------------------------------------------------------------\n'
            printf 'Administrator            hist_admin               Guest\n'
            printf 'The command completed successfully.\n\n' ;;
        VIEW)
            printf '\nServer Name            Remark\n\n'
            printf '-------------------------------------------------------------------------------\n'
            printf '\\\\OT-DC-01              OT Domain Controller\n'
            printf '\\\\SCADA-SRV01           Distribution SCADA\n'
            printf '\\\\ENG-WS01              Engineering Workstation\n'
            printf 'The command completed successfully.\n\n' ;;
        *) echo "The syntax of this command is incorrect." ;;
    esac
}

cmd_ssh()  { /usr/bin/ssh -o StrictHostKeyChecking=no "$@"; }
cmd_curl() { /usr/bin/curl "$@"; }
cmd_nmap() { /usr/bin/nmap "$@"; }
cmd_nc()   { /usr/bin/nc "$@"; }

cmd_iwr() {
    local uri="" outfile=""
    while [[ $# -gt 0 ]]; do
        case "${1,,}" in
            -uri) shift; uri="$1" ;;
            -outfile) shift; outfile="$1" ;;
            http://*|https://*) uri="$1" ;;
        esac
        shift
    done
    [[ -z "$uri" ]] && { echo "Invoke-WebRequest: URI parameter required."; return; }
    [[ -n "$outfile" ]] && { /usr/bin/curl -s "$uri" -o "$outfile"; return; }
    /usr/bin/curl -s "$uri"
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

System commands: whoami, hostname, ipconfig, netstat, ping, net, ssh, nmap, nc, curl

EOF
}

# ── banner ────────────────────────────────────────────────────────────────────

clear
cat << 'BANNER'
Windows PowerShell
Copyright (C) Microsoft Corporation. All rights reserved.

BANNER

cat << 'LOGON'
*******************************************************************************
*                                                                             *
*   Unseen University Power & Light Co.                                       *
*   HIST-SRV01 — Process Historian Server (Windows Server 2019)              *
*                                                                             *
*   This system stores all plant time-series data since 1997.                *
*   Authorised personnel only. Contact: Ponder Stibbons (ext 201).           *
*                                                                             *
*******************************************************************************

LOGON

# ── main loop ─────────────────────────────────────────────────────────────────

while true; do
    printf 'PS %s> ' "$(_disp)"
    IFS= read -r line || break
    line="${line//$'\r'/}"
    line="${line#.\\}"; line="${line#./}"
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
        netstat)                    cmd_netstat ;;
        ping)                       cmd_ping $rest ;;
        net)    read -r sub _ <<< "$rest"; cmd_net "$sub" ;;
        ssh)                        cmd_ssh $rest ;;
        curl|wget)                  cmd_curl $rest ;;
        invoke-webrequest|iwr)      cmd_iwr $rest ;;
        nmap)                       cmd_nmap $rest ;;
        nc)                         cmd_nc $rest ;;
        help|get-help)              cmd_help ;;
        exit|quit|logout)           printf '\n'; exit 0 ;;
        "")                         true ;;
        *)
            printf "'%s' is not recognized as the name of a cmdlet, function, script file,\nor operable program. Check the spelling of the name, or if a path was\nincluded, verify that the path is correct and try again.\n" "$cmd" ;;
    esac
done
