with open('/usr/share/nmap/nmap-service-probes') as f:
    content = f.read()

old = r'match http m|^HTTP/1\.0 \d\d\d [A-Z ]*\r.*\nServer: Werkzeug/([\w._-]+) Python/([\w._-]+)\r\n|s p/Werkzeug httpd/ v/$1/ i/Python $2/ cpe:/a:python:python:$2/'
new = (old + '\n' +
       r'match http m|^HTTP/1\.1 \d\d\d [^\r]*\r\n(?:[^\r\n]+\r\n)*?Server: Werkzeug/([\w._-]+) Python/([\w._-]+)\r\n|s p/Werkzeug httpd/ v/$1/ i/Python $2/ cpe:/a:python:python:$2/')

if old in content and new not in content:
    with open('/usr/share/nmap/nmap-service-probes', 'w') as f:
        f.write(content.replace(old, new, 1))
