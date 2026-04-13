#!/usr/bin/env bash
# UU P&L Legacy Workstation — DOS shell emulator
# Presents a Windows 95-era command prompt over SSH/Telnet.
# The filesystem lives at /opt/legacy/C with uppercase 8.3 names.
# Nothing here is spoofed at the OS level — it is all bash.

VIRT_ROOT="/opt/legacy/C"
VIRT_CWD=""   # path relative to VIRT_ROOT, empty = C:\ root

# Strip carriage returns that Telnet sends
stty icrnl 2>/dev/null || true

# ── path helpers ────────────────────────────────────────────────────────────

# Convert virtual DOS path to real Linux path.
# Input may be: FILENAME, SUBDIR\FILE, C:\FULL\PATH, or empty (= cwd).
_real() {
    local v="${1:-}"
    v="${v^^}"                  # uppercase
    v="${v//\\//}"              # backslash → forward slash
    v="${v#C:}"                 # strip drive letter
    v="${v#/}"                  # strip leading slash

    if [[ -z "$v" ]]; then
        # no argument: return current directory
        if [[ -z "$VIRT_CWD" ]]; then
            echo "$VIRT_ROOT"
        else
            echo "$VIRT_ROOT/$VIRT_CWD"
        fi
    elif [[ -z "$VIRT_CWD" ]] || [[ "$v" == /* ]]; then
        echo "$VIRT_ROOT/$v"
    else
        echo "$VIRT_ROOT/$VIRT_CWD/$v"
    fi
}

# Display form of current directory: C:\  or  C:\UUPL  etc.
_display_cwd() {
    if [[ -z "$VIRT_CWD" ]]; then
        echo 'C:\'
    else
        echo "C:\\${VIRT_CWD//\//\\}"
    fi
}

# ── commands ────────────────────────────────────────────────────────────────

cmd_ver() {
    printf '\nMicrosoft Windows 95 [Version 4.00.950]\n\n'
}

cmd_cls() {
    clear
}

cmd_dir() {
    local arg="${1:-}"
    local real

    if [[ -n "$arg" ]]; then
        real="$(_real "$arg")"
    else
        real="$(_real)"
    fi

    if [[ ! -d "$real" ]]; then
        echo "File Not Found"; return
    fi

    local show_path
    if [[ -n "$arg" ]]; then
        local v="${arg^^}"; v="${v//\\//}"; v="${v#C:}"; v="${v#/}"
        show_path="C:\\${v//\//\\}"
    else
        show_path="$(_display_cwd)"
    fi
    # strip trailing backslash from root so it prints C:\ not C:\\
    show_path="${show_path%\\}"
    [[ "$show_path" == "C:" ]] && show_path='C:\'

    printf '\n Volume in drive C is UUPL-SYS\n'
    printf ' Volume Serial Number is 2B7F-A4C1\n'
    printf '\n Directory of %s\n\n' "$show_path"

    local files=0 dirs=0 total=0

    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")
        local dosname="${name^^}"
        if [[ -d "$entry" ]]; then
            printf '%s  %s   <DIR>         %s\n' \
                "14/09/99" " 9:23a" "$dosname"
            (( dirs++ )) || true
        else
            local sz
            sz=$(stat -c%s "$entry" 2>/dev/null || echo 0)
            printf '%s  %s   %9s  %s\n' \
                "14/09/99" " 9:23a" "$sz" "$dosname"
            (( files++ )) || true
            (( total += sz )) || true
        fi
    done < <(find "$real" -maxdepth 1 -mindepth 1 -print0 | sort -z)

    printf '       %3d file(s)    %7d bytes\n' "$files" "$total"
    printf '       %3d dir(s)   1,048,576 bytes free\n\n' "$dirs"
}

cmd_cd() {
    local arg="${1:-}"

    # cd with no args or cd \ → root
    if [[ -z "$arg" ]] || [[ "$arg" == "\\" ]] || \
       [[ "${arg^^}" == "C:\\" ]] || [[ "${arg^^}" == "C:" ]]; then
        VIRT_CWD=""
        return
    fi

    if [[ "$arg" == ".." ]]; then
        if [[ -n "$VIRT_CWD" ]]; then
            VIRT_CWD="${VIRT_CWD%/*}"
            # if we stripped to nothing or to ".", reset
            [[ "$VIRT_CWD" == "." ]] && VIRT_CWD=""
        fi
        return
    fi

    local old_cwd="$VIRT_CWD"
    local v="${arg^^}"; v="${v//\\//}"; v="${v#C:}"; v="${v#/}"

    local new_cwd
    if [[ "$v" == /* ]] || [[ -z "$VIRT_CWD" ]]; then
        new_cwd="${v#/}"
    else
        new_cwd="$VIRT_CWD/$v"
    fi

    if [[ -d "$VIRT_ROOT/$new_cwd" ]]; then
        VIRT_CWD="$new_cwd"
    else
        echo "Invalid directory"
        VIRT_CWD="$old_cwd"
    fi
}

cmd_type() {
    local arg="${1:-}"
    if [[ -z "$arg" ]]; then
        echo "Required parameter missing"; return
    fi

    local real="$(_real "$arg")"

    if [[ ! -f "$real" ]]; then
        echo "File not found - $arg"; return
    fi

    cat "$real"
}

cmd_copy() {
    echo "Access denied."
}

cmd_del() {
    echo "Access denied."
}

cmd_net() {
    local sub="${1^^}"
    case "$sub" in
        USE)
            printf '\nNew connections will be remembered.\n\n'
            printf 'Status    Local   Remote                          Network\n'
            printf '----------------------------------------------------------------------\n'
            printf 'OK        F:      \\\\UUPL-SRV-01\\operations$       Microsoft Windows Network\n'
            printf 'OK        G:      \\\\hex-legacy-1\\public           Microsoft Windows Network\n\n'
            ;;
        VIEW)
            printf '\nServer Name            Remark\n'
            printf '----------------------------------------------------------------------\n'
            printf '\\\\HEX-LEGACY-1          UU P&L Inventory Server\n'
            printf '\\\\UUPL-SRV-01           File server / domain controller\n\n'
            ;;
        USER)
            printf '\nUser accounts for \\\\HEX-LEGACY-1\n'
            printf '----------------------------------------------------------------------\n'
            printf 'Administrator            Guest\n\n'
            ;;
        *)
            echo "The syntax of this command is incorrect."
            ;;
    esac
}

cmd_ping() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then echo "Usage: PING host-name"; return; fi

    printf '\nPinging %s with 32 bytes of data:\n\n' "$target"
    if ping -c 4 -W 1 "$target" &>/dev/null; then
        for _ in 1 2 3 4; do
            printf 'Reply from %s: bytes=32 time<1ms TTL=128\n' "$target"
        done
        printf '\nPing statistics for %s:\n' "$target"
        printf '    Packets: Sent = 4, Received = 4, Lost = 0 (0%% loss),\n'
        printf 'Approximate round trip times in milli-seconds:\n'
        printf '    Minimum = 0ms, Maximum = 1ms, Average = 0ms\n\n'
    else
        for _ in 1 2 3 4; do printf 'Request timed out.\n'; done
        printf '\nPing statistics for %s:\n' "$target"
        printf '    Packets: Sent = 4, Received = 0, Lost = 4 (100%% loss),\n\n'
    fi
}

cmd_netstat() {
    printf '\nActive Connections\n\n'
    printf '  Proto  Local Address          Foreign Address        State\n'
    netstat -tn 2>/dev/null \
      | awk 'NR>2 && /ESTABLISHED|LISTEN/ {
            printf "  %-6s %-22s %-22s %s\n", "TCP", $4, $5, $6
        }' \
      | head -12
    printf '\n'
}

cmd_ssh() {
    printf 'Opening secure shell...\n'
    /usr/bin/ssh -o StrictHostKeyChecking=no "$@"
}

cmd_ftp() {
    /usr/bin/ftp "$@"
}

cmd_telnet() {
    /usr/bin/telnet "$@"
}

cmd_nc() {
    /usr/bin/nc "$@"
}

cmd_curl() {
    /usr/bin/curl "$@"
}

cmd_nmap() {
    /usr/bin/nmap "$@"
}

cmd_help() {
    printf '\n'
    printf 'CD       Changes the current directory.\n'
    printf 'CLS      Clears the screen.\n'
    printf 'COPY     Copies files. (restricted on this system)\n'
    printf 'DEL      Deletes files. (restricted on this system)\n'
    printf 'DIR      Lists files and subdirectories.\n'
    printf 'EXIT     Quits COMMAND.COM.\n'
    printf 'FTP      Connects to an FTP server.\n'
    printf 'HELP     This help.\n'
    printf 'NC       Netcat — raw TCP connections.\n'
    printf 'NET      Network commands (USE / VIEW / USER).\n'
    printf 'NETSTAT  Displays active network connections.\n'
    printf 'NMAP     Network scanner.\n'
    printf 'PING     Tests network connectivity.\n'
    printf 'SSH      Opens a secure shell to a remote host.\n'
    printf 'TELNET   Connects to a Telnet server.\n'
    printf 'TYPE     Displays a text file.\n'
    printf 'VER      Displays the Windows version.\n'
    printf '\n'
}

# ── banner ───────────────────────────────────────────────────────────────────

clear
cat << 'BANNER'

  Microsoft Windows 95
  Copyright (C) Microsoft Corp 1981-1995.

  UU P&L Network Inventory System v2.3
  Hex Computing Division

  Authorised users only. Contact Ponder Stibbons for access issues.

BANNER
cmd_ver

# ── main loop ────────────────────────────────────────────────────────────────

while true; do
    printf '%s> ' "$(_display_cwd)"
    IFS= read -r line || break

    # strip CR
    line="${line//$'\r'/}"

    # split command and remainder
    read -r cmd rest <<< "$line"
    cmd="${cmd^^}"

    case "$cmd" in
        VER)     cmd_ver ;;
        CLS)     cmd_cls ;;
        DIR)     cmd_dir "$rest" ;;
        CD)      cmd_cd  "$rest" ;;
        TYPE)    cmd_type "$rest" ;;
        COPY)    cmd_copy ;;
        DEL|ERASE) cmd_del ;;
        NET)
            read -r sub _ <<< "$rest"
            cmd_net "$sub"
            ;;
        PING)    cmd_ping    "$rest" ;;
        NETSTAT) cmd_netstat ;;
        SSH)     cmd_ssh     $rest ;;
        FTP)     cmd_ftp     $rest ;;
        TELNET)  cmd_telnet  $rest ;;
        NC)      cmd_nc      $rest ;;
        CURL)    cmd_curl    $rest ;;
        NMAP)    cmd_nmap    $rest ;;
        HELP|"/?") cmd_help ;;
        EXIT|QUIT|LOGOUT|BYE)
            printf '\n'
            exit 0
            ;;
        "")      true ;;
        *)       printf "Bad command or file name\n" ;;
    esac
done