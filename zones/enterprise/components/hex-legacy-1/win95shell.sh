#!/usr/bin/env bash
# UU P&L Legacy Workstation, DOS shell emulator
# Presents a Windows 95-era command prompt over SSH/Telnet.
# The filesystem lives at /opt/legacy/C with uppercase 8.3 names.

VIRT_ROOT="/opt/legacy/C"
VIRT_CWD=""      # path relative to VIRT_ROOT; empty = C:\ root
VIRT_DRIVE="C"   # currently active drive letter

# Mapped network drives.  Values are real filesystem paths.
# __UNC__\\... means the share was mapped but has no local backing.
declare -A DRIVE_MAP=(
    [F]="__UNC__\\\\UUPL-SRV-01\\operations\$"
    [G]="/srv/smb/public"
)
# Per-drive CWD (relative to that drive's root), populated on first cd.
declare -A DRIVE_CWD=()

stty icrnl 2>/dev/null || true

# ── path helpers ──────────────────────────────────────────────────────────────

_real() {
    local v="${1:-}"
    v="${v//\\//}"   # backslash → slash

    # Detect explicit drive letter at the front.
    local drive=""
    if [[ "${v^^}" =~ ^([A-Z]):(/.*)$ ]]; then
        drive="${BASH_REMATCH[1]^^}"; v="${BASH_REMATCH[2]#/}"
    elif [[ "${v^^}" =~ ^([A-Z]):$ ]]; then
        drive="${BASH_REMATCH[1]^^}"; v=""
    elif [[ "${v^^}" =~ ^([A-Z]):/$ ]]; then
        drive="${BASH_REMATCH[1]^^}"; v=""
    fi
    [[ -z "$drive" ]] && drive="$VIRT_DRIVE"

    if [[ "$drive" == "C" ]]; then
        v="${v^^}"
        if [[ -z "$v" ]]; then
            [[ -z "$VIRT_CWD" ]] && echo "$VIRT_ROOT" || echo "$VIRT_ROOT/$VIRT_CWD"
        elif [[ "$v" == /* ]]; then
            echo "$VIRT_ROOT/${v#/}"
        elif [[ -z "$VIRT_CWD" ]]; then
            echo "$VIRT_ROOT/$v"
        else
            echo "$VIRT_ROOT/$VIRT_CWD/$v"
        fi
        return
    fi

    local dp="${DRIVE_MAP[$drive]:-}"
    if [[ -z "$dp" || "$dp" == __UNC__* ]]; then
        echo "/dev/null/nopath"; return
    fi
    local dcwd="${DRIVE_CWD[$drive]:-}"
    v="${v^^}"
    if [[ -z "$v" ]]; then
        [[ -z "$dcwd" ]] && echo "$dp" || echo "$dp/$dcwd"
    else
        echo "$dp/$v"
    fi
}

_display_cwd() {
    if [[ "$VIRT_DRIVE" == "C" ]]; then
        [[ -z "$VIRT_CWD" ]] && echo 'C:\' || echo "C:\\${VIRT_CWD//\//\\}"
    else
        local dcwd="${DRIVE_CWD[$VIRT_DRIVE]:-}"
        [[ -z "$dcwd" ]] && echo "${VIRT_DRIVE}:\\" || echo "${VIRT_DRIVE}:\\${dcwd//\//\\}"
    fi
}

# Convert a real filesystem path back to the DOS display form.
# _dos_path REAL_PATH [HINT_DRIVE]
_dos_path() {
    local real="$1" hint="${2:-}"

    if [[ "$real" == "$VIRT_ROOT"* ]]; then
        local rel="${real#$VIRT_ROOT}"; rel="${rel#/}"
        [[ -z "$rel" ]] && echo 'C:\' || echo "C:\\${rel//\//\\}"
        return
    fi

    # Try hint drive first so that newly mapped Z: shows Z:\ rather than G:\.
    if [[ -n "$hint" ]]; then
        local dp="${DRIVE_MAP[$hint]:-}"
        if [[ -n "$dp" && "$dp" != __UNC__* && "$real" == "$dp"* ]]; then
            local rel="${real#$dp}"; rel="${rel#/}"
            [[ -z "$rel" ]] && echo "${hint}:\\" || echo "${hint}:\\${rel//\//\\}"
            return
        fi
    fi

    local dl
    for dl in "${!DRIVE_MAP[@]}"; do
        local dp="${DRIVE_MAP[$dl]}"
        [[ "$dp" == __UNC__* || -z "$dp" ]] && continue
        if [[ "$real" == "$dp"* ]]; then
            local rel="${real#$dp}"; rel="${rel#/}"
            [[ -z "$rel" ]] && echo "${dl}:\\" || echo "${dl}:\\${rel//\//\\}"
            return
        fi
    done
    echo "$real"
}

# Determine which drive letter and backing root a real path belongs to.
# Outputs: DRIVE ROOT  (space-separated, both empty if unknown)
_path_drive() {
    local real="$1"
    if [[ "$real" == "$VIRT_ROOT"* ]]; then
        echo "C $VIRT_ROOT"; return
    fi
    local dl
    for dl in "${!DRIVE_MAP[@]}"; do
        local dp="${DRIVE_MAP[$dl]}"
        [[ "$dp" == __UNC__* || -z "$dp" ]] && continue
        if [[ "$real" == "$dp"* ]]; then
            echo "$dl $dp"; return
        fi
    done
    echo " "
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_ver() { printf '\nMicrosoft Windows 95 [Version 4.00.950]\n\n'; }
cmd_cls() { clear; }

cmd_dir() {
    local rest="${1:-}"
    local recursive=false pattern="" base_path=""
    local -a tokens
    read -r -a tokens <<< "$rest"

    for tok in "${tokens[@]}"; do
        local up="${tok^^}"
        case "$up" in
            /S) recursive=true ;;
            /B|/W|/P|/A|/A:*|/O|/O:*|/X|/4|/L|/N|/Q) ;;
            *)
                if [[ "$tok" == *[\*\?]* ]]; then
                    if [[ "$tok" == *[/\\]* ]]; then
                        local norm="${tok//\\//}"
                        base_path="${norm%/*}"
                        pattern="${norm##*/}"
                    else
                        pattern="$tok"
                    fi
                elif [[ -n "$tok" ]]; then
                    base_path="$tok"
                fi
                ;;
        esac
    done

    local real_base; real_base="$(_real "${base_path:-}")"

    if [[ ! -e "$real_base" ]]; then
        printf 'File Not Found\n'; return
    fi

    # Determine drive/root for display path generation.
    local pd; pd="$(_path_drive "$real_base")"
    local base_drive="${pd%% *}" base_root="${pd#* }"

    if $recursive; then
        _dir_recursive "$real_base" "$base_drive" "$base_root" "$pattern"
    else
        local disp; disp="$(_dos_path "$real_base" "$base_drive")"
        _dir_listing "$real_base" "$disp" "$pattern"
    fi
}

_dir_listing() {
    local real="$1" show="$2" pattern="${3:-}"
    local find_args=()
    [[ -n "$pattern" ]] && find_args=(-iname "$pattern")

    printf '\n Volume in drive %s is UUPL-SYS\n' "$VIRT_DRIVE"
    printf ' Volume Serial Number is 2B7F-A4C1\n'
    printf '\n Directory of %s\n\n' "$show"

    local files=0 dirs=0 total=0
    while IFS= read -r -d '' entry; do
        local name; name=$(basename "$entry")
        local dosname="${name^^}"
        if [[ -d "$entry" ]]; then
            printf '%s  %s   <DIR>         %s\n' "14/09/99" " 9:23a" "$dosname"
            (( dirs++ )) || true
        else
            local sz; sz=$(stat -c%s "$entry" 2>/dev/null || echo 0)
            printf '%s  %s   %9s  %s\n' "14/09/99" " 9:23a" "$sz" "$dosname"
            (( files++ )) || true; (( total += sz )) || true
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 "${find_args[@]}" -print0 2>/dev/null | sort -z)

    printf '       %3d file(s)    %7d bytes\n' "$files" "$total"
    printf '       %3d dir(s)   1,048,576 bytes free\n\n' "$dirs"
}

_dir_recursive() {
    local real_base="$1" base_drive="$2" base_root="$3" pattern="${4:-}"
    local find_args=(-mindepth 1)
    if [[ -n "$pattern" ]]; then
        find_args+=(-type f -iname "$pattern")
    fi

    local total_files=0 total_bytes=0
    declare -A seen_dirs

    while IFS= read -r f; do
        local d; d=$(dirname "$f")
        if [[ -z "${seen_dirs[$d]:-}" ]]; then
            seen_dirs[$d]=1
            local ddisp
            if [[ "$base_drive" == "C" ]]; then
                local rel="${d#$VIRT_ROOT}"; rel="${rel#/}"
                [[ -z "$rel" ]] && ddisp='C:\' || ddisp="C:\\${rel//\//\\}"
            else
                local rel="${d#$base_root}"; rel="${rel#/}"
                [[ -z "$rel" ]] && ddisp="${base_drive}:\\" || ddisp="${base_drive}:\\${rel//\//\\}"
            fi
            printf '\n Directory of %s\n\n' "$ddisp"
        fi

        if [[ -d "$f" ]]; then
            printf '%s  %s   <DIR>         %s\n' "14/09/99" " 9:23a" "${f^^##*/}"
        else
            local name; name=$(basename "$f"); local dosname="${name^^}"
            local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            printf '%s  %s   %9s  %s\n' "14/09/99" " 9:23a" "$sz" "$dosname"
            (( total_files++ )) || true; (( total_bytes += sz )) || true
        fi
    done < <(find "$real_base" "${find_args[@]}" 2>/dev/null | sort)

    if [[ $total_files -eq 0 && -n "$pattern" ]]; then
        printf '\n     File Not Found\n\n'
    else
        printf '\n     Total Files Listed:\n'
        printf '       %3d file(s)    %7d bytes\n' "$total_files" "$total_bytes"
        printf '             0 dir(s)   1,048,576 bytes free\n\n'
    fi
}

cmd_cd() {
    local arg="${1:-}"

    # bare cd or cd \ → root of current drive
    if [[ -z "$arg" || "$arg" == "\\" ]]; then
        [[ "$VIRT_DRIVE" == "C" ]] && VIRT_CWD="" || DRIVE_CWD[$VIRT_DRIVE]=""
        return
    fi

    # Drive switch: "Z:" with no path component
    if [[ "${arg^^}" =~ ^([A-Z]):$ ]]; then
        local dl="${BASH_REMATCH[1]^^}"
        if [[ "$dl" == "C" ]]; then
            VIRT_DRIVE="C"
        else
            local dp="${DRIVE_MAP[$dl]:-}"
            if [[ -z "$dp" || "$dp" == __UNC__* ]]; then
                printf 'Not ready reading drive %s\nAbort, Retry, Fail? ' "$dl"
                IFS= read -r _reply
            else
                VIRT_DRIVE="$dl"
            fi
        fi
        return
    fi

    if [[ "${arg^^}" == ".." ]]; then
        if [[ "$VIRT_DRIVE" == "C" ]]; then
            [[ -n "$VIRT_CWD" ]] && VIRT_CWD="${VIRT_CWD%/*}" && [[ "$VIRT_CWD" == "." ]] && VIRT_CWD=""
        else
            local dcwd="${DRIVE_CWD[$VIRT_DRIVE]:-}"
            if [[ -n "$dcwd" ]]; then
                dcwd="${dcwd%/*}"; [[ "$dcwd" == "." ]] && dcwd=""
                DRIVE_CWD[$VIRT_DRIVE]="$dcwd"
            fi
        fi
        return
    fi

    local real_target; real_target="$(_real "$arg")"
    if [[ -d "$real_target" ]]; then
        if [[ "$VIRT_DRIVE" == "C" ]]; then
            local rel="${real_target#$VIRT_ROOT/}"
            [[ "$real_target" == "$VIRT_ROOT" ]] && rel=""
            VIRT_CWD="$rel"
        else
            local dp="${DRIVE_MAP[$VIRT_DRIVE]}"
            local rel="${real_target#$dp/}"
            [[ "$real_target" == "$dp" ]] && rel=""
            DRIVE_CWD[$VIRT_DRIVE]="$rel"
        fi
    else
        printf 'Invalid directory\n'
    fi
}

cmd_type() {
    local arg="${1:-}"
    [[ -z "$arg" ]] && { printf 'Required parameter missing\n'; return; }
    local real; real="$(_real "$arg")"
    [[ -f "$real" ]] && cat "$real" || printf 'File not found - %s\n' "$arg"
}

cmd_copy() { printf 'Access denied.\n'; }
cmd_del()  { printf 'Access denied.\n'; }

cmd_net() {
    local rest="${1:-}"
    local sub
    read -r sub rest <<< "$rest"
    sub="${sub^^}"

    case "$sub" in
        VIEW)
            if [[ -n "$rest" ]]; then
                local server="${rest^^}"; server="${server//\\\\//}"; server="${server#/}"
                case "$server" in
                    HEX-LEGACY-1*)
                        printf '\nShared resources at \\\\HEX-LEGACY-1\n\n'
                        printf 'Share name  Type  Used as  Comment\n'
                        printf '----------------------------------------------------------------------\n'
                        printf 'public      Disk           UU P&L Public Documents\n'
                        printf 'The command completed successfully.\n\n'
                        ;;
                    UUPL-SRV-01*)
                        printf '\nShared resources at \\\\UUPL-SRV-01\n\n'
                        printf 'Share name    Type  Used as  Comment\n'
                        printf '----------------------------------------------------------------------\n'
                        printf 'operations$   Disk           Operations share\n'
                        printf 'The command completed successfully.\n\n'
                        ;;
                    *)
                        printf '\nSystem error 53 has occurred.\n\nThe network path was not found.\n\n'
                        ;;
                esac
            else
                printf '\nServer Name            Remark\n'
                printf '----------------------------------------------------------------------\n'
                printf '\\\\HEX-LEGACY-1          UU P&L Inventory Server\n'
                printf '\\\\UUPL-SRV-01           File server / domain controller\n\n'
            fi
            ;;
        USE)
            if [[ -z "$rest" ]]; then
                printf '\nNew connections will be remembered.\n\n'
                printf 'Status    Local   Remote                          Network\n'
                printf '----------------------------------------------------------------------\n'
                printf 'OK        F:      \\\\UUPL-SRV-01\\operations$       Microsoft Windows Network\n'
                printf 'OK        G:      \\\\HEX-LEGACY-1\\public           Microsoft Windows Network\n'
                local dl
                for dl in "${!DRIVE_MAP[@]}"; do
                    [[ "$dl" == "F" || "$dl" == "G" ]] && continue
                    local dp="${DRIVE_MAP[$dl]}"
                    [[ "$dp" == __UNC__* ]] && continue
                    printf 'OK        %s:      \\\\(mapped)\\share                Microsoft Windows Network\n' "$dl"
                done
                printf '\n'
            else
                local letter unc_or_cmd
                read -r letter unc_or_cmd _ <<< "$rest"
                letter="${letter^^}"; letter="${letter%:}"

                if [[ "${unc_or_cmd^^}" == "/D" ]]; then
                    if [[ -n "${DRIVE_MAP[$letter]:-}" ]]; then
                        unset "DRIVE_MAP[$letter]"
                        printf '%s: was deleted successfully.\n\n' "$letter"
                    else
                        printf 'The network connection could not be found.\n\n'
                    fi
                elif [[ "$unc_or_cmd" == \\\\* ]]; then
                    local share_name="${unc_or_cmd^^}"; share_name="${share_name##*\\}"
                    local real_path
                    case "$share_name" in
                        PUBLIC)  real_path="/srv/smb/public" ;;
                        PRIVATE) real_path="/srv/smb/private" ;;
                        *)       real_path="" ;;
                    esac
                    if [[ -n "$real_path" ]]; then
                        DRIVE_MAP[$letter]="$real_path"
                    else
                        DRIVE_MAP[$letter]="__UNC__$unc_or_cmd"
                    fi
                    printf 'The command completed successfully.\n\n'
                else
                    printf 'The syntax of this command is incorrect.\n\n'
                fi
            fi
            ;;
        USER)
            printf '\nUser accounts for \\\\HEX-LEGACY-1\n'
            printf '----------------------------------------------------------------------\n'
            printf 'Administrator            Guest\n\n'
            ;;
        *)
            printf 'The syntax of this command is incorrect.\n'
            ;;
    esac
}

# DOS FIND command: searches for text inside files.
# Usage: FIND [/I] "string" file [file...]
cmd_find_dos() {
    local rest="${1:-}"
    local case_flag=false search_str="" after_str=""
    local -a file_pats

    [[ "${rest^^}" =~ (^|[[:space:]])/I([[:space:]]|$) ]] && case_flag=true

    if [[ "$rest" =~ \"([^\"]+)\" ]]; then
        search_str="${BASH_REMATCH[1]}"
        after_str="${rest#*\"${search_str}\"}"
    else
        local stripped="${rest//\/[Ii]/}"
        local -a toks
        read -r -a toks <<< "$stripped"
        for tok in "${toks[@]}"; do
            [[ -z "$tok" || "$tok" == /* ]] && continue
            if [[ -z "$search_str" ]]; then search_str="$tok"
            else file_pats+=("$tok"); fi
        done
        after_str=""
    fi

    if [[ -z "$search_str" ]]; then
        printf 'FIND: Parameter format not correct\n'; return
    fi

    local -a extra_pats
    read -r -a extra_pats <<< "$after_str"
    for tok in "${extra_pats[@]}"; do
        [[ -z "$tok" || "$tok" == /* ]] && continue
        file_pats+=("$tok")
    done

    if [[ ${#file_pats[@]} -eq 0 ]]; then
        printf 'FIND: File not found\n'; return
    fi

    local found_any=false
    for pat in "${file_pats[@]}"; do
        [[ "$pat" == /* ]] && continue
        local real_pat; real_pat="$(_real "$pat")"
        local dir_part; dir_part="$(dirname "$real_pat")"
        local name_part; name_part="$(basename "$real_pat")"

        local -a matching=()
        if [[ "$pat" == *[\*\?]* ]]; then
            while IFS= read -r -d '' mf; do
                matching+=("$mf")
            done < <(find "$dir_part" -maxdepth 1 -iname "$name_part" -type f -print0 2>/dev/null | sort -z)
        else
            [[ -f "$real_pat" ]] && matching=("$real_pat")
        fi

        for mf in "${matching[@]}"; do
            found_any=true
            local dpath; dpath="$(_dos_path "$mf")"
            printf '\n---------- %s\n' "$dpath"
            if $case_flag; then
                grep -i -- "$search_str" "$mf" 2>/dev/null || true
            else
                grep -- "$search_str" "$mf" 2>/dev/null || true
            fi
        done
    done

    $found_any || printf 'FIND: File not found\n'
}

cmd_ping() {
    local target="${1:-}"
    [[ -z "$target" ]] && { printf 'Usage: PING host-name\n'; return; }
    printf '\nPinging %s with 32 bytes of data:\n\n' "$target"
    if ping -c 4 -W 1 "$target" &>/dev/null; then
        for _ in 1 2 3 4; do printf 'Reply from %s: bytes=32 time<1ms TTL=128\n' "$target"; done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 4, Lost = 0 (0%%%% loss),\n' "$target"
        printf 'Approximate round trip times in milli-seconds:\n    Minimum = 0ms, Maximum = 1ms, Average = 0ms\n\n'
    else
        for _ in 1 2 3 4; do printf 'Request timed out.\n'; done
        printf '\nPing statistics for %s:\n    Packets: Sent = 4, Received = 0, Lost = 4 (100%%%% loss),\n\n' "$target"
    fi
}

cmd_netstat() {
    printf '\nActive Connections\n\n'
    printf '  Proto  Local Address          Foreign Address        State\n'
    netstat -tn 2>/dev/null \
      | awk 'NR>2 && /ESTABLISHED|LISTEN/ {
            printf "  %-6s %-22s %-22s %s\n", "TCP", $4, $5, $6
        }' | head -12
    printf '\n'
}

cmd_route() {
    printf '\nActive Routes:\n'
    printf 'Network Address   Netmask           Gateway Address   Interface    Metric\n'
    printf '          0.0.0.0         0.0.0.0       10.10.1.1     10.10.1.10       1\n'
    printf '       10.10.1.0   255.255.255.0     10.10.1.10     10.10.1.10       1\n'
    printf '     127.0.0.0     255.0.0.0         127.0.0.1       127.0.0.1       1\n'
    printf '\nDefault Gateway:   10.10.1.1\n\n'
}

cmd_arp() {
    printf '\nInterface: 10.10.1.10 on Interface 0x2\n'
    printf '  Internet Address      Physical Address      Type\n'
    printf '  10.10.1.1             00-14-22-01-23-45     dynamic\n'
    printf '  10.10.1.20            00-50-56-aa-bb-cc     dynamic\n\n'
}

cmd_winipcfg() {
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="10.10.1.10"
    printf '\nIP Configuration\n\n'
    printf '   Ethernet Adapter: SMC EtherCard ELITE16T\n\n'
    printf '   Adapter Address:  00-50-56-01-02-03\n'
    printf '   IP Address:       %s\n' "$ip"
    printf '   Subnet Mask:      255.255.255.0\n'
    printf '   Default Gateway:  10.10.1.1\n\n'
    printf '   DNS Server:       10.10.1.1\n'
    printf '   DHCP:             Disabled\n\n'
}

cmd_ipconfig() {
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="10.10.1.10"
    printf '\nWindows IP Configuration\n\n'
    printf '\nEthernet adapter:\n\n'
    printf '   IP Address. . . . . . . . . : %s\n' "$ip"
    printf '   Subnet Mask . . . . . . . . : 255.255.255.0\n'
    printf '   Default Gateway . . . . . . : 10.10.1.1\n\n'
}

cmd_nbtstat() {
    local rest="${1:-}"
    local flag target
    read -r flag target <<< "$rest"
    flag="${flag^^}"
    local resp_ip="${target:-}"

    local machine_name
    case "$resp_ip" in
        10.10.1.10) machine_name="HEX-LEGACY-1" ;;
        10.10.1.20) machine_name="BURSAR-DESK" ;;
        10.10.2.10) machine_name="HISTORIAN-01" ;;
        10.10.2.20) machine_name="DIST-SCADA-01" ;;
        10.10.2.30) machine_name="ENG-WS-01" ;;
        *)          machine_name="" ;;
    esac

    if [[ -z "$resp_ip" ]]; then
        printf '\nUsage: NBTSTAT -A ip-address\n\n'; return
    fi
    if [[ -z "$machine_name" ]]; then
        printf '\nHost not found.\n\n'; return
    fi

    printf '\nNode IpAddress: [%s] Scope Id: []\n\n' "$resp_ip"
    printf '           NetBIOS Remote Machine Name Table\n\n'
    printf '       Name               Type         Status\n'
    printf '    ---------------------------------------------\n'
    printf '    %-15s<00>  UNIQUE      Registered\n' "$machine_name"
    printf '    %-15s<00>  GROUP       Registered\n' "UUPL"
    printf '    %-15s<20>  UNIQUE      Registered\n' "$machine_name"
    printf '\n    MAC Address = 00-50-56-AA-BB-CC\n\n'
}

cmd_attrib() {
    local arg="${1:-}"
    if [[ -z "$arg" ]]; then
        local real; real="$(_real)"
        printf 'A    %s\n' "$(_display_cwd)"; return
    fi
    local real; real="$(_real "$arg")"
    if [[ -e "$real" ]]; then
        printf 'A    %s\n' "$(_dos_path "$real")"
    else
        printf 'File not found - %s\n' "$arg"
    fi
}

cmd_ssh()    { printf 'Opening secure shell...\n'; /usr/bin/ssh -o StrictHostKeyChecking=no "$@"; }
cmd_ftp()    { /usr/bin/ftp "$@"; }
cmd_tftp()   { command -v tftp &>/dev/null && /usr/bin/tftp "$@" || printf 'TFTP: command not available\n'; }
cmd_telnet() { /usr/bin/telnet "$@"; }
cmd_nc()     { /usr/bin/nc "$@"; }
cmd_curl()   { /usr/bin/curl "$@"; }
cmd_nmap()   { /usr/bin/nmap "$@"; }

cmd_help() {
    printf '\n'
    printf 'ARP      Displays the ARP table.          (ARP -A)\n'
    printf 'ATTRIB   Displays file attributes.\n'
    printf 'CD       Changes the current directory.\n'
    printf 'CLS      Clears the screen.\n'
    printf 'COPY     Copies files. (restricted on this system)\n'
    printf 'DEL      Deletes files. (restricted on this system)\n'
    printf 'DIR      Lists files.  (/S recursive; wildcards supported)\n'
    printf 'EXIT     Quits COMMAND.COM.\n'
    printf 'FIND     Searches for a string in files.  (FIND /I "text" *.ext)\n'
    printf 'FTP      Connects to an FTP server.\n'
    printf 'HELP     Provides help information.\n'
    printf 'IPCONFIG Displays IP configuration.\n'
    printf 'NBTSTAT  Displays NetBIOS info.            (NBTSTAT -A ip)\n'
    printf 'NC       Netcat, raw TCP connections.\n'
    printf 'NET      Network commands.  (NET VIEW, NET USE, NET USER)\n'
    printf 'NETSTAT  Displays active connections.\n'
    printf 'NMAP     Network scanner.\n'
    printf 'PING     Tests network connectivity.\n'
    printf 'ROUTE    Displays the routing table.       (ROUTE PRINT)\n'
    printf 'SSH      Opens an SSH session to a remote host.\n'
    printf 'TELNET   Connects to a Telnet server.\n'
    printf 'TFTP     Trivial File Transfer Protocol.\n'
    printf 'TYPE     Displays a text file.\n'
    printf 'VER      Displays the Windows version.\n'
    printf 'WINIPCFG Displays full IP configuration.\n'
    printf '\n'
}

# ── dispatch ──────────────────────────────────────────────────────────────────

_dispatch() {
    local line="$1"
    local cmd rest
    read -r cmd rest <<< "$line"
    cmd="${cmd^^}"

    case "$cmd" in
        VER)           cmd_ver ;;
        CLS)           cmd_cls ;;
        DIR)           cmd_dir "$rest" ;;
        CD|CHDIR)      cmd_cd  "$rest" ;;
        TYPE)          cmd_type "$rest" ;;
        COPY)          cmd_copy ;;
        DEL|ERASE)     cmd_del ;;
        FIND)          cmd_find_dos "$rest" ;;
        NET)           cmd_net "$rest" ;;
        PING)          cmd_ping "$rest" ;;
        NETSTAT)       cmd_netstat ;;
        ROUTE)         cmd_route "$rest" ;;
        ARP)           cmd_arp ;;
        WINIPCFG)      cmd_winipcfg ;;
        IPCONFIG)      cmd_ipconfig ;;
        NBTSTAT)       cmd_nbtstat "$rest" ;;
        ATTRIB)        cmd_attrib "$rest" ;;
        SSH)           eval "cmd_ssh $rest" ;;
        FTP)           eval "cmd_ftp $rest" ;;
        TFTP)          eval "cmd_tftp $rest" ;;
        TELNET)        eval "cmd_telnet $rest" ;;
        NC)            eval "cmd_nc $rest" ;;
        CURL)          eval "cmd_curl $rest" ;;
        NMAP)          eval "cmd_nmap $rest" ;;
        HELP|"/?"|\?) cmd_help ;;
        EXIT|QUIT|LOGOUT|BYE) printf '\n'; exit 0 ;;
        "")            true ;;
        [A-Z]:)        cmd_cd "$cmd" ;;
        *)             printf 'Bad command or file name\n' ;;
    esac
}

# ── non-interactive command exec ─────────────────────────────────────────────
# ssh root@host 'CMD' invokes the shell as  win95shell.sh -c 'CMD'.
# Shared redirection logic so  DIR C:\ > C:\TEMP\OUT.TXT  works here too.

_run_line() {
    local _line="$1"
    _line="${_line//$'\r'/}"
    local _out="" _app=false
    if [[ "$_line" =~ [[:space:]]">>"[[:space:]]*(.+)$ ]]; then
        _out="${BASH_REMATCH[1]}"; _app=true; _line="${_line%%" >>"*}"
    elif [[ "$_line" =~ [[:space:]]">"[[:space:]]*(.+)$ ]]; then
        _out="${BASH_REMATCH[1]}"; _line="${_line%%" >"*}"
    fi
    if [[ -n "$_out" ]]; then
        local _r; _r="$(_real "$_out")"
        mkdir -p "$(dirname "$_r")" 2>/dev/null || true
        if $_app; then _dispatch "$_line" >> "$_r" 2>&1
        else           _dispatch "$_line" >  "$_r" 2>&1; fi
    else
        _dispatch "$_line"
    fi
}

if [[ "${1:-}" == "-c" && $# -ge 2 ]]; then
    _run_line "$2"
    exit
fi

# ── banner ────────────────────────────────────────────────────────────────────

clear
cat << 'BANNER'

  Microsoft Windows 95
  Copyright (C) Microsoft Corp 1981-1995.

  UU P&L Network Inventory System v2.3
  Hex Computing Division

  Authorised users only. Contact Ponder Stibbons for access issues.

BANNER
cmd_ver

# ── main loop ─────────────────────────────────────────────────────────────────

while true; do
    printf '%s> ' "$(_display_cwd)"
    IFS= read -r line || break
    _run_line "$line"
done