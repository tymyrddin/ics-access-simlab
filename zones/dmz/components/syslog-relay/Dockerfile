FROM balabit/syslog-ng:4.11.0
# UDP 514, plaintext, no TLS.
# Attack path: sniff monitoring traffic; spoof log entries to confuse incident response.
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
EXPOSE 514/udp
