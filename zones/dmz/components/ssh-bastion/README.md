# SSH bastion

`contractors-gate` is the SSH bastion host at the IT/OT boundary of the DMZ.
It is dual-homed: internet-facing on `ics_dmz` (10.10.5.20) and enterprise-facing
on `ics_enterprise` (10.10.1.30). A shell on this machine provides a pivot point
into the enterprise network from the DMZ.

The image is `debian:12.0`, the original bookworm release, which ships
OpenSSH 9.2p1-2 (pre-regreSSHion patch). The primary attack surface is simpler
than a race condition: `PermitRootLogin yes` with root password `uupl2015`.

`AllowAgentForwarding yes` means a participant who compromises this host can
forward their SSH agent and use it to authenticate to downstream enterprise
hosts as if they were sitting at the bastion.

## How this maps to real OT networks

SSH bastion hosts are a common architectural control for remote access into
industrial networks: a single hardened jump point through which all external
SSH connections pass. In practice, bastion hosts are often the least-well-
maintained machines in the estate: they are "infrastructure" rather than
"application", and security patches fall behind operational concerns. The
regreSSHion vulnerability (CVE-2024-6387) affected OpenSSH 9.2p1-2 and earlier,
which is the exact version shipped with the original Debian 12.0 image.

## Container details

Base image: `debian:12.0`. Ships `openssh-server 9.2p1-2`.

SSH configuration:
- `PermitRootLogin yes`
- `PasswordAuthentication yes`
- `AllowAgentForwarding yes`

Root password: `uupl2015`.

CVE-2024-6387 (regreSSHion): a signal handler race condition in OpenSSH versions
before 9.2p1-2+deb12u3 that can lead to unauthenticated remote code execution
on glibc-based Linux systems. The vulnerability is present in this image.
Exploitation is timing-dependent and not guaranteed to be reliable; the simpler
attack path is the `root` / `uupl2015` credential.

rsyslog is running inside the container and forwards all syslog events (including
sshd auth successes, failures, and session open/close) to `scribes-post`
(10.10.5.32:514) over UDP. No TLS.

Exposed port: 22/tcp.

## Connections

- `ics_dmz`: 10.10.5.20 (internet-facing)
- `ics_enterprise`: 10.10.1.30 (enterprise-facing pivot point)
- Firewall: only this host in the DMZ is permitted to reach `ics_enterprise`

## Protocols

SSH: port 22.

## Built-in vulnerabilities

Default root credential: `root` / `uupl2015`. SSH as root is enabled with
password authentication. Any host reachable from the internet zone can
authenticate directly as root.

Agent forwarding: `AllowAgentForwarding yes`. An attacker who establishes a
session with agent forwarding enabled can use a forwarded agent to SSH from this
host to enterprise-zone machines without the private key being present on the
bastion.

CVE-2024-6387 (regreSSHion): present in `openssh-server 9.2p1-2`. A timing
attack via signal handler race. Exploitation requires multiple connection
attempts and is glibc-dependent; success is probabilistic rather than
deterministic. The intended attack path in this scenario is the credential.

Enterprise pivot: the enterprise NIC (10.10.1.30) provides access to
`ics_enterprise`. Combined with credentials found on the enterprise zone (e.g.
from `hex-legacy-1` or `bursar-desk`), a shell on this machine enables lateral
movement to historian, SCADA, and engineering workstation.

## Modifying vulnerabilities

To disable root login: change `PermitRootLogin yes` to `PermitRootLogin no` in
`sshd_config`.

To change the root password: edit the `chpasswd` line in `entrypoint.sh`.

To disable agent forwarding: change `AllowAgentForwarding yes` to `no` in
`sshd_config`.

To patch regreSSHion: replace `debian:12.0` with `debian:12` (latest point
release, which includes the backported fix) in the Dockerfile.

To remove the enterprise NIC: edit `ctf-config.yaml` under `ssh_bastion` and
remove the `enterprise_ip` entry.

## Hardening suggestions

Replace password authentication with public-key-only authentication and disable
`PermitRootLogin`. Disable `AllowAgentForwarding` unless specifically required.
Keep the base image on a recent point release to receive security backports.
Apply firewall rules that restrict source IPs on the enterprise NIC to the
specific hosts that legitimately use this bastion.

## Observability and debugging

```bash
docker logs ssh-bastion
ssh root@10.10.5.20          # password: uupl2015 (from ics_dmz or ics_internet)
```

From inside the bastion, the enterprise network is reachable:
```bash
ssh root@10.10.5.20
ping 10.10.1.10              # hex-legacy-1 on ics_enterprise
```

## Concrete attack paths

Password credential (primary path):
1. `ssh root@10.10.5.20` with password `uupl2015`.
2. From the enterprise NIC (10.10.1.30), reach `ics_enterprise` hosts.
3. `ssh bursardesk@10.10.1.20` or `smbclient //10.10.1.10/public -N` using
   credentials from the enterprise zone.

Agent forwarding pivot:
1. SSH to the bastion with agent forwarding: `ssh -A root@10.10.5.20`.
2. From the bastion shell, `ssh engineer@10.10.2.30` using the forwarded agent
   if the engineering workstation trusts the attacker's key.

regreSSHion (CVE-2024-6387):
- Connect repeatedly to port 22 and trigger the signal handler race condition.
- If exploitation succeeds, the result is unauthenticated root code execution.
- Relevant PoC code is in the public domain following the 2024 disclosure.

## Odd behaviours

The bastion is dual-homed: the container has both `ics_dmz` and `ics_enterprise`
interfaces. From a shell on the container, both network segments are directly
reachable.

`AllowAgentForwarding yes` is required for the agent-forwarding pivot path. It
does nothing on its own; the attacker needs to connect with `ssh -A` to forward their
agent.

The enterprise NIC (10.10.1.30) is a new IP on the enterprise segment, not
previously documented in the enterprise zone's network inventory (which shows
10.10.1.3, 10.10.1.10, 10.10.1.20). A thorough `nmap` of the enterprise subnet
would reveal it.

## In short

SSH bastion, dual-homed into DMZ (10.10.5.20) and enterprise (10.10.1.30).
Root login enabled with password `uupl2015`. Agent forwarding on. OpenSSH
9.2p1-2 is vulnerable to CVE-2024-6387 (regreSSHion). The simplest path is
the credential; the vulnerability is the optional flourish.
