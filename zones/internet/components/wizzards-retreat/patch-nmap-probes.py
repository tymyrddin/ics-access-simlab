probes_path = '/usr/share/nmap/nmap-service-probes'
with open(probes_path) as f:
    content = f.read()

SENTINEL = '# ics-simlab patches applied'
if SENTINEL in content:
    exit(0)


def insert_first(text, probe_name, match_line):
    """Insert match_line before the first match entry in the named TCP probe section."""
    marker = f'\nProbe TCP {probe_name} '
    pos = text.find(marker)
    if pos == -1:
        return text
    next_probe = text.find('\nProbe ', pos + 1)
    end = next_probe if next_probe != -1 else len(text)
    section = text[pos:end]
    first = section.find('\nmatch ')
    insert_at = pos + (first if first != -1 else len(section))
    return text[:insert_at + 1] + match_line + '\n' + text[insert_at + 1:]


# hex-legacy-1 port 23: win95shell.sh sends a clear-screen sequence then the
# "Microsoft Windows 95" banner.  It never emits IAC bytes; it only drains
# incoming ones.  An existing landesk-rc match in GenericLines fires on the
# response first.  Insert our match before all others in that section.
content = insert_first(content, 'GenericLines',
    'match telnet m|Microsoft Windows 95| '
    'p/hex-legacy-1 legacy shell/ i/no authentication, direct access/')

# Flask/Werkzeug services return HTTP 400/404 to RTSP, Help, Socks5, and
# FourOhFourRequest probes.  nmap has no match for these response formats so
# it emits fingerprint blobs.  Add matches in each probe section to suppress
# the blobs without affecting how the service is already labelled from
# GetRequest and HTTPOptions.
content = insert_first(content, 'RTSPRequest',
    r'softmatch http m|^HTTP/1\.1 400 Bad Request\r\nServer: Werkzeug| '
    r'p/Werkzeug Flask HTTP/ i/rejects RTSP probe/')

content = insert_first(content, 'Help',
    r'softmatch http m|^HTTP/1\.1 400 Bad Request\r\nServer: Werkzeug| '
    r'p/Werkzeug Flask HTTP/ i/rejects Help probe/')

content = insert_first(content, 'Socks5',
    r'softmatch http m|^HTTP/1\.1 400 Bad Request\r\nServer: Werkzeug| '
    r'p/Werkzeug Flask HTTP/ i/rejects Socks5 probe/')

content = insert_first(content, 'FourOhFourRequest',
    r'softmatch http m|^HTTP/1\.1 404 NOT FOUND\r\nServer: Werkzeug| '
    r'p/Werkzeug Flask HTTP/')

content += f'\n{SENTINEL}\n'

with open(probes_path, 'w') as f:
    f.write(content)