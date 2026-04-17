# Remote admin machine

Rincewind administers UU Power and Light remotely. His home machine has accumulated exactly the kind of artefacts that accumulate when convenience outranks hygiene: a weak SSH password, a world-readable NFS share with a private key sitting in it, and a key to the engineering workstation filed under `.ssh-keys`. Two independent paths in. He is aware of the situation and is dealing with it.

## Where this fits in real OT

A remote administrator's personal machine with VPN access into the corporate network. Common in OT environments where a single engineer manages the control systems from home. The dual-homed configuration simulates an established VPN tunnel: the machine has a presence on both the internet and the enterprise network, making it a natural pivot point for anyone who compromises it.

## Container details

Base image: `debian:bookworm-slim`. Runs OpenSSH (port 22) and NFS-Ganesha (user-space NFSv3 server, ports 111/2049/20048).

User: `rincewind`, password `wizzard`. Neither has been changed since the machine was provisioned.

The WireGuard tools package is installed; no daemon runs. NFS-Ganesha exports a tmpfs staging directory as `/work` 
(pseudo path). The tmpfs workaround is needed because Docker's OverlayFS does not support `name_to_handle_at()`, 
which the VFS FSAL requires. The container runs `privileged: true` for this reason.

Loot available once on the NFS share:

- `/work/notes.txt`: VPN instructions, engineering workstation address, SCADA and historian URLs
- `/work/rincewind_id_ed25519`: rincewind's Ed25519 private key, left here and forgotten. The corresponding public key is in `~/.ssh/authorized_keys`, so this key opens a direct SSH session.

Additional loot available after SSH login:

- `~/.vpn/uupl-vpn.conf`: WireGuard config listing enterprise and operational AllowedIPs (cosmetic, but useful for network mapping)
- `~/.ssh-keys/uupl_eng_key`: Ed25519 private key for `engineer@10.10.2.30`
- `~/notes.txt`: same notes file, also present in the home directory

## Connections

- `ics_internet`: 10.10.0.10 (reachable from `unseen-gate`)
- `ics_enterprise`: 10.10.1.3 (the VPN tunnel endpoint; gives access to the enterprise zone)
- `ics_operational`: 10.10.2.3 (simulates VPN AllowedIPs covering 10.10.2.0/24; makes the engineering workstation reachable)

## Protocols

- SSH: port 22
- rpcbind: port 111
- NFS: port 2049
- mountd: port 20048

## Built-in vulnerabilities

1. SSH brute force or guess weak password: `rincewind` / `wizzard`
2. NFS credential theft: `/work` exported world-readable with no authentication (`all_squash`, no client restriction), and contains `rincewind_id_ed25519`, a private key with a matching entry in `~/.ssh/authorized_keys`
3. OSINT: `prior-recon.txt` in each adversary home on `unseen-gate` references 10.10.0.10 with open ports; leads to path 1 or 2

The SSH key for the engineering workstation is the primary loot. The NFS share contains the notes file that points toward it.

## Modifying vulnerabilities

To change the SSH password: edit the `chpasswd` line in the Dockerfile.

To restrict NFS access: add a `CLIENT { Clients = 10.10.0.5; ... }` block to `ganesha.conf` and rebuild.

To add loot: place files in `loot/` and add COPY directives to the Dockerfile. The entrypoint copies `loot/` contents to the tmpfs at startup, so files added to `/home/rincewind/work` via the Dockerfile end up in the NFS export automatically.

## Observability and debugging

```bash
docker logs admin-home
docker exec -it admin-home bash
ssh rincewind@10.10.0.10          # from unseen-gate; password: wizzard
showmount -e 10.10.0.10                              # from attacker machine or host
sudo mount -t nfs -o vers=3 10.10.0.10:/work /mnt   # from attacker machine (passwordless sudo)
```

## Known oddities

The "VPN tunnel" is simulated by dual-homing. No WireGuard daemon runs. The `.vpn/uupl-vpn.conf` file exists purely as 
loot for participants who want the full narrative.

The enterprise NIC (10.10.1.3) is accessible from a shell on this machine immediately. No separate route or tunnel 
needed.

NFS-Ganesha logs to stdout. `docker logs admin-home` shows the full startup sequence. The DBUS and Kerberos warnings at 
startup are expected in a containerised environment and do not affect NFS operation.

## In short

Remote admin machine, dual-homed into enterprise. Two compromise paths: NFS credential theft (mount the
world-readable share, take the private key, SSH in) and weak SSH password. Either way in, the engineering
workstation key is in the home directory. The machine is the VPN.
