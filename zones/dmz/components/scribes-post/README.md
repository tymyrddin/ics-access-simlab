# Syslog relay

`scribes-post` is a syslog-ng relay that accepts UDP syslog messages from any
source on port 514 and appends them to `/var/log/syslog-relay.log`. No TLS.
No source authentication. Any host that can reach UDP 514 can write log entries.

In incident response, the log file is the record of what happened. A log relay
that accepts forged entries from any source is a record that an attacker can
edit in real time, retroactively or prospectively.

## Centralised logging in OT

Centralised log collection is a security control. Syslog over UDP with no
authentication is the historical default and remains common in OT environments
where the network was assumed to be trusted. A logging relay that accepts entries
from any source allows an attacker who has gained a foothold to inject log
events, remove evidence of their activity (by flooding the log with noise), or
create false attribution. These techniques are described in MITRE ATT&CK under
T1565.001 (Stored Data Manipulation) and T1070 (Indicator Removal on Host).

## Container details

Base image: `balabit/syslog-ng:4.11.0`. https://hub.docker.com/r/balabit/syslog-ng

Exposed port: 514/udp.

Configuration:
- Source `s_udp`: UDP on port 514, accepts from any source
- Destination `d_file`: appends to `/var/log/syslog-relay.log`
- No TLS. No source filtering. No authentication.

## Connections

- `ics_dmz`: 10.10.5.32
- Accepts syslog from any host on `ics_dmz` and `ics_internet`

## Protocols

Syslog (RFC 3164 / RFC 5424): UDP port 514.

## Built-in vulnerabilities

Unauthenticated syslog: any host that can reach UDP 514 can inject log entries
with any source hostname, severity, and message content. The relay writes
whatever it receives to the log file without validation.

No TLS: syslog messages are plaintext. Any host on `ics_dmz` can intercept
the message stream with a packet capture.

Log injection: an attacker can write log entries that attribute malicious
activity to other hosts, create false alarms to distract incident responders,
or flood the log to obscure genuine events.

Log interception: an on-path attacker between legitimate syslog sources and
this relay can intercept, modify, or drop log messages before they reach the
relay.

## Modifying vulnerabilities

To add TLS: configure a `tls()` block in the source definition and mount
certificates. syslog-ng supports TLS with client certificate verification.

To restrict which sources are accepted: add source IP filters or use the
`network()` source with an explicit `allow-hosts` option.

To add a separate secure log path for audit events: add a second source with
TLS and client certificate authentication, writing to a separate destination
file with more restrictive permissions.

## Hardening suggestions

Enable TLS with client certificate authentication. Restrict the source address
range to the specific hosts that legitimately send logs. Separate audit-critical
logs from general syslog to a destination that requires authentication.

## Observability and debugging

```bash
docker logs syslog-relay
docker exec -it syslog-relay cat /var/log/syslog-relay.log
```

Send a test syslog message:
```bash
logger -n 10.10.5.32 -P 514 --udp "test message from $(hostname)"
```

## Concrete attack paths

From the internet zone or from within the DMZ:

Inject a false log entry (e.g. attributing an action to another host):
```bash
logger -n 10.10.5.32 -P 514 --udp \
  -t "sshd" "Accepted password for root from 10.10.1.10 port 44231 ssh2"
```

Flood the log to obscure genuine events:
```bash
while true; do
  logger -n 10.10.5.32 -P 514 --udp "normal operation" &
done
```

Intercept legitimate syslog traffic: capture UDP 514 on `ics_dmz` with
tcpdump and read log entries from other DMZ hosts as they are sent.

## Odd behaviours

UDP syslog is connectionless and fire-and-forget. The relay has no mechanism
to acknowledge receipt or detect dropped messages. In a noisy environment,
high-volume injection or flooding will appear in the log file alongside genuine
entries.

The `keep-hostname(yes)` option in syslog-ng preserves the hostname field from
incoming syslog messages. An attacker can set this field to any value; it is not
validated against the source IP.

The log file (`/var/log/syslog-relay.log`) is inside the container and is lost
on container restart unless volume-mounted. In a persistent deployment, mounting
this to a host path or a volume preserves the log across restarts.

## Bottom line

syslog-ng relay, UDP 514, no TLS, no authentication. Accepts log entries from
any source. Any host on the DMZ can inject log entries with arbitrary hostname,
severity, and content. The log is the incident record; this host accepts edits
from anyone.
