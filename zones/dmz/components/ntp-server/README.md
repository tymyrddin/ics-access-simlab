# NTP server

`guild-clock` provides NTP to the DMZ. It runs `cturra/ntp`, a lightweight
NTP server container. There is no NTP authentication; `ntpq` and `ntpdc` queries
are open to any host that reaches UDP port 123.

Time is not glamorous. Attacks that manipulate it tend to be preconditions for
other attacks: expired certificates begin to look valid, log timestamps become
unreliable, and replay protection based on timing becomes ineffective.

## NTP in OT environments

NTP servers are critical infrastructure in ICS environments: PLCs, RTUs, and
historian databases all depend on synchronised time for log correlation, sequence-
of-events analysis, and certificate validation. Unauthenticated NTP is the
overwhelming norm in OT networks. NTP amplification and time-of-day manipulation
are documented attack techniques; the former is a denial-of-service amplification
vector, the latter is a long-game persistence technique.

## Container details

Base image: `cturra/ntp@sha256:7224d4e7c7833aabbcb7dd70c46c8a8dcccda365314c6db047b9b10403ace3bc`
(pinned by digest; no semver tag on this image). https://hub.docker.com/r/cturra/ntp

Exposed port: 123/udp.

No NTP authentication (no symmetric key or autokey configuration).

## Connections

- `ics_dmz`: 10.10.5.30
- Reachable from `ics_internet` and from within `ics_dmz`

## Protocols

NTP: UDP port 123. No authentication.

## Built-in vulnerabilities

Unauthenticated NTP: `ntpq` and `ntpdc` queries are accepted without any key
or authentication mode. Any host on the DMZ can query the server's status, peer
list, and configuration.

NTP amplification: an NTP server that responds to `monlist` requests (older NTP
versions) provides a significant amplification factor for reflected UDP attacks.
The cturra/ntp image uses a recent ntpd; `monlist` is disabled by default in
modern NTP. However, other queries remain open.

Time manipulation: an attacker who can poison NTP responses seen by DMZ hosts
can shift their system clocks. Effects include: TLS certificates appearing
expired or not-yet-valid, log timestamps becoming unreliable, and replay-
protection windows becoming exploitable.

## Modifying vulnerabilities

To add NTP symmetric key authentication: generate a key file, configure `keys`
and `trustedkey` directives in the NTP configuration, and distribute the key to
authorised clients. This requires a custom configuration volume mount.

To restrict queries: add `restrict` directives in the NTP configuration to limit
which hosts can query the server.

## Hardening suggestions

Enable NTP symmetric key authentication. Restrict `ntpq` and `ntpdc` queries
to management addresses. Ensure the NTP server is not accessible from the public
internet to prevent amplification.

## Observability and debugging

```bash
docker logs ntp-server
ntpq -p 10.10.5.30          # peer list query
ntpdate -q 10.10.5.30       # query time offset without changing local clock
```

## Concrete attack paths

From the internet zone:

1. `ntpq -p 10.10.5.30` confirms the server is responding and shows its
   upstream peers.
2. Forge NTP responses to a DMZ host: tools such as `ntpdate` in step-mode or
   a custom NTP packet forger can shift a vulnerable client's clock by several
   hours.
3. A shifted clock on the SSH bastion or SFTP drop affects the validity window
   of TLS session tickets and certificate validation if those services depend on
   NTP synchronisation.

## Watch out for

The `cturra/ntp` image is pinned by digest because there is no semver tag; the
image has only a `latest` tag. The digest pins the exact image version at time
of implementation.

NTP responses traverse UDP, which is connectionless. An on-path attacker does
not need to compromise the NTP server to substitute responses; they only need
to intercept the UDP exchange between a client and the server.

## At a glance

NTP server, UDP 123, no authentication. Open to `ntpq` / `ntpdc` queries.
Useful for reconnaissance (peer list reveals NTP topology) and as a precondition
for time-manipulation attacks that affect TLS and log integrity.
