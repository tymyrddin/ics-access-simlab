# DNS forwarder

`city-directory` is a BIND9 recursive resolver serving the DMZ. It accepts
queries from any source (`allow-query { any; }`), allows recursion from any
source (`allow-recursion { any; }`), and has DNSSEC validation disabled. It
forwards unresolved queries to 8.8.8.8 and 8.8.4.4.

The combination of open recursion and no DNSSEC validation makes this a workable
DNS amplification reflector and a target for cache poisoning. Cache poisoning is
the operationally significant path: a poisoned entry for `uupl-historian.uupl.am`
redirects any client that uses this resolver to an attacker-controlled address,
enabling credential harvest.

## DNS in OT networks

DNS infrastructure in OT environments is frequently inherited from IT and
deployed without OT-specific hardening. Open recursion was acceptable in the
1990s when the internet was smaller; disabling it is straightforward but
requires knowing to do it. DNSSEC validation is disabled more often than not
because it adds complexity and can cause resolution failures for domains with
misconfigured signatures. The practical result is a resolver that will accept
poisoned answers and serve them to clients.

## Container details

Base image: `internetsystemsconsortium/bind9:9.20`. https://hub.docker.com/r/internetsystemsconsortium/bind9
Exposed ports: 53/tcp and 53/udp.

Named configuration:
- `allow-query { any; }`: accepts queries from any source
- `allow-recursion { any; }`: performs recursive resolution for any client
- `dnssec-validation no`: accepts unsigned or incorrectly signed responses
- `forwarders { 8.8.8.8; 8.8.4.4; }`: forwards unresolved queries upstream

## Connections

- `ics_dmz`: 10.10.5.31
- Reachable from `ics_internet` and from within `ics_dmz`

## Protocols

DNS: UDP and TCP port 53.

## Built-in vulnerabilities

Open recursion: any host on the internet (or the DMZ) can use this resolver for
arbitrary DNS lookups. This enables DNS amplification attacks using this server
as a reflector: a forged query with the victim's source address elicits a
response many times larger than the query.

No DNSSEC validation: the resolver accepts unsigned DNS responses and responses
with invalid signatures. An attacker who can intercept or influence the resolver's
upstream queries can substitute forged answers, which the resolver will cache and
serve to clients.

Cache poisoning path: a poisoned A record for a hostname that DMZ clients query
(e.g. `historian.uupl.am`) redirects those clients to an attacker-controlled
address. If any DMZ component queries the historian by hostname and uses this
resolver, its HTTP requests (including any credential headers) go to the
attacker.

BIND9 version disclosure: `dig version.bind chaos txt @10.10.5.31` returns the
BIND9 version string unless explicitly hidden.

## Modifying vulnerabilities

To restrict recursion to the DMZ only: change `allow-recursion { any; }` to
`allow-recursion { 10.10.5.0/24; }` in `named.conf`.

To enable DNSSEC validation: change `dnssec-validation no` to
`dnssec-validation auto` and ensure the root trust anchor is present (BIND9
includes it by default).

To hide the version: add `version "not disclosed";` to the `options` block.

To disable the open resolver entirely: remove `allow-recursion` or set it to
`none`.

## Hardening suggestions

Restrict recursion to the specific subnets that legitimately use this resolver.
Enable DNSSEC validation. Hide the version string. Apply rate limiting
(`rate-limit` clause) to prevent amplification abuse.

## Observability and debugging

```bash
docker logs dns-forwarder
dig @10.10.5.31 google.com                # test recursive resolution
dig version.bind chaos txt @10.10.5.31   # BIND version disclosure
```

## Concrete attack paths

From the internet zone:

1. `dig @10.10.5.31 version.bind chaos txt` discloses the BIND version.
2. Use this resolver for open recursion: resolve any external hostname via
   `dig @10.10.5.31 <hostname>`.
3. Cache poisoning (requires control over a name server in the resolution path
   or on-path position): forge a DNS response for a hostname queried by a DMZ
   component, substitute an attacker-controlled IP, and wait for the poisoned
   entry to be cached and served.
4. DNS amplification reflector: send forged queries with the victim's source
   address to UDP 53; the resolver's larger responses are directed at the victim.

## Heads up

Cache poisoning in a modern BIND9 instance is significantly harder than in older
implementations due to source port randomisation and query ID randomisation.
The `dnssec-validation no` setting removes one layer of protection but does not
make poisoning trivial; it requires an on-path or timing attack.

The forwarders (8.8.8.8, 8.8.4.4) are external. In an airgapped deployment,
these may be unreachable and the resolver will fail to resolve external names.
Replace with internal forwarder addresses if needed.

TCP port 53 is exposed alongside UDP for queries and zone transfers that exceed
UDP size limits. BIND9 allows zone transfers by default only to explicit
`allow-transfer` targets; without configuration, zone transfers to arbitrary
hosts are refused.

## The short version

BIND9 recursive resolver, open recursion, DNSSEC validation off. Any host can
use it as a forwarder or amplification reflector. Cache poisoning redirects
DNS-dependent DMZ clients to attacker-controlled addresses. Version string is
disclosed by default.
