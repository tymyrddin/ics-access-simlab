# SFTP file drop

`dispatch-box` is an SFTP server used as a file drop for contractors and
data exchange with external parties. The account is `anonymous` with password
`anonymous`. The upload directory is `/home/anonymous/upload` with world-write
permissions. There is no chroot jail, which means directory traversal via `../`
is possible from an SFTP client.

## File drops in real OT

File drop servers at the IT/OT boundary are common: contractors submit firmware
update packages, vendors deliver configuration exports, and field teams upload
commissioning data. Anonymous or shared-account access is frequent in
environments where setting up individual accounts is considered overhead. Without
a chroot jail, an SFTP client has the ability to traverse outside the intended
directory and potentially read or overwrite files elsewhere on the filesystem.

## Container details

Base image: `atmoz/sftp:debian`.

SSH / SFTP on port 22.

Configured user: `anonymous` / `anonymous`, UID 1001, GID 1001. Upload directory
`/home/anonymous/upload`.

The `atmoz/sftp` image creates the user from `users.conf` at startup and sets
up the upload directory with write permissions.

No chroot jail is configured. The `anonymous` user can browse the container
filesystem with an SFTP client.

rsyslog is running inside the container and forwards syslog events (including
sshd auth successes, failures, and SFTP session open/close) to `scribes-post`
(10.10.5.32:514) over UDP. No TLS.

## Connections

- `ics_dmz`: 10.10.5.21
- Reachable from `ics_internet` and from within `ics_dmz`

## Protocols

SFTP (SSH subsystem): port 22.

## Built-in vulnerabilities

Anonymous credential: `anonymous` / `anonymous`. No per-user credential management.

No chroot jail: SFTP clients can traverse outside `/home/anonymous/upload` using
`..` paths. The extent of accessible filesystem depends on file permissions
within the container.

World-writable upload directory: any authenticated session can write files to
`/home/anonymous/upload` with no review or validation.

File read: if the container has readable files outside the upload directory (logs,
configuration, or other artefacts), directory traversal may expose them.

## Modifying vulnerabilities

To add a chroot jail: the `atmoz/sftp` image supports chroot configuration via
the `users.conf` format or environment variables. Consult the upstream image
documentation for the chroot option syntax.

To change the credential: edit `users.conf` to replace `anonymous:anonymous`
with the desired username and password.

To restrict uploads to specific file types: add a ForceCommand with an sftp
wrapper that validates filenames. This requires a custom entrypoint.

## Hardening suggestions

Enable chroot so the anonymous user cannot traverse outside their upload
directory. Replace anonymous shared credentials with per-user credentials.
Review uploaded files before they are processed by any downstream system.
Consider whether an anonymous upload drop is appropriate in a DMZ at all.

## Observability and debugging

```bash
docker logs sftp-drop
sftp anonymous@10.10.5.21          # password: anonymous
```

From an SFTP session:
```
sftp> pwd
sftp> ls ../                       # traverse upward if no chroot
sftp> get ../etc/passwd            # read system files if permissions allow
```

## Concrete attack paths

From the internet zone:

1. `sftp anonymous@10.10.5.21` with password `anonymous`.
2. `ls ../` to confirm directory traversal is possible.
3. Traverse to readable paths and exfiltrate any files with useful content.
4. Upload a file to `/home/anonymous/upload/`. If the downstream system processes
   uploaded files automatically (e.g. firmware update handler), this is a
   delivery vector for malicious content.

## Worth knowing

The `atmoz/sftp` image creates the user and directory at container start based
on `users.conf`. If the container is rebuilt, the upload directory is empty.

SFTP is an SSH subsystem. The connection uses SSH negotiation on port 22 before
dropping into the SFTP subsystem. Standard SSH clients (`ssh -s sftp`) and
dedicated SFTP clients both work.

The absence of a chroot jail is the configured vulnerability, not a Docker
escape: traversal is within the container filesystem. There is no path out of
the container.

## In brief

SFTP file drop, `anonymous` / `anonymous`. No chroot jail: clients can traverse
outside the upload directory. World-writable upload path. Useful for exfiltrating
container files and as a delivery vector if upstream systems process uploads
automatically.
