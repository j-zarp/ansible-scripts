# Ansible toolbox

Useful tools and scripts to facilitate server deployments and automation using Ansible.

## Structure
  * **server-side**<br>
  Scripts to run on the remote server(s) i.e. *managed nodes* in Ansible terminology.
  * **deployment**<br>
  Scripts to run on the *control node* in Ansible terminology to manage remote servers' deployments.

### References
  * [Ansible official website](https://www.redhat.com/en/ansible-collaborative)
  * [Latest official Ansible documentation](https://docs.ansible.com/projects/ansible/latest/index.html)


# Detailed Automated Documentation — Debian Server Migration Toolkit

Reverse-engineer a running Debian server into a reproducible Ansible playbook, then redeploy it on a fresh machine.

Built for the common scenario: you have a server that was configured by hand over months or years — packages, Docker services, firewall rules, cron jobs, VPN, SSH hardening — and you want to migrate it to a new OS version (e.g. Debian 12 → 13) without forgetting anything.

## What's in this repo

| File | What it does | Where to run it |
|---|---|---|
| `server-audit.sh` | Snapshots everything on the current server into a timestamped directory | **Old server** (as root) |
| `generate-ansible.sh` | Reads the audit output and scaffolds an Ansible project with 8 pre-populated roles | **Your workstation** |
| `review-playbook.sh` | Produces a single readable summary of the entire generated playbook | **Your workstation** |

## Prerequisites

On your workstation:

```bash
pip install --upgrade ansible
ansible-galaxy collection install ansible.posix community.general community.docker
```

On the old server: root access (or sudo). On the new server: a user with sudo privileges and SSH key access from your workstation.

## Workflow

### Phase 1 — Audit the old server

```bash
# Copy the audit script to your old server
scp server-audit.sh root@oldserver:/root/

# Run it
ssh root@oldserver "bash /root/server-audit.sh"

# Transfer the result to your workstation
scp root@oldserver:/root/server-audit_*.tar.gz .
tar xzf server-audit_*.tar.gz
```

The script collects 12 categories of system state: installed packages, users and SSH keys, network config, firewall rules (iptables/nftables/ufw), systemd services and timers, cron jobs, Docker containers and compose files, OpenVPN configuration, security hardening (fail2ban, sysctl, AppArmor), and custom scripts. Everything is saved into a structured directory with a summary report.

### Phase 2 — Generate the Ansible project

```bash
bash generate-ansible.sh ./server-audit_myhost_20260509_113014/
```

This creates an `ansible-rebuild/` directory containing a complete Ansible project with 8 roles, pre-populated from your audit data.

### Phase 3 — Review before deploying

```bash
cd ansible-rebuild
bash ../review-playbook.sh | less -R
```

This prints a consolidated view of every task, variable, package, firewall rule, Docker project, cron job, and safety flag — all in one scrollable document. Much easier than navigating 40+ role files.

**Things to check during review:**

- `inventory/hosts.ini` — set the new server's IP address and username
- `roles/base-packages/defaults/main.yml` — the package list; remove packages you don't need and check for Debian version renames
- `roles/docker/defaults/main.yml` — verify compose project paths are correct
- `roles/firewall/defaults/main.yml` — verify UFW rules look right
- `roles/vpn/defaults/main.yml` — choose `openvpn` or `wireguard`
- `group_vars/rebuild.yml` — the two dangerous flags (`deploy_old_sudoers`, `deploy_old_sshd_config`) default to `false`

### Phase 4 — Transfer Docker data

The playbook copies compose files but not your application data (databases, configs, media, volumes). Transfer those separately before starting services:

```bash
# On the old server, stop services cleanly first
ssh root@oldserver "cd /root/docker && for d in */; do (cd \"\$d\" && docker compose stop); done"

# Rsync the entire tree to the new server
rsync -avHAX --numeric-ids \
  root@oldserver:/root/docker/ \
  root@newserver:/root/docker/
```

### Phase 5 — Deploy

```bash
cd ansible-rebuild

# Install required Ansible collections
ansible-galaxy collection install -r requirements.yml

# Dry run (simulates everything, changes nothing)
ansible-playbook -i inventory/hosts.ini site.yml --check --diff -K

# Deploy for real
ansible-playbook -i inventory/hosts.ini site.yml -K

# Deploy only specific roles
ansible-playbook -i inventory/hosts.ini site.yml --tags docker -K

# Start Docker services (disabled by default — only copies compose files)
ansible-playbook -i inventory/hosts.ini site.yml --tags docker -K \
  -e docker_start_services=true
```

## Generated project structure

```
ansible-rebuild/
├── ansible.cfg                  # Ansible configuration
├── requirements.yml             # Required collections (posix, general, docker)
├── inventory/hosts.ini          # Target server(s)
├── group_vars/rebuild.yml       # Global variables and safety flags
├── site.yml                     # Main playbook
└── roles/
    ├── users/                   # Users, SSH keys, sudoers (runs FIRST)
    ├── base-packages/           # APT packages, timezone, hostname
    ├── networking/              # Network interfaces, DNS, /etc/hosts
    ├── docker/                  # Docker CE install, compose file deployment
    ├── vpn/                     # OpenVPN or WireGuard
    ├── cron/                    # Cron jobs and scripts
    ├── firewall/                # UFW / iptables / nftables
    └── security/                # fail2ban, sysctl hardening, sshd_config
```

Each role follows standard Ansible layout: `tasks/`, `defaults/`, `handlers/`, `templates/`, `files/`.

## Safety features

This toolkit is designed to never lock you out of a remote server.

**Lockout protection (runs first, every time):**
- The `bootstrap_user` (defaults to your `ansible_user`) is guaranteed sudo access via a dedicated `/etc/sudoers.d/00-ansible-bootstrap` file
- The bootstrap user is never modified by the users role — their groups, SSH keys, and sudo access are left untouched
- User creation uses `append: yes` on groups to never strip existing memberships
- SSH authorized_keys deployment uses `exclusive: no` to never wipe existing keys

**Dangerous operations require explicit opt-in:**
- `deploy_old_sudoers: false` (default) — the old server's `/etc/sudoers.d/` files are NOT deployed. Cloud-init's `90-cloud-init-users` is never overwritten even when opted in.
- `deploy_old_sshd_config: false` (default) — the old server's `sshd_config` is NOT deployed. When opted in, a backup is created automatically.
- `deploy_static_ip: false` (default) — static IP config is NOT written. When opted in, the config is written to disk but networking is NOT restarted automatically. You activate it manually from the VPS console or by rebooting.
- `docker_start_services: false` (default) — compose files are copied but containers are not started until you explicitly enable it.

**Safe by default:**
- `deploy_dotfiles: true` (default) — `.bashrc`, `.vimrc`, etc. from the old server are deployed. This is safe because it only touches user dotfiles, not system configuration.

**Pre-flight checks:**
- The playbook verifies the target is Debian before making any changes
- It confirms the bootstrap user exists
- It warns visibly if dangerous flags are enabled

**Check-mode safe:**
- All tasks that need installed binaries (ufw, docker, wg, fail2ban) are wrapped in `when: not ansible_check_mode` so `--check --diff` runs cleanly on a fresh server

## Adding Docker services manually

Two files to edit per service:

**1. Add the path** to `roles/docker/defaults/main.yml`:

```yaml
docker_compose_dirs:
  - /root/docker/traefik
  - /root/docker/jellyfin     # ← add this
```

**2. Drop the compose file** into `roles/docker/files/` with the right name:

```bash
# The naming convention: path with / replaced by _, plus .yml
# /root/docker/jellyfin → _root_docker_jellyfin.yml

cp my-jellyfin-compose.yml roles/docker/files/_root_docker_jellyfin.yml
```

Quick reference:

| Path | Filename |
|---|---|
| `/root/docker/jellyfin` | `_root_docker_jellyfin.yml` |
| `/root/docker/pihole` | `_root_docker_pihole.yml` |
| `/opt/services/grafana` | `_opt_services_grafana.yml` |

## OpenVPN → WireGuard migration

Set `vpn_backend: "wireguard"` in `group_vars/rebuild.yml`. The VPN role will:

- Install WireGuard and generate server keys
- Create key pairs for each client found in the old OpenVPN PKI
- Deploy a `wg0.conf` with NAT/forwarding rules

Your old OpenVPN configs are preserved in `roles/vpn/files/openvpn-old/` for reference. See `roles/vpn/files/wireguard-migration-notes.txt` for the directive-by-directive mapping.

All clients will need new WireGuard config files — there's no certificate reuse between OpenVPN and WireGuard.

## Static IP configuration

The generator auto-extracts the old server's IP, gateway, interface, and DNS servers from the audit and populates `group_vars/rebuild.yml`. Review and adjust the values for the new server, then opt in:

```yaml
# In group_vars/rebuild.yml:
deploy_static_ip: true
static_interface: "ens3"
static_ip: "203.0.113.42/24"
static_gateway: "203.0.113.1"
static_dns:
  - "1.1.1.1"
  - "9.9.9.9"
```

The playbook writes `/etc/network/interfaces` but deliberately does NOT restart networking (a wrong IP = instant SSH lockout). Activate it manually:

```bash
# From the VPS provider's web console:
systemctl restart networking
ip addr show ens3   # verify

# Or simply reboot:
reboot
```

## Dotfiles

The audit script collects `.bashrc`, `.vimrc`, `.bash_aliases`, `.profile`, `.tmux.conf`, `.gitconfig`, `.inputrc`, and `.nanorc` for every user (including root). The generator places them in `roles/users/files/dotfiles/<username>/` and the playbook deploys them.

Enabled by default (`deploy_dotfiles: true`) since dotfiles don't affect system security. Disable with:

```yaml
deploy_dotfiles: false
```

After generation, the dotfiles directory looks like:

```
roles/users/files/dotfiles/
├── root/
│   ├── .bashrc
│   └── .vimrc
└── nuc/
    ├── .bashrc
    ├── .vimrc
    └── .bash_aliases
```

You can edit these files before deployment to customize your new server's shell environment.

## Debian 12 → 13 gotchas

Things to watch for when reviewing the generated playbook:

- **Package renames** — some packages may have been renamed, split, or merged. The playbook fails clearly if a package name doesn't exist; fix the name in `roles/base-packages/defaults/main.yml` and re-run.
- **Python version** — Debian 13 ships Python 3.13+. Check any custom scripts or venvs.
- **nftables** — Debian 13 defaults to nftables. If you were using raw iptables, consider switching. The firewall role supports both.
- **systemd unit changes** — some deprecated unit options may cause warnings. Check `systemctl status` after deployment.

## Troubleshooting

**"Missing sudo password"** — pass `-K` to the playbook command. Ansible will prompt once for the sudo password.

**"executable not found" in --check mode** — expected. In check mode, package installs are simulated, so binaries don't actually exist on disk. The playbook handles this by skipping post-install tasks when in check mode. Run without `--check` for real deployment.

**compose files not being copied** — check that `docker_compose_dirs` in `group_vars/rebuild.yml` isn't set to `[]` (which overrides the role defaults). Comment it out or delete the line.

**User locked out after deploy** — use your VPS provider's web console to regain access. Restore sudo with: `usermod -aG sudo <username>`. See the safety features section above for how the playbook prevents this.

## License

MIT
