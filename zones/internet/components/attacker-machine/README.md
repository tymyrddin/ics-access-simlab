# Attacker machine

`unseen-gate` is the participant entry point. It lives on `ics_internet` only (10.10.0.5). No enterprise or operational network access. Participants work outward from here.

## What is installed

- nmap, curl, wget, smbclient, hydra, tcpdump, socat, ftp, showmount, mount (nfs-common)
- Python venv at `/opt/attacker-env` with pymodbus 3.6.9, paramiko, impacket
- Five accounts: `ponder`, `hex`, `ridcully`, `librarian`, `dean`
- Mission briefing at `/run/adversary-readme.txt`

The container runs `privileged: true` so that the kernel NFS client can issue `mount(2)` syscalls. Without this, mounting NFS shares from inside the container is blocked even with `SYS_ADMIN`.

## Connecting

```bash
./ctl ssh ponder          # uses lab-key automatically
./ctl ssh hex             # same, different account
ssh ponder@localhost -p 2222
```

## Auth modes

Set `attacker_machine.auth_mode` in `ctf-config.yaml`.

`key` (default): public key only. Keys read from `adversary-keys` at runtime. `./ctl up` generates `lab-key` / `lab-key.pub` if the file does not exist. Pre-populate `adversary-keys` with participant keys before a Hetzner deployment.

`password`: credentials from `attacker_machine.accounts`. Used for Root-Me and platforms that publish connection strings. No key file needed.

## Port

`attacker_machine.ssh_host_port` in config. Default 2222 (avoids clash with host sshd). Set to 22 on Hetzner after running `setup.sh`, which moves the host sshd to port 2222.

## Adding tools

Edit the Dockerfile: `apt-get install` list and the pip install command in the venv setup. Rebuild:

```bash
docker compose -f zones/internet/docker-compose.yml build attacker-machine
```
