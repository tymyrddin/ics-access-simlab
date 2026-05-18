probes_path = '/usr/share/nmap/nmap-service-probes'
with open(probes_path) as f:
    content = f.read()

# hex-legacy-1 telnet sends IAC WILL CHARSET + WILL LINEMODE + DO TERMTYPE +
# DO FLOWCONTROL + DO NAWS + DO ENVIRON + DO OLD-ENVIRON in response to the
# GenericLines probe. nmap has no match for this sequence, so it emits a
# fingerprint blob instead of labelling the service version.
new_match = (
    r'match telnet m|^\xff\xfb\x25\xff\xfb\x26\xff\xfd\x18'
    r'\xff\xfd\x20\xff\xfd\x23\xff\xfd\x27\xff\xfd\x24| p/telnet/'
)

if new_match in content:
    exit(0)

gl_pos = content.find('\nProbe TCP GenericLines ')
if gl_pos == -1:
    raise SystemExit('GenericLines probe not found in nmap-service-probes')

next_probe = content.find('\nProbe ', gl_pos + 1)
section = content[gl_pos:next_probe] if next_probe != -1 else content[gl_pos:]

first_telnet = section.find('\nmatch telnet ')
if first_telnet == -1:
    insert_at = gl_pos + len(section)
else:
    insert_at = gl_pos + first_telnet

patched = content[:insert_at + 1] + new_match + '\n' + content[insert_at + 1:]
with open(probes_path, 'w') as f:
    f.write(patched)
