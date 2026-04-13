# Legacy workstation

`hex-legacy-1` has been running since the late 1990s. The hardware was replaced in 2003; the software was migrated intact because nothing was broken. Nothing has changed since because it still works. It runs Samba with NTLMv1 and LAN Manager hashes, FTP with anonymous read access, Telnet, and SSH added later by someone who needed remote access and left PermitRootLogin enabled. The attack surface is not a misconfiguration: it is the correct operation of 1990s software in 2024.

## The real-world parallel

A legacy workstation running era-appropriate software that was never decommissioned because it hosts files the rest of the network still depends on. Common in OT environments where uptime requirements prohibit upgrades and the vendor stopped supporting the OS before the site even considered replacing it. The security model assumed that anyone on the network was authorised to be there.

## Container details

Base image: `debian:bookworm-slim` presenting a Windows 95-era facade via a custom login shell (`win95shell.sh`). The real filesystem is under `/opt/legacy/C/`. SSH drops users into a DOS-style shell with 8.3 filenames.

Services: Samba (ports 139, 445), vsftpd (port 21), Telnet via xinetd (port 23), OpenSSH (port 22).

Accounts: `Administrator` / `hex123` (also set as Samba password and root SSH password). Anonymous Samba guest access to the `public` share.

Exposed ports: 21, 22, 23, 139, 445.

## Connections

- `ics_enterprise`: 10.10.1.10
- Reachable from `wizzards-retreat` (10.10.1.3) and `bursar-desk` (10.10.1.20)

## Protocols

- SMB/CIFS: ports 139, 445. NTLMv1 enabled, LAN Manager hashes accepted. Guest access to `\\hex-legacy-1\public`.
- FTP: port 21. Anonymous read access to the public share contents.
- Telnet: port 23. Plaintext, no encryption.
- SSH: port 22. Password auth, `PermitRootLogin yes`.

## Built-in vulnerabilities

NTLMv1 and LM hashes enabled: any captured challenge/response can be cracked offline or relayed. Null session / guest SMB access: the `public` share requires no authentication and contains operational documents. FTP anonymous access: same documents available over plaintext FTP. Telnet: credentials transmitted in cleartext, capturable with tcpdump from anywhere on the enterprise segment. SSH with root and weak password: `root`/`hex123`.

Key loot in `\\hex-legacy-1\public`: `C:\UUPL\NETWORK.TXT` (full network inventory including historian, SCADA, engineering workstation IPs and credentials), `C:\UUPL\PROCS.TXT` (operating procedures referencing Modbus addresses), `C:\LOGBOOK\ENGINEER.LOG` (all system passwords in plaintext, described as "informal notes").

The `private` share is restricted to `Administrator` but contains the same credential list in `plc-access.conf`.

## Modifying vulnerabilities

To disable LM/NTLMv1: set `lanman auth = no` and `ntlm auth = ntlmv2-only` in the smb.conf block in `entrypoint.sh`.

To remove anonymous FTP: set `anonymous_enable=NO` in the vsftpd config block.

To remove Telnet: delete the xinetd config block and remove `telnetd` from the apt install list.

To change the password: update the `chpasswd` line and the `smbpasswd` invocation in `entrypoint.sh`.

To modify loot: edit the heredoc blocks in `entrypoint.sh` that write to `/opt/legacy/C/`.

## Hardening suggestions

Disable LM/NTLMv1; require NTLMv2. Remove anonymous FTP and guest Samba access. Remove Telnet entirely. Set `PermitRootLogin no` in sshd_config. Move sensitive documents off a world-readable share.

## Observability and debugging

```bash
docker logs legacy-workstation
docker exec -it legacy-workstation bash
smbclient //10.10.1.10/public -N           # anonymous access; list and get files
ftp 10.10.1.10                             # user: anonymous
ssh root@10.10.1.10                        # password: hex123
telnet 10.10.1.10
```

The virtual C: drive is at `/opt/legacy/C/` inside the container. The win95shell simulates DOS navigation; `DIR`, `TYPE`, `CD` work as expected.

## Concrete attack paths

From `wizzards-retreat` (10.10.1.3) or `bursar-desk` (10.10.1.20):

1. `smbclient //10.10.1.10/public -N`
2. `get C:\UUPL\NETWORK.TXT` and `get C:\LOGBOOK\ENGINEER.LOG`
3. Credentials for historian, SCADA, and engineering workstation are in those files
4. `ssh engineer@10.10.2.30` with `spanner99` or use historian with `Historian2015`

For the private share: `smbclient //10.10.1.10/private -U Administrator%hex123`, get `plc-access.conf`.

FTP path: `ftp 10.10.1.10`, login anonymous, retrieve the same public files.

NTLMv1 relay: capture authentication with `responder` on the enterprise segment, relay to other services.

## Caveats

The win95shell does not implement every DOS command. It handles `DIR`, `CD`, `TYPE`, `COPY`, `DEL`, `CLS`, and `EXIT`. Attempting anything outside that list produces an appropriate error.

The machine exposes Telnet but the Linux login prompt appears, not a DOS prompt. Participants who try to telnet in and expect a Windows shell will encounter a brief reality check.

`C:\PRIVATE\PLCACCS.CFG` inside the virtual filesystem and `\\hex-legacy-1\private\plc-access.conf` on the Samba share contain identical information via different paths.

## Summary

1990s workstation still running Samba with NTLMv1, anonymous FTP, and Telnet. Password `hex123` everywhere. The public SMB share contains a complete network inventory and all system passwords. The machine is a goldmine that nobody thought to lock.
