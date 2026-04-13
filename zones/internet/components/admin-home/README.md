# Remote admin machine

Rincewind administers UU Power and Light remotely. His home machine has accumulated exactly the kind of artefacts that accumulate when convenience outranks hygiene: a weak SSH password, a Flask endpoint with default credentials, and a private key to the engineering workstation left in a directory named `.ssh-keys`. Three independent paths in, all active simultaneously. He is aware of the situation and is dealing with it.

## Where this fits in real OT

A remote administrator's personal machine with VPN access into the corporate network. Common in OT environments where a single engineer manages the control systems from home. The dual-homed configuration simulates an established VPN tunnel: the machine has a presence on both the internet and the enterprise network, making it a natural pivot point for anyone who compromises it.

## Container details

Base image: `debian:bookworm-slim`. Runs OpenSSH (port 22) and a Flask status application (port 80).

User: `rincewind`, password `wizzard`. The Flask endpoint's credentials are `admin:admin`. Neither has been changed since the machine was provisioned.

Python venv at `/opt/status-env` runs `status.py`. The WireGuard tools package is installed; no daemon runs.

Loot available once inside:
- `~/.vpn/uupl-vpn.conf`: WireGuard config listing enterprise and operational AllowedIPs (cosmetic, but useful for network mapping)
- `~/.ssh-keys/uupl_eng_key`: Ed25519 private key for `engineer@10.10.2.30`
- `~/notes.txt`: historian URL, SCADA URL, enterprise IPs

## Connections

- `ics_internet`: 10.10.0.10 (reachable from `unseen-gate`)
- `ics_enterprise`: 10.10.1.3 (the VPN tunnel endpoint; gives access to the enterprise zone)

## Protocols

- SSH: port 22
- HTTP: port 80 (`/status` endpoint, Basic auth)

## Built-in vulnerabilities

Three attack paths, all active simultaneously:

1. SSH brute force: `rincewind` / `wizzard`
2. OSINT pivot: `prior-recon.txt` in each adversary home on `unseen-gate` references 10.10.0.10
3. HTTP status endpoint: `GET /status` with `Authorization: Basic YWRtaW46YWRtaW4=` (`admin:admin`)

The SSH key for the engineering workstation is the primary loot. Everything else is reconnaissance.

## Modifying vulnerabilities

To change the SSH password: edit the `chpasswd` line in the Dockerfile.

To change Flask credentials: edit `ADMIN_USER` and `ADMIN_PASS` in `app/status.py`.

To remove the HTTP path entirely: remove the Flask install, the COPY of `status.py`, and the `exec` invocation in `entrypoint.sh`. Rebuild.

To add loot: place files in `loot/` and add COPY directives to the Dockerfile.

## Hardening suggestions

Use a strong, unique SSH password or disable password auth entirely. Rotate the Flask credentials. In a real deployment, private keys for production systems would not be kept on a personal machine in plaintext; the engineering workstation key is the main finding a post-incident review would note.

## Observability and debugging

```bash
docker logs admin-home
docker exec -it admin-home bash
ssh rincewind@10.10.0.10          # from unseen-gate; password: wizzard
curl -u admin:admin http://10.10.0.10/status
```

## Concrete attack paths

Path A (OSINT and SSH):
1. Read `~/loot/prior-recon.txt` on `unseen-gate`, find 10.10.0.10
2. `ssh rincewind@10.10.0.10`, password `wizzard`
3. Collect `~/.ssh-keys/uupl_eng_key` and `~/notes.txt`
4. `ssh -i uupl_eng_key engineer@10.10.2.30`

Path B (HTTP):
1. `curl -u admin:admin http://10.10.0.10/status` confirms VPN and network membership
2. Correlate with recon notes to orient within the topology

Path C (brute force):
1. `hydra -l rincewind -P /usr/share/wordlists/rockyou.txt ssh://10.10.0.10`
2. Same outcome as Path A

## Known oddities

The "VPN tunnel" is simulated by dual-homing. No WireGuard daemon runs. The `.vpn/uupl-vpn.conf` file exists purely as loot for participants who want the full narrative.

The enterprise NIC (10.10.1.3) is accessible from a shell on this machine immediately. No separate route or tunnel needed.

## In short

Remote admin machine, dual-homed into enterprise. Three simultaneous compromise paths. Primary loot: Ed25519 key for the engineering workstation. The machine is the VPN.
