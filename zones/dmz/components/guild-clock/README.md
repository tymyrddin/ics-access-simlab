# NTP server

`guild-clock` provides NTP to the DMZ. It runs `cturra/ntp`, a lightweight
NTP server container (uses `chronyd` internally). There is no NTP authentication;
any host that reaches UDP port 123 can synchronise its clock from this server.

Time is not glamorous. Attacks that manipulate it tend to be preconditions for
other attacks: expired certificates begin to look valid, log timestamps become
unreliable, and replay protection based on timing becomes ineffective.

## NTP in OT environments

NTP servers are critical infrastructure in ICS environments: PLCs, RTUs, and
uupl-historian databases all depend on synchronised time for log correlation, sequence-
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

Unauthenticated NTP: the server accepts time synchronisation requests from any
client without authentication. Any host on the DMZ can use this server as its
time source, and an on-path attacker can substitute forged NTP responses.

No NTP amplification: the `cturra/ntp` image runs `chronyd`, not ntpd. The
`monlist` amplification vector is ntpd-specific and does not apply here.

Time manipulation: an attacker who can poison NTP responses seen by DMZ hosts
can shift their system clocks. Effects include: TLS certificates appearing
expired or not-yet-valid, log timestamps becoming unreliable, and replay-
protection windows becoming exploitable.

## Modifying vulnerabilities

To add NTP authentication: chrony supports NTP symmetric key authentication via
the `key` and `authselectmode` directives. A custom `chrony.conf` volume mount
is needed. Clients also need the matching key configured.

To restrict which clients can use the server: add `allow` directives in
`chrony.conf` to limit the source range.

## Hardening suggestions

Enable NTP symmetric key authentication. Restrict `allow` to the specific subnets
that legitimately need time service. Ensure the NTP server is not accessible from
the public internet.

## Observability and debugging

```bash
docker logs guild-clock
docker exec guild-clock chronyc tracking    # server status (local only)
ntpdate -q 10.10.5.30                       # query time offset without changing local clock
```

## Concrete attack paths

From the internet zone:

1. `ntpdate -q 10.10.5.30` confirms the server is reachable and shows the
   time offset and stratum.
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

The image uses `chronyd`, not `ntpd`. Tools that target ntpd management
interfaces (`ntpq`, `ntpdc`) do not apply. Use `ntpdate -q` for external time
queries; `chronyc` only works locally inside the container.

NTP responses traverse UDP, which is connectionless. An on-path attacker does
not need to compromise the NTP server to substitute responses; they only need
to intercept the UDP exchange between a client and the server.

## At a glance

NTP server (chronyd), UDP 123, no authentication. Useful as a precondition
for time-manipulation attacks that affect TLS and log integrity.
