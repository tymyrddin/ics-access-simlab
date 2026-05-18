# Legacy workstation

`hex-legacy-1` has been running since the late 1990s. The hardware was replaced in 2003; the software was migrated intact because nothing was broken. Nothing has changed since because it still works. It runs Samba with NTLMv1 and LAN Manager hashes, FTP with anonymous read access, Telnet, and SSH added later by someone who needed remote access and left PermitRootLogin enabled. The attack surface is not a misconfiguration: it is the correct operation of 1990s software in 2024.

## The real-world parallel

A legacy workstation running era-appropriate software that was never decommissioned because it hosts files the rest of the network still depends on. Common in OT environments where uptime requirements prohibit upgrades and the vendor stopped supporting the OS before the site even considered replacing it. The security model assumed that anyone on the network was authorised to be there.

## Container details

Base image: `debian:bookworm-slim` presenting a Windows 95-era facade via a custom login shell (`win95shell.sh`). The real filesystem is under `/opt/legacy/C/`. SSH drops users into a DOS-style shell with 8.3 filenames.

Services: Samba (ports 139, 445), vsftpd (port 21), Telnet via xinetd (port
23, served by `inetutils-telnetd`), OpenSSH (port 22), tftp client available.

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

Key loot in `\\hex-legacy-1\public` (also available over anonymous FTP and
visible in the virtual C: drive at `C:\UUPL\` and `C:\LOGBOOK\`):
- `UUPL/NETWORK.TXT`: full network inventory including uupl-historian, SCADA,
  engineering workstation IPs.
- `LOGBOOK/ENGINEER.LOG`: every system password in plaintext, described as
  "Ponder Stibbons' informal notes". Includes hist_read/history2017 (the
  uupl-historian ingest credential) and the SCADA SSH password.
- `procedures.txt`, `network_inventory.txt`, `logs_sample.csv` (legacy
  copies kept under different names; same flavour of information).

The `private` share is restricted to `Administrator` but contains the same
credential list in `plc-access.conf`.

## Modifying vulnerabilities

To disable LM/NTLMv1: set `lanman auth = no` and `ntlm auth = ntlmv2-only` in the smb.conf block in `entrypoint.sh`.

To remove anonymous FTP: set `anonymous_enable=NO` in the vsftpd config block.

To remove Telnet: delete the xinetd config block and remove `telnetd` from the apt install list.

To change the password: update the `chpasswd` line and the `smbpasswd` invocation in `entrypoint.sh`.

Static scenario content lives in `data/shares/` and is copied into the image by the Dockerfile. Anything in `entrypoint.sh` is there because it is runtime-coupled (Samba and service configuration) or credential-coupled (the C: drive files: the short logbook, PLCACCS.CFG, and the rest). Edit `data/shares/` for public share content. Edit the heredocs in `entrypoint.sh` for C: drive content.

## Hardening suggestions

Disable LM/NTLMv1; require NTLMv2. Remove anonymous FTP and guest Samba access. Remove Telnet entirely. Set `PermitRootLogin no` in sshd_config. Move sensitive documents off a world-readable share.

## Observability and debugging

```bash
docker logs hex-legacy-1
docker exec -it hex-legacy-1 bash
smbclient //10.10.1.10/public -N           # anonymous access; list and get files
ftp 10.10.1.10                             # user: anonymous
ssh root@10.10.1.10                        # password: hex123
telnet 10.10.1.10
```

The virtual C: drive is at `/opt/legacy/C/` inside the container. The win95shell simulates DOS navigation; see the commands section below.

## Concrete attack paths

From `wizzards-retreat` (10.10.1.3) or `bursar-desk` (10.10.1.20):

1. `smbclient //10.10.1.10/public -N`
2. `get C:\UUPL\NETWORK.TXT` and `get C:\LOGBOOK\ENGINEER.LOG`
3. Credentials for uupl-historian, SCADA, and engineering workstation are in those files
4. `ssh engineer@10.10.2.30` with `spanner99` or use uupl-historian with `Historian2015`

For the private share: `smbclient //10.10.1.10/private -U Administrator%hex123`, get `plc-access.conf`.

FTP path: `ftp 10.10.1.10`, login anonymous, retrieve the same public files.

NTLMv1 relay: capture authentication with `responder` on the enterprise segment, relay to other services.

## Shell commands

The win95shell dispatches the following DOS/Win95 commands:

Navigation and files: `DIR` (with `/S` for recursive, wildcards such as `*.cfg` and `*scada*`), `CD`, `TYPE`, `ATTRIB`. `COPY` and `DEL` return access denied.

Output redirection: `DIR C:\ /S > list.txt` and `>>` both work; the file lands in the virtual C: drive.

Network enumeration: `NET VIEW`, `NET VIEW \\SERVER`, `NET USE` (drive mapping and listing), `PING`, `NETSTAT`, `ROUTE PRINT`, `ARP -A`, `WINIPCFG`, `IPCONFIG`, `NBTSTAT -A ip`.

Drive mapping: `NET USE Z: \\HEX-LEGACY-1\public` maps Z: to the public share. Switching drives with `Z:` (bare) works. `NET USE Z: /D` disconnects.

Text search: `FIND /I "string" *.ext` searches inside files, grouped by filename header. Accepts wildcards in the file argument.

Connectivity: `FTP`, `TFTP`, `TELNET`, `SSH`, `NC`, `NMAP`, `CURL`.

Commands not recognised produce `Bad command or file name`.

The machine exposes Telnet but the Linux login prompt appears, not a DOS prompt. Participants who telnet in and expect a Windows shell will encounter a brief reality check.

`C:\PRIVATE\PLCACCS.CFG` inside the virtual filesystem and `\\hex-legacy-1\private\plc-access.conf` on the Samba share contain identical information via different paths.

## Summary

1990s workstation still running Samba with NTLMv1, anonymous FTP, and Telnet. Password `hex123` everywhere. The public SMB share contains a complete network inventory and all system passwords. The DOS facade supports recursive file hunting, credential scraping with `FIND`, drive mapping, and period-correct network recon. The machine is a goldmine that nobody thought to lock.
