#!/usr/bin/env bash
# Enterprise workstation, Windows 10 PowerShell facade
# Presents a Windows 10 PowerShell prompt over SSH.
# Virtual C: drive lives at /opt/win10/C with proper mixed-case names.

VIRT_ROOT="/opt/win10/C"
VIRT_CWD="Users/bursardesk"   # start in user home

# Make the underlying process cwd match the facade's virtual cwd so
# relative paths in dispatched commands (iwr -OutFile foo.db,
# sqlite3 foo.db, etc.) hit the same files that dir/type see.
cd "$VIRT_ROOT/$VIRT_CWD" 2>/dev/null || true

stty icrnl 2>/dev/null || true

# ── path helpers ─────────────────────────────────────────────────────────────

# Resolve a single path component case-insensitively under a real directory.
_resolve_ci() {
    local parent="$1" component="$2"
    [[ -e "$parent/$component" ]] && { echo "$component"; return; }
    local match
    match=$(find "$parent" -maxdepth 1 -mindepth 1 -iname "$component" \
            -printf '%f\n' 2>/dev/null | head -1)
    echo "${match:-$component}"
}

# Convert a virtual Windows path to a real Linux path.
# Accepts: relative, C:\absolute, or empty (= cwd).
_real() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then
        echo "$VIRT_ROOT/$VIRT_CWD"; return
    fi

    v="${v//\\//}"                      # backslash → slash

    # Strip surrounding quotes
    v="${v#\"}"; v="${v%\"}"
    v="${v#\'}"; v="${v%\'}"

    # Absolute: C:/... or /...
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"
        echo "$VIRT_ROOT/$v"; return
    fi

    # Home shorthand
    if [[ "$v" == "~" || "$v" == "~/"* ]]; then
        v="Users/bursardesk/${v:2}"
        echo "$VIRT_ROOT/$v"; return
    fi

    # Relative
    echo "$VIRT_ROOT/$VIRT_CWD/$v"
}

# Display current path as C:\Windows\Style
_disp() {
    if [[ -z "$VIRT_CWD" ]]; then
        echo 'C:\'
    else
        echo "C:\\${VIRT_CWD//\//\\}"
    fi
}

_mtime() {
    stat -c '%y' "$1" 2>/dev/null | awk '{
        split($1,d,"-"); split($2,t,":")
        h=int(t[1]); m=int(t[2])
        ap="AM"; if(h>=12){ap="PM"; if(h>12)h-=12} if(h==0)h=12
        printf "%s/%s/%s %3d:%02d %s", d[3],d[2],d[1],h,m,ap
    }'
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_dir() {
    local rawargs="${1:-}" recurse=0 filter="" target=""
    local -a parts
    read -ra parts <<< "$rawargs"

    local next_is_filter=0
    for part in "${parts[@]}"; do
        if [[ "$next_is_filter" -eq 1 ]]; then
            filter="$part"; next_is_filter=0; continue
        fi
        case "${part^^}" in
            /S|-RECURSE) recurse=1 ;;
            -FILTER)     next_is_filter=1 ;;
            *)
                if [[ "$part" == *"*"* || "$part" == *"?"* ]]; then
                    filter="$part"
                elif [[ -n "$part" ]]; then
                    target="$part"
                fi
                ;;
        esac
    done

    local real show
    if [[ -n "$target" ]]; then
        real="$(_real "$target")"
        local v="${target//\\//}"; v="${v#\"}"; v="${v%\"}"
        if [[ "${v^^}" == C:* ]]; then
            v="${v:2}"; v="${v#/}"
            show="C:\\${v//\//\\}"
        else
            local full="${VIRT_CWD}/${v}"; full="${full%/}"
            show="C:\\${full//\//\\}"
        fi
    else
        real="$(_real)"
        show="$(_disp)"
    fi

    if [[ ! -e "$real" ]]; then
        printf "Get-ChildItem: Cannot find path '%s' because it does not exist.\n" "$show"
        return
    fi

    if [[ "$recurse" -eq 1 ]]; then
        local find_args=(-type f)
        [[ -n "$filter" ]] && find_args+=(-iname "$filter")
        local results
        results=$(find "$real" "${find_args[@]}" 2>/dev/null | sort)
        if [[ -z "$results" ]]; then
            printf 'Get-ChildItem: No files found matching the filter.\n'
            return
        fi
        local last_dir=""
        while IFS= read -r entry; do
            local dir; dir=$(dirname "$entry")
            local name; name=$(basename "$entry")
            local dshow="C:\\${dir#$VIRT_ROOT/}"; dshow="${dshow//\//\\}"
            if [[ "$dir" != "$last_dir" ]]; then
                printf '\n\n    Directory: %s\n\n\n' "$dshow"
                echo 'Mode                 LastWriteTime         Length Name'
                echo '----                 -------------         ------ ----'
                last_dir="$dir"
            fi
            printf '%s        %-20s  %10s  %s\n' \
                '-a----' "$(_mtime "$entry")" "$(stat -c%s "$entry")" "$name"
        done <<< "$results"
        printf '\n'
        return
    fi

    if [[ -f "$real" ]]; then
        local parent; parent=$(dirname "$real")
        local pshow="C:\\${parent#$VIRT_ROOT/}"; pshow="${pshow//\//\\}"
        printf '\n\n    Directory: %s\n\n\n' "$pshow"
        echo 'Mode                 LastWriteTime         Length Name'
        echo '----                 -------------         ------ ----'
        printf '%s        %-20s  %10s  %s\n' \
            '-a----' "$(_mtime "$real")" "$(stat -c%s "$real")" "$(basename "$real")"
        printf '\n'
        return
    fi

    printf '\n\n    Directory: %s\n\n\n' "$show"
    echo 'Mode                 LastWriteTime         Length Name'
    echo '----                 -------------         ------ ----'

    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        if [[ -d "$entry" ]]; then
            printf '%s        %-20s               %s\n' 'd-----' "$(_mtime "$entry")" "$name"
        else
            printf '%s        %-20s  %10s  %s\n' \
                '-a----' "$(_mtime "$entry")" "$(stat -c%s "$entry")" "$name"
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 -print0 | sort -z)
    printf '\n'
}

cmd_cd() {
    local arg="${1:-}"

    # No arg or ~ → home
    if [[ -z "$arg" || "$arg" == "~" ]]; then
        VIRT_CWD="Users/bursardesk"; return
    fi

    local v="${arg//\\//}"; v="${v#\"}"; v="${v%\"}"

    [[ "$v" == "." ]] && return

    local new_cwd
    if [[ "${v^^}" == C:/* || "${v^^}" == "C:" ]]; then
        v="${v:2}"; v="${v#/}"
        new_cwd="$v"
    else
        new_cwd="$VIRT_CWD/$v"
    fi

    # Resolve any .. components
    local resolved="" comp
    IFS='/' read -ra comps <<< "$new_cwd"
    for comp in "${comps[@]}"; do
        [[ -z "$comp" || "$comp" == "." ]] && continue
        if [[ "$comp" == ".." ]]; then
            [[ "$resolved" == */* ]] && resolved="${resolved%/*}" || resolved=""
        else
            resolved="${resolved:+$resolved/}$comp"
        fi
    done

    if [[ -d "$VIRT_ROOT/$resolved" ]]; then
        VIRT_CWD="$resolved"
    else
        printf "Set-Location: Cannot find path 'C:\\%s' because it does not exist.\n" \
            "${resolved//\//\\}"
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

cmd_pwd() {
    _disp
}

cmd_whoami() {
    local flag="${1:-}"
    case "${flag^^}" in
        /GROUPS)
            printf '\nUSER INFORMATION\n----------------\n'
            printf '%-18s %s\n' 'User Name' 'SID'
            printf '%-18s %s\n' '==================' '======================================='
            printf '%-18s %s\n\n' 'uupl\bursardesk' 'S-1-5-21-3847294729-1000000001-555555555-1001'
            printf 'GROUP INFORMATION\n-----------------\n'
            printf '%-36s %-17s %s\n' 'Group Name' 'Type' 'SID'
            printf '%-36s %-17s %s\n' '===================================' '================' '========================='
            printf '%-36s %-17s %s\n' 'UUPL\Domain Users' 'Domain group' 'S-1-5-21-3847294729-1000000001-555555555-513'
            printf '%-36s %-17s %s\n' 'BUILTIN\Users' 'Alias' 'S-1-5-32-545'
            printf '%-36s %-17s %s\n' 'BUILTIN\Remote Desktop Users' 'Alias' 'S-1-5-32-555'
            printf '%-36s %-17s %s\n' 'NT AUTHORITY\Authenticated Users' 'Well-known group' 'S-1-5-11'
            printf '\n'
            ;;
        /ALL)
            printf '\nUSER INFORMATION\n----------------\n'
            printf '%-18s %s\n' 'User Name' 'SID'
            printf '%-18s %s\n' '==================' '======================================='
            printf '%-18s %s\n\n' 'uupl\bursardesk' 'S-1-5-21-3847294729-1000000001-555555555-1001'
            printf 'GROUP INFORMATION\n-----------------\n'
            printf '%-36s %-17s %s\n' 'Group Name' 'Type' 'SID'
            printf '%-36s %-17s %s\n' '===================================' '================' '========================='
            printf '%-36s %-17s %s\n' 'UUPL\Domain Users' 'Domain group' 'S-1-5-21-3847294729-1000000001-555555555-513'
            printf '%-36s %-17s %s\n' 'BUILTIN\Users' 'Alias' 'S-1-5-32-545'
            printf '%-36s %-17s %s\n' 'NT AUTHORITY\Authenticated Users' 'Well-known group' 'S-1-5-11'
            printf '\nPRIVILEGES INFORMATION\n----------------------\n'
            printf '%-30s %-30s %s\n' 'Privilege Name' 'Description' 'State'
            printf '%-30s %-30s %s\n' '=============================' '==============================' '======='
            printf '%-30s %-30s %s\n' 'SeShutdownPrivilege' 'Shut down the system' 'Disabled'
            printf '%-30s %-30s %s\n' 'SeChangeNotifyPrivilege' 'Bypass traverse checking' 'Enabled'
            printf '%-30s %-30s %s\n' 'SeIncreaseWorkingSetPrivilege' 'Increase process working set' 'Disabled'
            printf '\n'
            ;;
        *)
            echo "uupl\bursardesk"
            ;;
    esac
}

cmd_hostname() {
    echo "BURSAR-DESK"
}

cmd_ipconfig() {
    local flag="${1:-}"
    local default_gw default_dev
    default_gw=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1);exit}}')
    default_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
    printf '\nWindows IP Configuration\n'
    if [[ "${flag^^}" == "/ALL" ]]; then
        printf '\n   Host Name . . . . . . . . . . . . : BURSAR-DESK\n'
        printf '   Primary Dns Suffix  . . . . . . . : uupl.local\n'
        printf '   Node Type . . . . . . . . . . . . : Hybrid\n'
        printf '   IP Routing Enabled. . . . . . . . : No\n'
        printf '   WINS Proxy Enabled. . . . . . . . : No\n'
        printf '   DNS Suffix Search List. . . . . . : uupl.local\n'
    fi
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
        local mac; mac=$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/{
            m=toupper($2); gsub(/:/,"-",m); print m; exit}')
        [[ -z "$mac" ]] && mac="00-00-00-00-00-00"
        local gw; [[ "$iface" == "$default_dev" ]] && gw="$default_gw" || gw=""
        local dns_sfx; [[ "$ip" == 10.10.1.* ]] && dns_sfx="uupl.local" || dns_sfx=""
        local nic_desc="Intel(R) PRO/1000 MT Network Connection"
        [[ $adapter_idx -gt 0 ]] && nic_desc="$nic_desc #$((adapter_idx+1))"
        printf '\nEthernet adapter Ethernet %d:\n\n' "$adapter_idx"
        if [[ "${flag^^}" == "/ALL" ]]; then
            printf '   Connection-specific DNS Suffix  . : %s\n' "$dns_sfx"
            printf '   Description . . . . . . . . . . . : %s\n' "$nic_desc"
            printf '   Physical Address. . . . . . . . . : %s\n' "$mac"
            printf '   DHCP Enabled. . . . . . . . . . . : No\n'
            printf '   Autoconfiguration Enabled . . . . : Yes\n'
        fi
        printf '   IPv4 Address. . . . . . . . . . . : %s\n' "$ip"
        printf '   Subnet Mask . . . . . . . . . . . : %s\n' "$mask"
        printf '   Default Gateway . . . . . . . . . : %s\n' "$gw"
        if [[ "${flag^^}" == "/ALL" ]]; then
            printf '   DNS Servers . . . . . . . . . . . : %s\n' "${default_gw:-10.10.1.1}"
            printf '   NetBIOS over Tcpip. . . . . . . . : Enabled\n'
        fi
        printf '\n'
        (( adapter_idx++ ))
    done < <(ip -4 addr show 2>/dev/null | awk '
        /^[0-9]+:/ { iface=$2; gsub(/:$/,"",iface); gsub(/@.*/,"",iface) }
        /inet /    { if (iface != "lo") print iface }
    ')
}

cmd_arp() {
    local ip1 ip2
    ip1=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1); [[ -z "$ip1" ]] && ip1="10.10.1.20"
    ip2=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1); [[ -z "$ip2" ]] && ip2="10.10.2.100"
    local sub1="${ip1%.*}" sub2="${ip2%.*}"

    printf '\nInterface: %s --- 0x2\n' "$ip1"
    printf '  Internet Address      Physical Address      Type\n'
    local ent1
    ent1=$(arp -n 2>/dev/null | awk -v pfx="$sub1" '
        NR>1 && $1 ~ ("^" pfx "\\.") {
            mac=$3; gsub(/:/, "-", mac)
            printf "  %-21s %-21s %s\n", $1, mac, "dynamic"
        }')
    if [[ -n "$ent1" ]]; then echo "$ent1"
    else printf '  %s.1             02-42-0a-0a-01-01     dynamic\n' "$sub1"; fi

    printf '\nInterface: %s --- 0x3\n' "$ip2"
    printf '  Internet Address      Physical Address      Type\n'
    local ent2
    ent2=$(arp -n 2>/dev/null | awk -v pfx="$sub2" '
        NR>1 && $1 ~ ("^" pfx "\\.") {
            mac=$3; gsub(/:/, "-", mac)
            printf "  %-21s %-21s %s\n", $1, mac, "dynamic"
        }')
    if [[ -n "$ent2" ]]; then echo "$ent2"
    else printf '  %s.1             02-42-0a-0a-02-01     dynamic\n' "$sub2"; fi
    printf '\n'
}

cmd_route_print() {
python3 - << 'PYEOF'
import struct, socket, subprocess

def hex_to_ip(h):
    return socket.inet_ntoa(struct.pack("<I", int(h, 16)))

ifaces = {}
try:
    out = subprocess.check_output(['ip','addr','show'], text=True, stderr=subprocess.DEVNULL)
    current = None
    for line in out.splitlines():
        if line and not line[0].isspace():
            parts = line.split()
            if len(parts) >= 2:
                # clab names interfaces as eth0@if12345 — strip the @if... suffix
                current = parts[1].rstrip(':').split('@')[0]
        elif 'inet ' in line and current and current != 'lo':
            ip = line.split()[1].split('/')[0]
            ifaces.setdefault(current, []).append(ip)
except Exception:
    pass

routes = []
try:
    with open('/proc/net/route') as f:
        for line in list(f)[1:]:
            p = line.split()
            if len(p) < 8:
                continue
            iface, dest, gw, mask, metric = p[0], p[1], p[2], p[7], int(p[6])
            routes.append((hex_to_ip(dest), hex_to_ip(mask), hex_to_ip(gw), iface, metric))
except Exception:
    pass

win_names = {}
for i, iface in enumerate(ifaces.keys()):
    suffix = f' #{i+1}' if i else ''
    win_names[iface] = f'Intel(R) PRO/1000 MT Network Connection{suffix}'

print('=' * 75)
print('Interface List')
idx = 1
for iface, ips in ifaces.items():
    idx += 1
    ip = ips[0] if ips else ''
    name = win_names.get(iface, iface)
    print(f'  {idx}...{name}  ({ip})')
print('  1...........................Software Loopback Interface 1')
print('=' * 75)
print()
print('IPv4 Route Table')
print('=' * 75)
print('Active Routes:')
print(f"{'Network Destination':<26} {'Netmask':<18} {'Gateway':<17} {'Interface':<14} Metric")
for dest, mask, gw, iface, metric in sorted(routes, key=lambda r: r[0]):
    ips = ifaces.get(iface, [])
    local_ip = ips[0] if ips else iface
    gw_disp = 'On-link' if gw == '0.0.0.0' else gw
    print(f'{dest:<26} {mask:<18} {gw_disp:<17} {local_ip:<14} {metric}')
print('=' * 75)
print('Persistent Routes:')
print('  None')
PYEOF
}

cmd_systeminfo() {
    local ip1 ip2
    ip1=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1); [[ -z "$ip1" ]] && ip1="10.10.1.20"
    ip2=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1); [[ -z "$ip2" ]] && ip2="10.10.2.100"
    cat << EOF

Host Name:                 BURSAR-DESK
OS Name:                   Microsoft Windows 10 Enterprise
OS Version:                10.0.17763 N/A Build 17763
OS Manufacturer:           Microsoft Corporation
OS Configuration:          Member Workstation
OS Build Type:             Multiprocessor Free
Registered Owner:          UU P&L Finance Department
Registered Organization:   Unseen University Power & Light Co.
Product ID:                00329-00000-00003-AA696
Original Install Date:     14/03/2019, 09:12:04
System Boot Time:          07/01/2025, 06:03:17
System Manufacturer:       Dell Inc.
System Model:              OptiPlex 7060
System Type:               x64-based PC
Processor(s):              1 Processor(s) Installed.
                           [01]: Intel64 Family 6 Model 158 Stepping 10 GenuineIntel ~3200 Mhz
BIOS Version:              Dell Inc. 1.7.3, 14/05/2019
Windows Directory:         C:\Windows
System Directory:          C:\Windows\system32
Boot Device:               \Device\HarddiskVolume1
System Locale:             en-gb;English (United Kingdom)
Input Locale:              en-gb;English (United Kingdom)
Time Zone:                 (UTC+00:00) Dublin, Edinburgh, Lisbon, London
Total Physical Memory:     8,192 MB
Available Physical Memory: 4,213 MB
Virtual Memory: Max Size:  9,728 MB
Virtual Memory: Available: 5,901 MB
Virtual Memory: In Use:    3,827 MB
Page File Location(s):     C:\pagefile.sys
Domain:                    UUPL
Logon Server:              \\UUPL-SRV-01
Hotfix(s):                 8 Hotfix(s) Installed.
                           [01]: KB4580325
                           [02]: KB4586830
                           [03]: KB4598481
                           [04]: KB4601315
                           [05]: KB4601554
                           [06]: KB4602122
                           [07]: KB4609949
                           [08]: KB4619339
Network Card(s):           2 NIC(s) Installed.
                           [01]: Intel(R) PRO/1000 MT Network Connection
                                 Connection Name: Ethernet 0
                                 DHCP Enabled:    No
                                 IP address(es)
                                 [01]: $ip1
                           [02]: Intel(R) PRO/1000 MT Network Connection #2
                                 Connection Name: Ethernet 1
                                 DHCP Enabled:    No
                                 IP address(es)
                                 [01]: $ip2

EOF
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
            }' | head -10
    else
        printf '  Proto  Local Address          Foreign Address        State\n'
        ss -tlnp 2>/dev/null | awk 'NR>1 {
            addr=$4; sub(/^\*:/, "0.0.0.0:", addr)
            printf "  %-6s %-22s %-22s %s\n", "TCP", addr, "0.0.0.0:0", "LISTENING"
        }'
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

cmd_tasklist() {
    cat << 'EOF'

Image Name                     PID Session Name        Session#    Mem Usage
========================= ======== ================ =========== ============
System Idle Process              0 Services                   0         24 K
System                           4 Services                   0        616 K
smss.exe                       348 Services                   0      1,236 K
csrss.exe                      512 Services                   0      5,316 K
wininit.exe                    608 Services                   0      7,124 K
services.exe                   668 Services                   0     10,468 K
lsass.exe                      680 Services                   0     17,292 K
svchost.exe                    804 Services                   0     45,624 K
svchost.exe                    888 Services                   0     23,108 K
svchost.exe                    960 Services                   0     18,440 K
svchost.exe                   1012 Services                   0     54,912 K
svchost.exe                   1064 Services                   0     12,336 K
explorer.exe                  2188 Console                    1    102,476 K
powershell.exe                3412 Console                    1     89,224 K
python3.exe                   3788 Console                    1     32,648 K
SearchIndexer.exe             4012 Services                   0     64,388 K
tasklist.exe                  4904 Console                    1     10,244 K

EOF
}

cmd_getprocess() {
    printf '\n'
    printf '%-8s %-7s %-10s %-10s %-10s %-6s %-3s %s\n' \
        'Handles' 'NPM(K)' 'PM(K)' 'WS(K)' 'CPU(s)' 'Id' 'SI' 'ProcessName'
    printf '%-8s %-7s %-10s %-10s %-10s %-6s %-3s %s\n' \
        '-------' '------' '-----' '-----' '------' '--' '--' '-----------'
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 423 42 89224 91332 12.34 3412 1 powershell
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 312 28 32648 34120 0.45 3788 1 python3
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 887 64 102476 105012 4.23 2188 1 explorer
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 1247 89 45624 47100 8.91 804 0 svchost
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 654 48 23108 24560 2.17 888 0 svchost
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 521 38 18440 19200 1.34 960 0 svchost
    printf '%8s %7s %10s %10s %10s %6s %3s %s\n' 892 72 54912 56800 6.78 1012 0 svchost
    printf '\n'
}

cmd_findstr() {
    local -a args=("$@")
    local case_flag="" pattern="" files=()
    local next_is_file=0

    for arg in "${args[@]}"; do
        case "${arg^^}" in
            /I)         case_flag="-i" ;;
            /S)         : ;;  # findstr /s is recursive but we handle by path
            /SI|/IS)    case_flag="-i" ;;
            /*)         ;;
            *)
                if [[ -z "$pattern" ]]; then
                    pattern="${arg//\"/}"
                else
                    files+=("$arg")
                fi
                ;;
        esac
    done

    if [[ -z "$pattern" ]]; then
        echo "FINDSTR: No search strings specified."; return
    fi

    local grep_args=()
    [[ -n "$case_flag" ]] && grep_args+=("$case_flag")

    if [[ ${#files[@]} -eq 0 ]]; then
        grep ${case_flag:+"$case_flag"} -- "$pattern" "$VIRT_ROOT/$VIRT_CWD" 2>/dev/null
        return
    fi

    for f in "${files[@]}"; do
        local real; real="$(_real "$f")"
        # shellcheck disable=SC2206
        local -a expanded=($real)
        for ef in "${expanded[@]}"; do
            [[ -f "$ef" ]] && grep ${case_flag:+"$case_flag"} -- "$pattern" "$ef" 2>/dev/null
        done
    done
}

cmd_cmdkey() {
    local sub="${1:-/list}"
    case "${sub^^}" in
        /LIST)
            printf '\nCurrently stored credentials:\n\n'
            printf '    Target: uupl-historian\n'
            printf '    Type: Generic\n'
            printf '    User: historian\n\n'
            printf '    Target: 10.10.2.10\n'
            printf '    Type: Generic\n'
            printf '    User: historian\n\n'
            printf '    Target: MicrosoftOffice16_Data:orgid\n'
            printf '    Type: Generic\n'
            printf '    User: bursar@uupl.local\n\n'
            ;;
        *)
            echo "The parameter is incorrect."
            ;;
    esac
}

cmd_psdrive() {
    cat << 'EOF'

Name           Used (GB)     Free (GB) Provider      Root
----           ---------     --------- --------      ----
Alias                                  Alias
C                   22.4          55.6 FileSystem    C:\
Cert                                   Certificate   \
Env                                    Environment
Function                               Function
HKCU                                   Registry      HKEY_CURRENT_USER
HKLM                                   Registry      HKEY_LOCAL_MACHINE
Variable                               Variable
WSMan                                  WSMan

EOF
}

cmd_schtasks() {
    local sub="${1:-}"
    case "${sub^^}" in
        /QUERY|"")
            printf '\nFolder: \\\n'
            printf '%-40s %-22s %s\n' 'TaskName' 'Next Run Time' 'Status'
            printf '%-40s %-22s %s\n' '========================================' '======================' '============'
            printf '\%-39s %-22s %s\n' 'MonthlyReport' '01/02/2025 06:00:00' 'Ready'
            printf '\%-39s %-22s %s\n' 'OneDrive Standalone Update Task' '08/01/2025 08:12:00' 'Ready'
            printf '\%-39s %-22s %s\n' 'MicrosoftEdgeUpdateTaskMachineCore' '08/01/2025 10:37:00' 'Ready'
            printf '\n'
            ;;
        *)
            printf 'ERROR: Invalid argument/option - '"'"'%s'"'"'.\n' "$sub"
            ;;
    esac
}

cmd_getscheduledtask() {
    cat << 'EOF'

TaskName                          : MonthlyReport
TaskPath                          : \
State                             : Ready
Actions                           : C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
                                    Arguments: -File C:\Users\bursardesk\Desktop\pull_monthly_report.ps1
Triggers                          : Monthly (Day 1 of every month)
LastRunTime                       : 01/01/2025 06:04:12
NextRunTime                       : 01/02/2025 06:00:00
Author                            : UUPL\Administrator

EOF
}

cmd_net() {
    local sub="${1^^}"
    shift 2>/dev/null || true
    case "$sub" in
        USER)
            printf '\nUser accounts for \\\\BURSAR-DESK\n\n'
            printf '%s\n' '-------------------------------------------------------------------------------'
            printf 'Administrator            bursardesk               Guest\n'
            printf 'The command completed successfully.\n\n'
            ;;
        VIEW)
            printf '\nServer Name            Remark\n\n'
            printf '%s\n' '-------------------------------------------------------------------------------'
            printf '\\\\UUPL-SRV-01           UU P&L Domain Controller\n'
            printf '\\\\HEX-LEGACY-1          Inventory Server\n'
            printf 'The command completed successfully.\n\n'
            ;;
        USE)
            printf '\nNew connections will be remembered.\n\n'
            printf 'Status       Local     Remote                             Network\n'
            printf '%s\n' '-------------------------------------------------------------------------------'
            printf 'OK           H:        \\\\uupl-srv-01\\home$                Microsoft Windows Network\n'
            printf 'The command completed successfully.\n\n'
            ;;
        LOCALGROUP)
            local grp="${1^^}"
            if [[ "$grp" == "ADMINISTRATORS" ]]; then
                printf '\nAlias name     Administrators\n'
                printf 'Comment        Administrators have complete and unrestricted access to the computer/domain\n\n'
                printf 'Members\n\n'
                printf '%s\n' '-------------------------------------------------------------------------------'
                printf 'Administrator\n'
                printf 'bursardesk\n'
                printf 'The command completed successfully.\n\n'
            else
                printf 'The group name could not be found.\n\n'
            fi
            ;;
        *)
            echo "The syntax of this command is incorrect."
            ;;
    esac
}

cmd_ssh() {
    /usr/bin/ssh -o StrictHostKeyChecking=no "$@"
}

cmd_iwr() {
    local uri="" method="GET" body="" content_type="" auth_header="" outfile="" infile=""
    while [[ $# -gt 0 ]]; do
        case "${1,,}" in
            -uri)         shift; uri="${1//\"/}" ;;
            -method)      shift; method="${1^^}" ;;
            -contenttype) shift; content_type="${1//\"/}" ;;
            -body)        shift; body="$1" ;;
            -headers)
                shift
                local h="${1#@\{}"; h="${h%\}}"
                local hkey="${h%%=*}" hval="${h#*=}"
                [[ "${hkey,,}" == "authorization" ]] && auth_header="$hval"
                ;;
            -outfile)     shift; outfile="$1" ;;
            -infile)      shift; infile="$(_real "$1")" ;;
            -usebasicparsing|-credential) ;;
            http://*|https://*) uri="${1//\"/}" ;;
        esac
        shift
    done
    if [[ -z "$uri" ]]; then
        echo "Invoke-WebRequest: URI parameter required."; return
    fi
    local -a args=("-s" "--connect-timeout" "5" "--max-time" "10")
    [[ "$method" == "POST" ]] && args+=("-X" "POST")
    [[ -n "$auth_header" ]]   && args+=("-H" "Authorization: $auth_header")
    [[ -n "$content_type" ]]  && args+=("-H" "Content-Type: $content_type")
    [[ -n "$body" ]]          && args+=("-d" "$body")
    [[ -n "$outfile" ]]       && args+=("-o" "$outfile")
    [[ -n "$infile" ]]        && args+=(--data-binary "@$infile")
    local out
    out=$(/usr/bin/curl "${args[@]}" "$uri" 2>/dev/null)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'Invoke-WebRequest : Unable to connect to the remote server\n'
        printf 'At line:1 char:1\n'
        printf '    + CategoryInfo : InvalidOperation\n'
        printf '    + FullyQualifiedErrorId : WebCmdletWebResponseException\n'
        return 1
    fi
    printf '%s' "$out"
    [[ -z "$outfile" && -n "$out" ]] && printf '\n'
}

cmd_nmap() {
    /usr/bin/nmap "$@"
}

cmd_nc() {
    /usr/bin/nc "$@"
}

cmd_ftp() {
    /usr/bin/ftp "$@"
}

Select-Object() { cat; }

cmd_help() {
    cat << 'EOF'

Name                          Alias                    Description
----                          -----                    -----------
Set-Location                  cd, sl                   Change the current directory
Get-ChildItem                 dir, ls, gci             List directory contents (supports /s, -Recurse, -Filter)
Get-Content                   cat, type, gc            Display file contents
Get-Location                  pwd, gl                  Show current path
Clear-Host                    cls, clear               Clear the screen
Invoke-WebRequest             iwr, wget                Send an HTTP/HTTPS request
Get-Process                   tasklist                 List running processes
Get-ScheduledTask             schtasks                 List scheduled tasks
Get-PSDrive                   gdr                      List available drives
whoami                                                 Current user (/groups, /all)
ipconfig                                               IP configuration (/all for full detail)
arp                                                    ARP cache (-a)
route                                                  Routing table (print)
systeminfo                                             System information
findstr                                                Search file contents (/i case-insensitive)
cmdkey                                                 Credential manager (/list)

Network tools available: nmap, nc, ftp, iwr, ssh, ping, netstat, net

EOF
}

# ── command dispatch ──────────────────────────────────────────────────────────

_dispatch() {
    local line="$1"
    line="${line//$'\r'/}"
    line="${line#.\\}"; line="${line#./}"

    local cmd rest
    read -r cmd rest <<< "$line"

    case "${cmd,,}" in
        cd|set-location|sl)             cmd_cd "$rest" ;;
        dir|ls|get-childitem|gci)       cmd_dir "$rest" ;;
        cat|type|get-content|gc)        cmd_cat "$rest" ;;
        pwd|get-location|gl)            cmd_pwd ;;
        cls|clear|clear-host)           clear ;;
        whoami)                         cmd_whoami $rest ;;
        hostname)                       cmd_hostname ;;
        ipconfig)                       cmd_ipconfig $rest ;;
        arp)                            cmd_arp ;;
        route)                          [[ "${rest,,}" == "print"* ]] && cmd_route_print \
                                            || echo "The syntax of this command is incorrect." ;;
        systeminfo)                     cmd_systeminfo ;;
        tasklist|get-process|gp)        [[ "${cmd,,}" == "get-process" || "${cmd,,}" == "gp" ]] \
                                            && cmd_getprocess || cmd_tasklist ;;
        findstr)                        cmd_findstr $rest ;;
        cmdkey)                         cmd_cmdkey $rest ;;
        get-psdrive|gdr)                cmd_psdrive ;;
        schtasks)                       cmd_schtasks $rest ;;
        get-scheduledtask)              cmd_getscheduledtask ;;
        netstat)                        cmd_netstat $rest ;;
        ping)                           cmd_ping $rest ;;
        net)                            cmd_net $rest ;;
        ssh)                            eval "$line" ;;
        curl)                           eval "$line" ;;
        invoke-webrequest|iwr|wget)     eval cmd_iwr "${rest//\\/\\\\}" ;;
        nmap)                           eval "$line" ;;
        nc)                             eval "$line" ;;
        ftp)                            eval "$line" ;;
        python|python3)                 eval "$line" ;;
        sqlite3)                        eval "$line" ;;
        help|get-help)                  cmd_help ;;
        exit|quit|logout)               printf '\n'; exit 0 ;;
        "")                             true ;;
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
*   BURSAR-DESK, Corporate Workstation                                       *
*                                                                             *
*   This system is provided for authorised UU P&L business use only.         *
*   Unauthorised access is prohibited. Usage may be monitored.                *
*   Contact IT: Ponder Stibbons, ext 201                                      *
*                                                                             *
*******************************************************************************

LOGON

# ── main loop ─────────────────────────────────────────────────────────────────

while true; do
    printf 'PS %s> ' "$(_disp)"
    IFS= read -r line || break
    _dispatch "$line"
done
