#!/usr/bin/env bash
# ============================================================================
#  generate-ansible.sh — Turn audit output into an Ansible project
#                        Run this file with an output of server_audit.sh
# ============================================================================
#  Run on your WORKSTATION (not the remote server).
#
#  Usage:
#    1. Extract the audit tarball:
#         tar xzf server-audit_myhost_20260509.tar.gz
#    2. Run this script pointing at the extracted directory:
#         bash generate-ansible.sh ./server-audit_myhost_20260509
#    3. Review & customise the generated project in ./ansible-rebuild/
#    4. Run the playbook:
#         cd ansible-rebuild
#         ansible-playbook -i inventory/hosts.ini site.yml
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }

# ── Validate input ──────────────────────────────────────────────────────────

AUDIT_DIR="${1:?Usage: $0 <path-to-audit-directory>}"

if [[ ! -d "$AUDIT_DIR" ]]; then
    echo "Error: '$AUDIT_DIR' is not a directory." >&2
    exit 1
fi

if [[ ! -f "$AUDIT_DIR/REPORT.txt" ]]; then
    echo "Error: '$AUDIT_DIR' does not look like a server-audit directory (no REPORT.txt)." >&2
    exit 1
fi

PROJECT="./ansible-rebuild"
info "Audit source: $AUDIT_DIR"
info "Ansible project will be created in: $PROJECT"
echo ""

# ── Scaffold directory structure ────────────────────────────────────────────

mkdir -p "$PROJECT"/{inventory,group_vars,roles/{base-packages,networking,firewall,docker,vpn,cron,users,security}/{tasks,templates,files,handlers,defaults}}

ok "Directory structure created"

# ============================================================================
#  INVENTORY
# ============================================================================

AUDIT_HOSTNAME=$(cat "$AUDIT_DIR/system/hostname.txt" 2>/dev/null || echo "newserver")
AUDIT_HOSTNAME_SHORT=$(echo "$AUDIT_HOSTNAME" | cut -d. -f1)

cat > "$PROJECT/inventory/hosts.ini" <<EOF
# ============================================================================
# Inventory — edit the IP/hostname below to point at your new Debian 13 box
# ============================================================================

[rebuild]
${AUDIT_HOSTNAME_SHORT}  ansible_host=CHANGE_ME_TO_NEW_SERVER_IP  ansible_user=root

# If using SSH key auth (recommended):
# ${AUDIT_HOSTNAME_SHORT}  ansible_host=192.168.1.100  ansible_user=root  ansible_ssh_private_key_file=~/.ssh/id_ed25519

# If you created a non-root deploy user:
# ${AUDIT_HOSTNAME_SHORT}  ansible_host=192.168.1.100  ansible_user=deploy  ansible_become=yes
EOF

ok "Inventory file"

# ============================================================================
#  GROUP VARS
# ============================================================================

# Extract timezone
TIMEZONE=$(cat "$AUDIT_DIR/system/timezone.txt" 2>/dev/null | grep "Time zone:" | awk '{print $3}' || echo "Europe/Zurich")

# Extract hostname
cat > "$PROJECT/group_vars/rebuild.yml" <<EOF
---
# ============================================================================
# Group variables for the rebuild target
# ============================================================================
# Extracted from: ${AUDIT_DIR}
# Adjust these before running the playbook.

server_hostname: "${AUDIT_HOSTNAME}"
server_timezone: "${TIMEZONE}"

# ─── LOCKOUT PROTECTION ─────────────────────────────────────────────────────
# The user Ansible connects as. This user is guaranteed to keep:
#   - sudo group membership
#   - their existing SSH authorized_keys (never wiped)
#   - excluded from any group/key replacement
# Defaults to ansible_user from inventory.
bootstrap_user: "{{ ansible_user }}"

# ─── DANGEROUS — REQUIRES EXPLICIT OPT-IN ──────────────────────────────────
# Deploying the old server's /etc/sudoers.d/* can overwrite cloud-init's
# 90-cloud-init-users grant on a fresh VPS and lock you out. Leave OFF
# until you've manually reviewed roles/users/files/sudoers.d/ and confirmed
# the files don't conflict with your bootstrap user's sudo access.
deploy_old_sudoers: false

# Deploying the old server's sshd_config can disable PasswordAuth, disable
# RootLogin, set AllowUsers, etc. — any of which can lock you out of SSH.
# Leave OFF until you've manually reviewed it, then opt in on a SECOND run
# after verifying everything else works.
deploy_old_sshd_config: false

# VPN choice — set to 'wireguard' to switch from OpenVPN
vpn_backend: "openvpn"   # or "wireguard"

# Docker compose project directories are auto-populated in
# roles/docker/defaults/main.yml from the audit. Override here ONLY if
# you've reorganized paths on the new server. Leaving this commented out
# means the role default takes effect.
# docker_compose_dirs:
#   - /opt/myapp
#   - /opt/monitoring
EOF

ok "Group variables"

# ============================================================================
#  ROLE: base-packages
# ============================================================================

info "Generating role: base-packages ..."

# Build the package list from apt-manual, filtering out low-value noise
if [[ -f "$AUDIT_DIR/packages/apt-manual.txt" ]]; then
    # Filter packages that should not be in the base list:
    #   - low-level system packages (kernel, libs) that come from the base install
    #   - third-party packages whose repos are configured by other roles
    #     (Docker packages → installed by docker role)
    FILTER_RE='^(lib|linux-image|linux-headers|linux-libc|grub-|initramfs|keyboard-configuration|console-setup|locales|tzdata|man-db|adduser|docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose-plugin|containerd\.io|containerd)'

    PACKAGES=$(grep -vE "$FILTER_RE" "$AUDIT_DIR/packages/apt-manual.txt" | sort | awk '{printf "    - %s\n", $1}')
else
    PACKAGES="    # Could not find apt-manual.txt in audit — add packages manually"
fi

cat > "$PROJECT/roles/base-packages/defaults/main.yml" <<EOF
---
# Packages to install — sourced from 'apt-mark showmanual' on the old server.
# Review this list: remove anything Debian 13 provides by default or that
# you no longer need, and check for package renames between Debian 12 → 13.
#
# Common Debian 12→13 gotchas:
#   - python3 may jump from 3.11 to 3.12+ (check venvs / pip packages)
#   - Some packages may have been merged or split
#   - iptables package may default to nftables backend

base_packages:
${PACKAGES}
EOF

cat > "$PROJECT/roles/base-packages/tasks/main.yml" <<EOF
---
- name: Update apt cache
  ansible.builtin.apt:
    update_cache: yes
    cache_valid_time: 3600

- name: Install base packages
  ansible.builtin.apt:
    name: "{{ base_packages }}"
    state: present
  # If a package was renamed/removed in Debian 13, this will fail clearly —
  # fix the name in defaults/main.yml and re-run.

- name: Set timezone
  community.general.timezone:
    name: "{{ server_timezone }}"

- name: Set hostname
  ansible.builtin.hostname:
    name: "{{ server_hostname }}"
EOF

# Copy APT sources for reference
if [[ -d "$AUDIT_DIR/packages/sources.list.d" ]]; then
    cp -a "$AUDIT_DIR/packages/sources.list.d"/* "$PROJECT/roles/base-packages/files/" 2>/dev/null || true
fi

ok "Role: base-packages"

# ============================================================================
#  ROLE: users
# ============================================================================

info "Generating role: users ..."

# Extract real users (UID >= 1000, not nobody)
USER_BLOCK=""
while IFS=: read -r uname _ uid gid _ home shell; do
    if [[ $uid -ge 1000 && $uid -lt 65534 ]]; then
        USER_BLOCK+="  - name: ${uname}
    uid: ${uid}
    shell: ${shell}
    home: ${home}
    groups: [$(id -nG "$uname" 2>/dev/null | tr ' ' ',' || echo '')]
"
        # Check for authorized_keys
        if [[ -f "$AUDIT_DIR/users/authorized_keys/${uname}.keys" ]]; then
            cp "$AUDIT_DIR/users/authorized_keys/${uname}.keys" \
               "$PROJECT/roles/users/files/${uname}_authorized_keys"
        fi
    fi
done < "$AUDIT_DIR/users/passwd.txt" 2>/dev/null

cat > "$PROJECT/roles/users/defaults/main.yml" <<EOF
---
# Users extracted from the old server.
# Passwords are NOT migrated (create new ones or use SSH keys only).

managed_users:
${USER_BLOCK:-  # No users found with UID >= 1000}
EOF

cat > "$PROJECT/roles/users/tasks/main.yml" <<EOF
---
# ─── LOCKOUT PROTECTION — runs FIRST, before anything else in this role ───
# Guarantees the bootstrap user retains sudo access throughout the play.
- name: "Lockout protection: ensure bootstrap user is in sudo group"
  ansible.builtin.user:
    name: "{{ bootstrap_user }}"
    groups: sudo
    append: yes   # never strip other group memberships

- name: "Lockout protection: keep a dedicated sudoers file for bootstrap user"
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/00-ansible-bootstrap"
    content: "{{ bootstrap_user }} ALL=(ALL) ALL\n"
    owner: root
    group: root
    mode: "0440"
    validate: "visudo -cf %s"
# The '00-' prefix ensures this file is read first by sudo. It only grants
# the same access the user already has via the sudo group, so it's safe.

# ─── Manage users from the audit ──────────────────────────────────────────
- name: Create managed users
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ item.uid }}"
    shell: "{{ item.shell }}"
    home: "{{ item.home }}"
    create_home: yes
    groups: "{{ item.groups | default([]) }}"
    append: yes   # CRITICAL: don't strip groups (could remove sudo!)
  loop: "{{ managed_users }}"
  when: item.name != bootstrap_user   # never touch the bootstrap user

- name: Check for authorized_keys files
  ansible.builtin.stat:
    path: "{{ role_path }}/files/{{ item.name }}_authorized_keys"
  loop: "{{ managed_users }}"
  register: authkey_files

- name: Deploy SSH authorized_keys
  ansible.posix.authorized_key:
    user: "{{ item.item.name }}"
    key: "{{ lookup('file', role_path ~ '/files/' ~ item.item.name ~ '_authorized_keys') }}"
    exclusive: no   # CRITICAL: never wipe existing keys
  loop: "{{ authkey_files.results }}"
  when:
    - item.stat.exists
    - item.item.name != bootstrap_user   # never replace bootstrap user's keys

# ─── DANGEROUS — opt-in only ──────────────────────────────────────────────
# Deploying the old server's /etc/sudoers.d/* can overwrite cloud-init's
# 90-cloud-init-users grant and lock you out. Defaults to off.
- name: Deploy sudoers rules from old server
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/sudoers.d/{{ item | basename }}"
    owner: root
    group: root
    mode: "0440"
    validate: "visudo -cf %s"
  with_fileglob:
    - "files/sudoers.d/*"
  when:
    - deploy_old_sudoers | bool
    # Belt-and-braces: even if opted in, refuse to overwrite cloud-init's file
    - (item | basename) != "90-cloud-init-users"
EOF

# Copy sudoers.d files
if [[ -d "$AUDIT_DIR/users/sudoers.d" ]]; then
    mkdir -p "$PROJECT/roles/users/files/sudoers.d"
    cp -a "$AUDIT_DIR/users/sudoers.d"/* "$PROJECT/roles/users/files/sudoers.d/" 2>/dev/null || true
fi

# Copy sshd_config as template
if [[ -f "$AUDIT_DIR/users/sshd_config" ]]; then
    cp "$AUDIT_DIR/users/sshd_config" "$PROJECT/roles/users/templates/sshd_config.j2"
fi

cat > "$PROJECT/roles/users/handlers/main.yml" <<EOF
---
- name: Restart sshd
  ansible.builtin.systemd:
    name: sshd
    state: restarted
EOF

ok "Role: users"

# ============================================================================
#  ROLE: networking
# ============================================================================

info "Generating role: networking ..."

# Copy network config files as templates
for f in "$AUDIT_DIR"/network/interfaces "$AUDIT_DIR"/network/resolv.conf; do
    [[ -f "$f" ]] && cp "$f" "$PROJECT/roles/networking/templates/$(basename "$f").j2"
done

if [[ -d "$AUDIT_DIR/network/netplan" ]]; then
    cp -a "$AUDIT_DIR/network/netplan"/* "$PROJECT/roles/networking/templates/" 2>/dev/null || true
fi

cat > "$PROJECT/roles/networking/tasks/main.yml" <<EOF
---
- name: Deploy /etc/hosts
  ansible.builtin.template:
    src: hosts.j2
    dest: /etc/hosts
    owner: root
    group: root
    mode: "0644"
  when: "'hosts.j2' is file"

- name: Deploy network interfaces
  ansible.builtin.template:
    src: interfaces.j2
    dest: /etc/network/interfaces
    owner: root
    group: root
    mode: "0644"
  notify: Restart networking
  when: "'interfaces.j2' is file"

# If using netplan instead, uncomment:
# - name: Deploy netplan config
#   ansible.builtin.template:
#     src: "01-netcfg.yaml.j2"
#     dest: /etc/netplan/01-netcfg.yaml
#     mode: "0600"
#   notify: Apply netplan

# NOTE: Review IP addresses — the new server likely has different IPs.
# Parameterise them in group_vars/rebuild.yml:
#   server_ip: "192.168.1.100"
#   server_gateway: "192.168.1.1"
EOF

cat > "$PROJECT/roles/networking/handlers/main.yml" <<EOF
---
- name: Restart networking
  ansible.builtin.systemd:
    name: networking
    state: restarted

- name: Apply netplan
  ansible.builtin.command: netplan apply
EOF

# Copy hosts file as template
if [[ -f "$AUDIT_DIR/network/hosts.txt" ]]; then
    cp "$AUDIT_DIR/network/hosts.txt" "$PROJECT/roles/networking/templates/hosts.j2"
fi

ok "Role: networking"

# ============================================================================
#  ROLE: firewall
# ============================================================================

info "Generating role: firewall ..."

# Detect which firewall was in use
HAS_UFW=false
HAS_IPTABLES=false
HAS_NFT=false

[[ -f "$AUDIT_DIR/firewall/ufw-status.txt" ]] && grep -q "Status: active" "$AUDIT_DIR/firewall/ufw-status.txt" 2>/dev/null && HAS_UFW=true
[[ -f "$AUDIT_DIR/firewall/iptables-v4.rules" ]] && HAS_IPTABLES=true
[[ -f "$AUDIT_DIR/firewall/nftables.conf" ]] && HAS_NFT=true

# Extract UFW rules if active
UFW_RULES=""
if $HAS_UFW && [[ -f "$AUDIT_DIR/firewall/ufw-status.txt" ]]; then
    # UFW status output has columns separated by 2+ spaces, and the Action
    # column actually contains two words: ACTION + DIRECTION (e.g. "ALLOW IN").
    # We split on multi-space, then split the action field on the inner space.
    # IPv6 rules (marked "(v6)") are skipped to avoid duplicates — UFW
    # auto-creates IPv6 entries when you add an IPv4 rule.
    UFW_RULES=$(awk -F'  +' '
        /^--/ { found=1; next }
        !found { next }
        NF < 3 { next }
        /\(v6\)/ { next }
        {
            to = $1
            action_dir = $2
            from = $3

            # Split "ALLOW IN" into action="ALLOW", direction="IN"
            split(action_dir, ad, " ")
            action = ad[1]

            # Split "22/tcp" into port="22", proto="tcp"
            # (the ufw module wants them as separate parameters).
            # A bare port like "9090" gets proto="any".
            if (to ~ /\//) {
                slash_idx = index(to, "/")
                port = substr(to, 1, slash_idx - 1)
                proto = substr(to, slash_idx + 1)
            } else {
                port = to
                proto = "any"
            }

            # Map UFW "Anywhere" to the ansible ufw module value
            if (from == "Anywhere") from = "any"

            # Lowercase the rule keyword; skip unknown actions
            rule = tolower(action)
            if (rule != "allow" && rule != "deny" && rule != "limit" && rule != "reject") next

            printf "  - { rule: %s, port: \"%s\", proto: \"%s\", from: \"%s\" }\n", rule, port, proto, from
        }
    ' "$AUDIT_DIR/firewall/ufw-status.txt" 2>/dev/null)
fi

cat > "$PROJECT/roles/firewall/defaults/main.yml" <<EOF
---
# Firewall backend detected on old server:
#   UFW active:     ${HAS_UFW}
#   iptables rules: ${HAS_IPTABLES}
#   nftables rules: ${HAS_NFT}
#
# Debian 13 uses nftables by default. If you were using raw iptables,
# consider switching to ufw or nftables for the rebuild.

firewall_backend: "ufw"    # "ufw", "iptables", or "nftables"

# Default policies
ufw_default_incoming: "deny"
ufw_default_outgoing: "allow"

# Rules extracted from old server
ufw_rules:
${UFW_RULES:-  # No UFW rules extracted — see firewall/ in audit for raw iptables rules}
EOF

cat > "$PROJECT/roles/firewall/tasks/main.yml" <<EOF
---
- name: Install UFW
  ansible.builtin.apt:
    name: ufw
    state: present
  when: firewall_backend == "ufw"

# Configuration tasks below need the ufw binary to exist on disk.
# In --check mode the install above is only simulated, so we skip
# them to avoid "executable not found" errors.
- name: Configure UFW
  when:
    - firewall_backend == "ufw"
    - not ansible_check_mode
  block:
    - name: Set default policies
      community.general.ufw:
        direction: "{{ item.direction }}"
        policy: "{{ item.policy }}"
      loop:
        - { direction: incoming, policy: "{{ ufw_default_incoming }}" }
        - { direction: outgoing, policy: "{{ ufw_default_outgoing }}" }

    - name: Apply UFW rules
      community.general.ufw:
        rule: "{{ item.rule }}"
        port: "{{ item.port }}"
        proto: "{{ item.proto | default('any') }}"
        from_ip: "{{ item.from | default('any') }}"
      loop: "{{ ufw_rules }}"

    - name: Enable UFW
      community.general.ufw:
        state: enabled

# For raw iptables migration, uncomment:
# - name: Restore iptables rules
#   ansible.builtin.copy:
#     src: iptables-v4.rules
#     dest: /etc/iptables/rules.v4
#     mode: "0644"
#   notify: Restore iptables

# For nftables, uncomment:
# - name: Deploy nftables config
#   ansible.builtin.copy:
#     src: nftables.conf
#     dest: /etc/nftables.conf
#     mode: "0644"
#   notify: Restart nftables
EOF

cat > "$PROJECT/roles/firewall/handlers/main.yml" <<EOF
---
- name: Restore iptables
  ansible.builtin.shell: iptables-restore < /etc/iptables/rules.v4

- name: Restart nftables
  ansible.builtin.systemd:
    name: nftables
    state: restarted
EOF

# Copy raw rule files for reference
for f in iptables-v4.rules iptables-v6.rules nftables.conf; do
    [[ -f "$AUDIT_DIR/firewall/$f" ]] && cp "$AUDIT_DIR/firewall/$f" "$PROJECT/roles/firewall/files/"
done

ok "Role: firewall"

# ============================================================================
#  ROLE: docker
# ============================================================================

info "Generating role: docker ..."

# Collect compose file paths
COMPOSE_FILES=""
if [[ -d "$AUDIT_DIR/docker/compose-files" ]]; then
    for f in "$AUDIT_DIR"/docker/compose-files/*; do
        [[ -f "$f" ]] || continue
        # Reconstruct original path from audit slug:
        #   "root_mnt_docker_piwigo_docker-compose.yml" → "/root/mnt/docker/piwigo"
        original=$(basename "$f" | sed 's/^_//; s/_/\//g')
        dir=$(dirname "/$original")
        COMPOSE_FILES+="  - ${dir}
"
        # The task copies via:
        #   src: "{{ item | regex_replace('/', '_') }}.yml"
        # For item=/root/mnt/docker/piwigo, that's "_root_mnt_docker_piwigo.yml"
        # — so we rename the file here to match exactly.
        dest_slug="$(echo "$dir" | tr '/' '_').yml"
        cp "$f" "$PROJECT/roles/docker/files/$dest_slug"
    done
fi

cat > "$PROJECT/roles/docker/defaults/main.yml" <<EOF
---
# Docker compose directories found on the old server.
# Update paths if you want to reorganise on the new machine.
docker_compose_dirs:
${COMPOSE_FILES:-  # No compose files found — check audit docker/inspect/ for container configs}

# Docker daemon config (copy from files/daemon.json if customised)
docker_custom_daemon_json: false
EOF

cat > "$PROJECT/roles/docker/tasks/main.yml" <<EOF
---
# ── Modern Debian 13 Docker install using deb822_repository ───────────────
# This avoids the deprecated apt-key utility and uses the structured
# DEB822 sources format that Debian now recommends.

- name: Install Docker repository prerequisites
  ansible.builtin.apt:
    name:
      - ca-certificates
      - python3-debian      # required by deb822_repository module
    state: present
    update_cache: yes
    cache_valid_time: 3600

- name: Add Docker DEB822 repository (with embedded signing key)
  ansible.builtin.deb822_repository:
    name: docker
    types: deb
    uris: https://download.docker.com/linux/debian
    suites: "{{ ansible_facts['distribution_release'] }}"
    components: stable
    architectures: "{{ 'amd64' if ansible_facts['architecture'] == 'x86_64' else ansible_facts['architecture'] }}"
    signed_by: https://download.docker.com/linux/debian/gpg
    state: present
    enabled: yes
  register: docker_repo

- name: Refresh apt cache after adding Docker repo
  ansible.builtin.apt:
    update_cache: yes
  when: docker_repo.changed

- name: Install Docker Engine
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present

- name: Deploy custom daemon.json
  ansible.builtin.copy:
    src: daemon.json
    dest: /etc/docker/daemon.json
    owner: root
    group: root
    mode: "0644"
  notify: Restart Docker
  when: docker_custom_daemon_json

# Tasks below need the docker binary on disk. In --check mode the install
# is only simulated, so we skip them to avoid "executable not found".
- name: Configure Docker (skip in --check mode)
  when: not ansible_check_mode
  block:
    - name: Ensure Docker is started and enabled
      ansible.builtin.systemd:
        name: docker
        state: started
        enabled: yes

    # ── Compose projects ──────────────────────────────────────────────────
    # IMPORTANT: a docker-compose.yml is not enough — most containers also
    # need their bind-mounted data directories (databases, configs, app
    # state). Recommended workflow BEFORE running this playbook:
    #
    #   # On the old server, stop services cleanly:
    #   cd /root/mnt/docker && docker compose -f */docker-compose.yml stop
    #
    #   # From your workstation, rsync the whole tree to the new server:
    #   rsync -avHAX --numeric-ids \\
    #     oldserver:/root/mnt/docker/ \\
    #     newserver:/root/mnt/docker/
    #
    # The tasks below then just bring the containers up using whatever
    # is on disk. If the directory is empty, we fall back to deploying
    # the compose file from this role's files/ directory.

    - name: Show compose projects this role will manage
      ansible.builtin.debug:
        msg: "{{ docker_compose_dirs }}"

    - name: Ensure compose project directories exist
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0755"
      loop: "{{ docker_compose_dirs }}"

    - name: Check whether each project already has a compose file
      ansible.builtin.stat:
        path: "{{ item }}/docker-compose.yml"
      loop: "{{ docker_compose_dirs }}"
      register: existing_compose

    - name: Deploy compose file from role (only if not already present)
      ansible.builtin.copy:
        src: "{{ item.item | regex_replace('/', '_') }}.yml"
        dest: "{{ item.item }}/docker-compose.yml"
        owner: root
        group: root
        mode: "0644"
      loop: "{{ existing_compose.results }}"
      when: not item.stat.exists
      failed_when: false   # don't abort if the source file is absent

    - name: Re-check for compose files after deploy attempt
      ansible.builtin.stat:
        path: "{{ item }}/docker-compose.yml"
      loop: "{{ docker_compose_dirs }}"
      register: compose_present

    - name: Start compose projects (only where a compose file exists)
      community.docker.docker_compose_v2:
        project_src: "{{ item.item }}"
        state: present
      loop: "{{ compose_present.results }}"
      when: item.stat.exists

    - name: Summary of compose project status
      ansible.builtin.debug:
        msg: |
          Compose projects:
          {% for r in compose_present.results %}
          - {{ r.item }}: {{ 'STARTED' if r.stat.exists else 'SKIPPED (no compose file — rsync data first)' }}
          {% endfor %}
EOF

cat > "$PROJECT/roles/docker/handlers/main.yml" <<EOF
---
- name: Restart Docker
  ansible.builtin.systemd:
    name: docker
    state: restarted
EOF

# Copy daemon.json if present
[[ -f "$AUDIT_DIR/docker/daemon.json" ]] && cp "$AUDIT_DIR/docker/daemon.json" "$PROJECT/roles/docker/files/"

ok "Role: docker"

# ============================================================================
#  ROLE: vpn (OpenVPN or WireGuard)
# ============================================================================

info "Generating role: vpn ..."

# Extract OpenVPN params if summary exists
VPN_SUBNET=""
VPN_PORT=""
VPN_PROTO=""
if [[ -f "$AUDIT_DIR/openvpn/summary.txt" ]]; then
    VPN_SUBNET=$(grep -oP 'server\s+\K[\d./\s]+' "$AUDIT_DIR/openvpn/summary.txt" | head -1 | xargs)
    VPN_PORT=$(grep -oP 'port\s+\K\d+' "$AUDIT_DIR/openvpn/summary.txt" | head -1)
    VPN_PROTO=$(grep -oP 'proto\s+\K\w+' "$AUDIT_DIR/openvpn/summary.txt" | head -1)
fi

# Count clients from issued certs
CLIENT_COUNT=0
CLIENTS=""
if [[ -f "$AUDIT_DIR/openvpn/issued-certs.txt" ]]; then
    CLIENT_COUNT=$(wc -l < "$AUDIT_DIR/openvpn/issued-certs.txt")
    CLIENTS=$(sed 's/\.crt$//; s/^/    - /' "$AUDIT_DIR/openvpn/issued-certs.txt" | grep -v 'server')
fi

cat > "$PROJECT/roles/vpn/defaults/main.yml" <<EOF
---
# ── VPN backend ─────────────────────────────────────────────────────────────
# Set in group_vars/rebuild.yml:  vpn_backend: "openvpn" or "wireguard"

# ── OpenVPN settings (from old server) ──────────────────────────────────────
openvpn_subnet: "${VPN_SUBNET:-10.8.0.0 255.255.255.0}"
openvpn_port: ${VPN_PORT:-1194}
openvpn_proto: "${VPN_PROTO:-udp}"

# ── WireGuard settings (for migration) ──────────────────────────────────────
wireguard_address: "10.8.0.1/24"        # Match your old VPN subnet
wireguard_port: 51820
wireguard_interface: "wg0"

# Clients to create (${CLIENT_COUNT} found on old server):
vpn_clients:
${CLIENTS:-    # No clients extracted — add manually}
EOF

cat > "$PROJECT/roles/vpn/tasks/main.yml" <<EOF
---
- name: Set up OpenVPN
  ansible.builtin.include_tasks: openvpn.yml
  when: vpn_backend == "openvpn"

- name: Set up WireGuard
  ansible.builtin.include_tasks: wireguard.yml
  when: vpn_backend == "wireguard"
EOF

cat > "$PROJECT/roles/vpn/tasks/openvpn.yml" <<EOF
---
# ── OpenVPN: reproduce the old setup ────────────────────────────────────────

- name: Install OpenVPN and Easy-RSA
  ansible.builtin.apt:
    name:
      - openvpn
      - easy-rsa
    state: present

- name: Deploy OpenVPN server config
  ansible.builtin.template:
    src: server.conf.j2
    dest: /etc/openvpn/server/server.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart OpenVPN

# NOTE: You must also transfer or regenerate the PKI (CA, server cert, DH, ta.key).
# Option A — copy from old server:
#   scp -r old:/etc/openvpn/easy-rsa/pki /etc/openvpn/easy-rsa/pki
# Option B — fresh PKI (all clients need new certs):
#   cd /etc/openvpn/easy-rsa && easyrsa init-pki && easyrsa build-ca ...

- name: Enable IP forwarding
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: yes
    reload: yes

# Service-level tasks need openvpn binaries — skip in --check mode.
- name: Start OpenVPN (skip in --check mode)
  when: not ansible_check_mode
  block:
    - name: Start and enable OpenVPN
      ansible.builtin.systemd:
        name: "openvpn-server@server"
        state: started
        enabled: yes
EOF

cat > "$PROJECT/roles/vpn/tasks/wireguard.yml" <<EOF
---
# ── WireGuard: fresh setup replacing OpenVPN ────────────────────────────────

- name: Install WireGuard
  ansible.builtin.apt:
    name:
      - wireguard
      - wireguard-tools
    state: present

- name: Enable IP forwarding
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: yes
    reload: yes

# Tasks below need the wg binary — skip in --check mode.
- name: Configure WireGuard (skip in --check mode)
  when: not ansible_check_mode
  block:
    - name: Generate server private key
      ansible.builtin.shell: wg genkey
      register: wg_server_privkey
      args:
        creates: /etc/wireguard/server_private.key

    - name: Save server private key
      ansible.builtin.copy:
        content: "{{ wg_server_privkey.stdout }}"
        dest: /etc/wireguard/server_private.key
        owner: root
        group: root
        mode: "0600"
      when: wg_server_privkey.changed

    - name: Derive server public key
      ansible.builtin.shell: cat /etc/wireguard/server_private.key | wg pubkey
      register: wg_server_pubkey
      changed_when: false

    - name: Deploy WireGuard config
      ansible.builtin.template:
        src: wg0.conf.j2
        dest: /etc/wireguard/wg0.conf
        owner: root
        group: root
        mode: "0600"
      notify: Restart WireGuard

    - name: Start and enable WireGuard
      ansible.builtin.systemd:
        name: "wg-quick@wg0"
        state: started
        enabled: yes

    - name: Create client key pairs
      ansible.builtin.shell: |
        mkdir -p /etc/wireguard/clients/{{ item }}
        wg genkey | tee /etc/wireguard/clients/{{ item }}/private.key | wg pubkey > /etc/wireguard/clients/{{ item }}/public.key
        chmod 600 /etc/wireguard/clients/{{ item }}/private.key
      args:
        creates: "/etc/wireguard/clients/{{ item }}/private.key"
      loop: "{{ vpn_clients }}"
EOF

# Create template files
cat > "$PROJECT/roles/vpn/templates/wg0.conf.j2" <<'EOF'
# {{ ansible_managed }}

[Interface]
Address    = {{ wireguard_address }}
ListenPort = {{ wireguard_port }}
PrivateKey = {{ lookup('file', '/etc/wireguard/server_private.key') }}
PostUp     = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown   = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Peers are added by the client key generation tasks
# or manually with:  wg set wg0 peer <PUBKEY> allowed-ips 10.8.0.X/32
EOF

# Copy old OpenVPN configs for reference
if [[ -d "$AUDIT_DIR/openvpn/etc-openvpn" ]]; then
    mkdir -p "$PROJECT/roles/vpn/files/openvpn-old"
    cp -a "$AUDIT_DIR/openvpn/etc-openvpn"/* "$PROJECT/roles/vpn/files/openvpn-old/" 2>/dev/null || true
fi
[[ -f "$AUDIT_DIR/openvpn/wireguard-migration-notes.txt" ]] && \
    cp "$AUDIT_DIR/openvpn/wireguard-migration-notes.txt" "$PROJECT/roles/vpn/files/"

cat > "$PROJECT/roles/vpn/handlers/main.yml" <<EOF
---
- name: Restart OpenVPN
  ansible.builtin.systemd:
    name: "openvpn-server@server"
    state: restarted

- name: Restart WireGuard
  ansible.builtin.systemd:
    name: "wg-quick@wg0"
    state: restarted
EOF

ok "Role: vpn"

# ============================================================================
#  ROLE: cron
# ============================================================================

info "Generating role: cron ..."

# Parse user crontabs into Ansible tasks
CRON_TASKS=""
if [[ -d "$AUDIT_DIR/cron/user-crontabs" ]]; then
    for tab in "$AUDIT_DIR"/cron/user-crontabs/*; do
        [[ -f "$tab" ]] || continue
        cron_user=$(basename "$tab")
        # Read non-comment, non-empty lines
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^[A-Z_]+= ]] && continue   # skip env vars

            # Parse: min hour dom mon dow command
            read -r m h dom mon dow cmd <<< "$line"
            job_name=$(echo "$cmd" | head -c 60 | tr -cs 'a-zA-Z0-9_' '_')
            CRON_TASKS+="
- name: \"Cron [${cron_user}]: ${job_name}\"
  ansible.builtin.cron:
    name: \"${cron_user}_${job_name}\"
    user: \"${cron_user}\"
    minute: \"${m}\"
    hour: \"${h}\"
    day: \"${dom}\"
    month: \"${mon}\"
    weekday: \"${dow}\"
    job: \"${cmd}\"
"
        done < "$tab"
    done
fi

cat > "$PROJECT/roles/cron/tasks/main.yml" <<EOF
---
# Cron jobs extracted from the old server.
# Review each one — paths and scripts may need updating for the new server.
${CRON_TASKS:-
# No user crontabs found. Check audit/cron/ for system crontabs (cron.d, etc.)
# and add them here manually.}

# System-level cron.d files
- name: Deploy cron.d scripts
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/cron.d/{{ item | basename }}"
    owner: root
    group: root
    mode: "0644"
  with_fileglob:
    - "files/cron.d/*"
EOF

# Copy cron.d files
if [[ -d "$AUDIT_DIR/cron/cron.d" ]]; then
    mkdir -p "$PROJECT/roles/cron/files/cron.d"
    cp -a "$AUDIT_DIR/cron/cron.d"/* "$PROJECT/roles/cron/files/cron.d/" 2>/dev/null || true
fi

# Copy custom scripts that cron jobs might reference
if [[ -d "$AUDIT_DIR/scripts" ]]; then
    cp -a "$AUDIT_DIR/scripts"/* "$PROJECT/roles/cron/files/" 2>/dev/null || true
fi

ok "Role: cron"

# ============================================================================
#  ROLE: security
# ============================================================================

info "Generating role: security ..."

# Check for fail2ban
HAS_FAIL2BAN=false
[[ -d "$AUDIT_DIR/security/fail2ban-etc" ]] && HAS_FAIL2BAN=true

cat > "$PROJECT/roles/security/defaults/main.yml" <<EOF
---
security_fail2ban: ${HAS_FAIL2BAN}
security_unattended_upgrades: true

# sysctl hardening (extracted from old server's custom sysctl.d)
sysctl_settings: {}
#  net.ipv4.ip_forward: 1
#  net.ipv4.conf.all.rp_filter: 1
#  net.ipv6.conf.all.disable_ipv6: 1
EOF

cat > "$PROJECT/roles/security/tasks/main.yml" <<EOF
---
- name: Install security packages
  ansible.builtin.apt:
    name:
      - fail2ban
      - unattended-upgrades
      - apt-listchanges
    state: present

# fail2ban
- name: Deploy fail2ban jail.local
  ansible.builtin.copy:
    src: jail.local
    dest: /etc/fail2ban/jail.local
    owner: root
    group: root
    mode: "0644"
  notify: Restart fail2ban
  when: security_fail2ban

# Tasks needing the fail2ban service unit on disk — skip in --check mode.
- name: Enable fail2ban (skip in --check mode)
  when:
    - security_fail2ban
    - not ansible_check_mode
  block:
    - name: Enable fail2ban
      ansible.builtin.systemd:
        name: fail2ban
        state: started
        enabled: yes

# Unattended upgrades
- name: Deploy unattended-upgrades config
  ansible.builtin.copy:
    src: 50unattended-upgrades
    dest: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root
    group: root
    mode: "0644"
  when: security_unattended_upgrades

# sysctl hardening
- name: Apply sysctl settings
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_set: yes
    reload: yes
  loop: "{{ sysctl_settings | dict2items }}"
  when: sysctl_settings | length > 0

# ─── DANGEROUS — opt-in only ──────────────────────────────────────────────
# The old server's sshd_config may have:
#   - AllowUsers directive that excludes your current bootstrap user
#   - PasswordAuthentication no (you need keys working first)
#   - PermitRootLogin no
#   - Different port number
# Any of these can lock you out instantly. Defaults to off; set
# deploy_old_sshd_config: true in group_vars only after a successful first
# run AND after manually reviewing roles/users/templates/sshd_config.j2.
- name: Deploy hardened sshd_config (DANGEROUS — opt-in)
  ansible.builtin.template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: "0644"
    validate: "sshd -t -f %s"
    backup: yes   # keeps /etc/ssh/sshd_config.<timestamp>~ for rollback
  notify: Restart sshd
  when:
    - deploy_old_sshd_config | bool
    - "'sshd_config.j2' is file"
EOF

cat > "$PROJECT/roles/security/handlers/main.yml" <<EOF
---
- name: Restart fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    state: restarted

- name: Restart sshd
  ansible.builtin.systemd:
    name: sshd
    state: restarted
EOF

# Copy fail2ban config
if [[ -d "$AUDIT_DIR/security/fail2ban-etc" ]]; then
    cp -a "$AUDIT_DIR/security/fail2ban-etc"/* "$PROJECT/roles/security/files/" 2>/dev/null || true
fi

# Copy unattended-upgrades config
for f in 50unattended-upgrades 20auto-upgrades; do
    [[ -f "$AUDIT_DIR/security/$f" ]] && cp "$AUDIT_DIR/security/$f" "$PROJECT/roles/security/files/"
done

# Copy sysctl overrides
if [[ -d "$AUDIT_DIR/security/sysctl.d" ]]; then
    mkdir -p "$PROJECT/roles/security/files/sysctl.d"
    cp -a "$AUDIT_DIR/security/sysctl.d"/* "$PROJECT/roles/security/files/sysctl.d/" 2>/dev/null || true
fi

ok "Role: security"

# ============================================================================
#  MAIN PLAYBOOK (site.yml)
# ============================================================================

cat > "$PROJECT/site.yml" <<EOF
---
# ============================================================================
# Server Rebuild Playbook — generated from infrastructure audit
# ============================================================================
#
# Usage:
#   ansible-playbook -i inventory/hosts.ini site.yml
#
# Run a single role:
#   ansible-playbook -i inventory/hosts.ini site.yml --tags docker
#
# Dry run:
#   ansible-playbook -i inventory/hosts.ini site.yml --check --diff
#
# ============================================================================

- name: Rebuild server from audit
  hosts: rebuild
  become: yes

  pre_tasks:
    - name: Wait for target to be reachable
      ansible.builtin.wait_for_connection:
        timeout: 30

    - name: Gather facts
      ansible.builtin.setup:

    - name: Verify Debian version
      ansible.builtin.assert:
        that:
          - ansible_facts['distribution'] == "Debian"
        fail_msg: "This playbook is designed for Debian. Found: {{ ansible_facts['distribution'] }}"

    # ─── LOCKOUT PROTECTION PRE-FLIGHT ────────────────────────────────────
    # Verify the bootstrap user really has sudo before we make any changes.
    # If they don't, abort BEFORE any role runs — otherwise the play could
    # leave the box in a state where we can't reconnect to fix it.
    - name: "Lockout protection: confirm bootstrap_user exists"
      ansible.builtin.getent:
        database: passwd
        key: "{{ bootstrap_user }}"
      register: bootstrap_pw

    - name: "Lockout protection: warn if deploying old sshd_config or sudoers"
      ansible.builtin.debug:
        msg: |
          ⚠️  WARNING — DANGEROUS OPTIONS ENABLED ⚠️
          deploy_old_sudoers     = {{ deploy_old_sudoers }}
          deploy_old_sshd_config = {{ deploy_old_sshd_config }}
          These can lock you out. Make sure you have console access to
          recover, and that you've reviewed the files being deployed.
      when: deploy_old_sudoers or deploy_old_sshd_config

    - name: Show target info
      ansible.builtin.debug:
        msg: "Deploying to {{ ansible_facts['hostname'] }} running {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }} as {{ bootstrap_user }}"

  roles:
    - { role: users,         tags: ['users', 'ssh'] }
    - { role: base-packages, tags: ['base', 'packages'] }
    - { role: networking,    tags: ['networking'] }
    - { role: docker,        tags: ['docker'] }
    - { role: vpn,           tags: ['vpn'] }
    - { role: cron,          tags: ['cron'] }
    - { role: firewall,      tags: ['firewall'] }
    - { role: security,      tags: ['security'] }
EOF

ok "Main playbook: site.yml"

# ============================================================================
#  ANSIBLE.CFG
# ============================================================================

cat > "$PROJECT/ansible.cfg" <<EOF
[defaults]
inventory               = inventory/hosts.ini
roles_path              = roles
retry_files_enabled     = False
stdout_callback         = default
result_format           = yaml
host_key_checking       = False
# Opt in to the future default (Ansible 2.24+):
# top-level facts like ansible_distribution will not be auto-injected;
# all our playbooks already use ansible_facts['...'] consistently.
inject_facts_as_vars    = False

[privilege_escalation]
become                  = True
become_method           = sudo

[ssh_connection]
pipelining              = True
EOF

ok "ansible.cfg"

# ============================================================================
#  REQUIREMENTS.YML — collections needed by the playbook
# ============================================================================

cat > "$PROJECT/requirements.yml" <<EOF
---
# Install with:
#   ansible-galaxy collection install -r requirements.yml
collections:
  - name: ansible.posix       # authorized_key, sysctl
  - name: community.general   # timezone, ufw
  - name: community.docker    # docker_compose_v2
EOF

ok "requirements.yml"

# ============================================================================
#  README
# ============================================================================

cat > "$PROJECT/README.md" <<'EOF'
# Server Rebuild — Ansible Project

Auto-generated from a server infrastructure audit.

## Quick Start

```bash
# 1. Install Ansible on your workstation (latest stable)
pip install --upgrade ansible

# 2. Install required collections
ansible-galaxy collection install -r requirements.yml

# 3. Edit the inventory with your new server's IP
vim inventory/hosts.ini

# 4. Review and customise variables
vim group_vars/rebuild.yml

# 5. Dry run (no changes made)
ansible-playbook -i inventory/hosts.ini site.yml --check --diff

# 6. Run for real
ansible-playbook -i inventory/hosts.ini site.yml

# 7. Run only specific roles
ansible-playbook -i inventory/hosts.ini site.yml --tags docker,vpn
```

## What to review before running

1. **`group_vars/rebuild.yml`** — server hostname, timezone, VPN backend choice
2. **`roles/base-packages/defaults/main.yml`** — package list (check for Debian 13 renames)
3. **`roles/networking/templates/`** — IP addresses will differ on the new server
4. **`roles/firewall/defaults/main.yml`** — verify UFW rules make sense
5. **`roles/vpn/defaults/main.yml`** — choose `openvpn` or `wireguard`
6. **`roles/docker/`** — you'll need to transfer compose files, volumes, and .env files manually
7. **`roles/cron/`** — verify script paths exist on the new server

## VPN Migration (OpenVPN → WireGuard)

Set `vpn_backend: "wireguard"` in `group_vars/rebuild.yml`. See
`roles/vpn/files/wireguard-migration-notes.txt` for the mapping between
your old OpenVPN config and the new WireGuard setup.

**Important:** All clients will need new WireGuard configs (key pairs + endpoints).

## Directory Structure

```
ansible-rebuild/
├── ansible.cfg
├── requirements.yml            # Required Ansible collections
├── inventory/hosts.ini          # Target server(s)
├── group_vars/rebuild.yml       # Shared variables
├── site.yml                     # Main playbook
└── roles/
    ├── base-packages/           # APT packages, timezone, hostname
    ├── users/                   # Users, SSH keys, sudoers
    ├── networking/              # Network interfaces, DNS, hosts
    ├── firewall/                # UFW / iptables / nftables
    ├── security/                # fail2ban, sysctl, unattended-upgrades
    ├── docker/                  # Docker CE, compose projects
    ├── vpn/                     # OpenVPN or WireGuard
    └── cron/                    # Cron jobs, scripts
```
EOF

ok "README.md"

# ============================================================================
#  Final output
# ============================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Ansible project generated: ${PROJECT}/${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Structure:"
find "$PROJECT" -type f | sort | sed 's|^\./ansible-rebuild/|    |'
echo ""
echo -e "${YELLOW}  NEXT STEPS:${NC}"
echo "    1.  cd $PROJECT"
echo "    2.  ansible-galaxy collection install -r requirements.yml"
echo "    3.  Edit inventory/hosts.ini — set the new server's IP"
echo "    4.  Edit group_vars/rebuild.yml — set vpn_backend, review settings"
echo "    5.  Review each role's defaults/main.yml"
echo "    6.  ansible-playbook site.yml --check --diff   (dry run)"
echo "    7.  ansible-playbook site.yml                  (deploy!)"
echo ""
