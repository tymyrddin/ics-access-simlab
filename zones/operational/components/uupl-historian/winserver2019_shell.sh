#!/usr/bin/env bash
# Historian, Windows Server 2019 facade
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

_mtime() {
    stat -c '%y' "$1" 2>/dev/null | awk '{
        split($1,d,"-"); split($2,t,":")
        h=int(t[1]); m=int(t[2])
        ap="AM"; if(h>=12){ap="PM"; if(h>12)h-=12} if(h==0)h=12
        printf "%s/%s/%s %3d:%02d %s", d[3],d[2],d[1],h,m,ap
    }'
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
        printf '%s        %-20s  %10s  %s\n' '-a----' "$(_mtime "$real")" "$(stat -L -c%s "$real")" "$(basename "$real")"
        printf '\n'; return
    fi
    printf '\n\n    Directory: %s\n\n\n' "$show"
    echo 'Mode                 LastWriteTime         Length Name'
    echo '----                 -------------         ------ ----'
    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            printf '%s        %-20s               %s\n' 'd-----' "$(_mtime "$entry")" "$name"
        else
            printf '%s        %-20s  %10s  %s\n' '-a----' "$(_mtime "$entry")" "$(stat -L -c%s "$entry")" "$name"
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
    local default_gw default_dev
    default_gw=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}')
    default_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
    printf '\nWindows IP Configuration\n\n\n'
    local adapter_idx=0
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local cidr; cidr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2;exit}')
        [[ -z "$cidr" ]] && continue
        local ip="${cidr%%/*}" prefix="${cidr##*/}"
        local full=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
        local mask; mask=$(printf '%d.%d.%d.%d' \
            $(( (full >> 24) & 255 )) $(( (full >> 16) & 255 )) \
            $(( (full >> 8)  & 255 )) $(( full & 255 )))
        local label
        case "$ip" in
            10.10.0.*) label="Internet" ;;
            10.10.1.*) label="Enterprise Network" ;;
            10.10.2.*) label="Operational Network" ;;
            10.10.3.*) label="Control Network" ;;
            10.10.5.*) label="DMZ" ;;
            *)         label="Ethernet" ;;
        esac
        local gw; [[ "$iface" == "$default_dev" ]] && gw="$default_gw" || gw=""
        printf 'Ethernet adapter Ethernet%d (%s):\n\n' "$adapter_idx" "$label"
        printf '   Connection-specific DNS Suffix  . : ot.local\n'
        printf '   IPv4 Address. . . . . . . . . . . : %s\n' "$ip"
        printf '   Subnet Mask . . . . . . . . . . . : %s\n' "$mask"
        printf '   Default Gateway . . . . . . . . . : %s\n\n' "$gw"
        (( adapter_idx++ ))
    done < <(ip -4 addr show 2>/dev/null | awk '
        /^[0-9]+:/ { iface=$2; gsub(/:$/,"",iface); gsub(/@.*/,"",iface) }
        /inet /    { if (iface != "lo") print iface }
    ')
}

cmd_netstat() {
    local show_pid=0
    [[ "$*" == *o* ]] && show_pid=1
    printf '\nActive Connections\n\n'
    if [[ $show_pid -eq 1 ]]; then
        printf '  Proto  Local Address          Foreign Address        State           PID\n'
        ss -tlnp 2>/dev/null | awk 'NR>1 {
            addr=$4; sub(/^\*:/, "0.0.0.0:", addr)
            printf "  %-6s %-22s %-22s %-16s %d\n", "TCP", addr, "0.0.0.0:0", "LISTENING", int(100+rand()*3000)
        }'
        netstat -tn 2>/dev/null \
          | awk 'NR>2 && /ESTABLISHED/ {
                printf "  %-6s %-22s %-22s %-16s %s\n", "TCP", $4, $5, $6, int(1000+rand()*3000)
            }' | head -8
    else
        printf '  Proto  Local Address          Foreign Address        State\n'
        ss -tlnp 2>/dev/null | awk 'NR>1 {
            addr=$4; sub(/^\*:/, "0.0.0.0:", addr)
            printf "  %-6s %-22s %-22s %s\n", "TCP", addr, "0.0.0.0:0", "LISTENING"
        }'
        netstat -tn 2>/dev/null \
          | awk 'NR>2 && /ESTABLISHED/ {
                printf "  %-6s %-22s %-22s %s\n", "TCP", $4, $5, $6
            }' | head -8
    fi
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
            printf -- '-------------------------------------------------------------------------------\n'
            printf 'Administrator            hist_admin               Guest\n'
            printf 'The command completed successfully.\n\n' ;;
        VIEW)
            printf '\nServer Name            Remark\n\n'
            printf -- '-------------------------------------------------------------------------------\n'
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
    local uri="" method="GET" content_type="" body="" outfile="" infile="" auth_header=""
    while [[ $# -gt 0 ]]; do
        case "${1,,}" in
            -uri)         shift; uri="$1" ;;
            -method)      shift; method="${1^^}" ;;
            -contenttype) shift; content_type="$1" ;;
            -body)        shift; body="$1" ;;
            -outfile)     shift; outfile="$1" ;;
            -infile)      shift; infile="$(_real "$1")" ;;
            -headers)
                shift
                # eval may strip double quotes; match value up to closing }
                if [[ "$1" =~ Authorization=([^}]+) ]]; then
                    local _v="${BASH_REMATCH[1]}"
                    _v="${_v#\"}"; _v="${_v%\"}"
                    auth_header="Authorization: $_v"
                fi ;;
            http://*|https://*) uri="$1" ;;
        esac
        shift
    done
    [[ -z "$uri" ]] && { echo "Invoke-WebRequest: URI parameter required."; return; }
    local args=(-s -X "$method")
    [[ -n "$auth_header" ]]  && args+=(-H "$auth_header")
    [[ -n "$content_type" ]] && args+=(-H "Content-Type: $content_type")
    [[ -n "$body" ]]         && args+=(--data-raw "$body")
    [[ -n "$infile" ]]       && args+=(--data-binary "@$infile")
    [[ -n "$outfile" ]]      && args+=(-o "$outfile")
    /usr/bin/curl "${args[@]}" "$uri"
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

# ── command dispatch ──────────────────────────────────────────────────────────
# _dispatch handles a single command line. Used by both the interactive REPL
# and the -c "<cmd>" non-interactive path so SSH command exec works the way
# real PowerShell would.

_dispatch() {
    local line="$1"
    line="${line//$'\r'/}"
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
        ping)                       cmd_ping $rest ;;
        net)    read -r sub _ <<< "$rest"; cmd_net "$sub" ;;
        ssh)                        eval "$line" ;;
        curl|wget)                  eval "$line" ;;
        invoke-webrequest|iwr)      eval cmd_iwr "${rest//\\/\\\\}" ;;
        nmap)                       eval "$line" ;;
        nc)                         eval "$line" ;;
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

BANNER

cat << 'LOGON'
*******************************************************************************
*                                                                             *
*   Unseen University Power & Light Co.                                       *
*   HIST-SRV01, Process Historian Server (Windows Server 2019)              *
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
    _dispatch "$line"
done
