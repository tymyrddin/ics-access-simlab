# Engineering workstation

`uupl-eng-ws` belongs to Ponder Stibbons, the person responsible for programming
and maintaining every PLC and IED in the control zone. The access controls for
the control network are, in Ponder's words, "the credentials in the config files
and asking me first." The config files are on his workstation. The SSH key for
his machine is in Rincewind's home directory on the internet. The workstation is
dual-homed into the operational and control zones because that is how the job
works and nobody has proposed a better arrangement.

## Field reality

The engineering workstation is the highest-privilege machine in most OT
environments. It holds the programming tools, the device credentials, the
firmware update utilities, and, inevitably, a collection of backup files from
previous configurations that nobody got round to deleting. Dual-homing into both
operational and control networks is standard practice at sites where one engineer
covers the full stack. The attack value is not in any software vulnerability: it
is in the profile.

## Container details

Base image: `debian:bookworm-slim`. Login shell for `engineer` is
`win10ltsc_shell.sh`, a Windows 10 Enterprise LTSC facade over Bash.

SSH on port 22: password authentication and public key authentication.
pymodbus 3.6.8 installed in `/venv`.

User: `engineer`, password `spanner99`. Root login disabled.

Virtual Windows profile at `/opt/win10/C/Users/engineer/`. Key contents:

- `config\plc-access.conf`: IP, port, protocol, and credentials for every
  control zone device, including the PLC admin password `turbineadmin`, relay
  credentials `admin/relay1234`, and a note that Modbus has no authentication
- `Projects\PLC\turbine_controller.project`: full PLC project file with coil and
  register maps, alarm setpoints, and `admin_pass = turbineadmin`
- `Projects\RelayConfigs\relay_a_2019.txt` and `relay_b_2019.txt`: relay
  register maps with notes that thresholds are writable with no authentication
- `Projects\Firmware\README.txt`: firmware update procedure including PLC
  credentials in plaintext
- `Desktop\update_plc_firmware.ps1`: PowerShell script with `turbineadmin` in a
  variable alongside a note about manual upload steps
- `Tools\modbus_read.py` and `modbus_write.py`: working Modbus utilities
- `Tools\send_alarm.ps1`: SMTP alarm relay script containing `plantmail123`
- `Documents\engineering_notes.txt`: operational notes listing credentials for
  historian, SCADA, HMI, and relay IEDs
- `backups\PLC_Backup_2019.tar.gz`: pre-upgrade archive containing an older
  credential list and a complete network map with all OT zone IPs and passwords
- `.ssh\id_rsa`: RSA private key (copied to `/home/engineer/.ssh/` so SSH works)

PSReadLine history includes Modbus reads and writes to the turbine PLC, SSH to
the HMI, and curl queries to historian and SCADA.

A cron job polls the turbine PLC every five minutes and appends the governor
setpoint to `/home/engineer/plc_poll.log`.

The authorised key list includes a static Ed25519 public key corresponding to
the private key stored at `~/.ssh-keys/uupl_eng_key` on `wizzards-retreat`
(Rincewind's home machine at 10.10.0.10).

## Connections

- `ics_operational`: 10.10.2.30
- `ics_control`: 10.10.3.100 (the control zone NIC)
- Connects outbound to turbine PLC (10.10.3.21), relays (10.10.3.31/32), HMI
  (10.10.3.10), historian (10.10.2.10), SCADA (10.10.2.20)
- Reachable from `wizzards-retreat` (Ed25519 key) and from `distribution-scada`

## Protocols

SSH: port 22.
Modbus-TCP: outbound to control zone devices on port 502.

## Built-in vulnerabilities

Credential cache: `config\plc-access.conf` contains credentials for every
device in the control zone in plaintext. `Documents\engineering_notes.txt`
duplicates them in prose form. `Desktop\update_plc_firmware.ps1` contains
`turbineadmin` in a variable. `Tools\send_alarm.ps1` contains the SMTP
credentials.

Backup archive: `PLC_Backup_2019.tar.gz` contains a network map with IP
addresses and credentials for the entire OT estate as of 2019. The SCADA
password in the archive is stale, but the rest remain current.

Ed25519 authorised key: the public key on this machine corresponds to the
private key at `~/.ssh-keys/uupl_eng_key` on `wizzards-retreat`. Compromising
Rincewind's home machine gives direct SSH access to the engineering workstation
without a password.

Control zone NIC: the operational NIC at 10.10.3.100 provides direct access
to all control zone devices. Combined with the Modbus utilities in `Tools\`, an
attacker with a shell on this machine has everything needed to read or write any
register on any device in the control zone.

## Modifying vulnerabilities

To change the password: edit the `chpasswd` line in the Dockerfile.

To remove credentials from the profile: edit the heredoc blocks in
`entrypoint.sh` that write `plc-access.conf`, `engineering_notes.txt`, and
`update_plc_firmware.ps1`.

To remove the Ed25519 authorised key: delete the `cat >> authorized_keys`
block in `entrypoint.sh`.

To remove the backup archive: delete the `tar czf` block and the associated
heredoc content in `entrypoint.sh`.

To remove the control zone NIC: edit `ctf-config.yaml` under
`engineering_workstation` to remove the `control_ip` entry.

## Hardening suggestions

Store credentials in a secrets manager rather than config files. Restrict the
profile to the minimum information needed for the current task. Rotate the admin
password on every control zone device periodically. Remove or encrypt old backup
archives. Audit which machines hold the authorised key for this workstation.

## Observability and debugging

```bash
docker logs engineering-workstation
docker exec -it engineering-workstation bash
ssh engineer@10.10.2.30              # password: spanner99
ssh -i lab-key engineer@10.10.2.30  # from wizzards-retreat using the Ed25519 key
```

Inside, the virtual C: drive is at `/opt/win10/C/`. The Modbus utilities are at
`/opt/win10/C/Users/engineer/Tools/` and can be run with the venv Python:
`/venv/bin/python3 modbus_read.py 10.10.3.21 502 holding 0 4`

## Concrete attack paths

Via `wizzards-retreat` (the intended pivot path):

1. Compromise `wizzards-retreat` (any of its three paths).
2. `~/.ssh-keys/uupl_eng_key` is the Ed25519 private key.
3. `ssh -i ~/.ssh-keys/uupl_eng_key engineer@10.10.2.30`.
4. `cat config\plc-access.conf` lists every control zone device with credentials.
5. From the control zone NIC (10.10.3.100), reach the turbine PLC directly:
   `/venv/bin/python3 Tools/modbus_read.py 10.10.3.21 502 holding 0 4`
6. Write to the emergency stop coil: `... modbus_write.py 10.10.3.21 502 coil 0 1`

Alternative path (password brute force or credential reuse):

1. `ssh engineer@10.10.2.30` with `spanner99` (visible in the SCADA engineering
   notes after SCADA compromise).
2. Same profile access as above.

## Watch out for

The win10ltsc shell is a thin Bash wrapper. All real Linux commands and the
Python venv work normally.

The `backups\PLC_Backup_2019.tar.gz` archive is on the Linux filesystem, not
the virtual Windows profile. It can be extracted inside the container with
`tar xzf` or retrieved via `scp`. The SCADA password inside the archive
(`sysadmin123`) is stale; the current one is `W1nd0ws@2016`.

The cron job polling the PLC writes to `/home/engineer/plc_poll.log`. This file
is on the real Linux filesystem. It confirms the PLC is reachable and provides
a timestamp of the last successful poll.

`~/.ssh-keys/uupl_eng_key` on `wizzards-retreat` is the private key. The
matching public key is in `/home/engineer/.ssh/authorized_keys` on this
workstation and in the virtual profile at `C:\Users\engineer\.ssh\id_rsa.pub`.

## At a glance

Ponder's engineering workstation, dual-homed into operational and control
networks. Profile contains credentials for every device in the plant. The
authorised SSH key lives on Rincewind's home machine on the internet. Compromising
the admin@home machine gives passwordless access to the machine that can write to
any register on the turbine PLC.
