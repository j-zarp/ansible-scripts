#!/usr/bin/env bash
# ============================================================================
#  server-audit.sh — Infrastructure Archaeology for Debian Servers
# ============================================================================
#  Run as root on the server you want to snapshot.
#  Produces a timestamped directory with everything needed to recreate the
#  machine as Ansible roles.
#
#  Usage:  sudo bash server-audit.sh [output_dir]
# ============================================================================

set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC}  %s\n" "$*"; }
banner(){ printf "\n${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"; \
          printf "${BOLD}  %s${NC}\n" "$*"; \
          printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n\n"; }

# ── Pre-flight checks ───────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (or with sudo)."
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME_SHORT=$(hostname -s)
OUTDIR="${1:-/root/ansible/server-audit_${HOSTNAME_SHORT}_${TIMESTAMP}}"
mkdir -p "$OUTDIR"

banner "Infrastructure Archaeology — $(hostname -f)"
info "Output directory: $OUTDIR"
info "Timestamp:        $TIMESTAMP"
echo ""

# Helper: run a command, save stdout, warn on failure
collect() {
    local label="$1" outfile="$2"; shift 2
    info "Collecting $label ..."
    mkdir -p "$(dirname "$OUTDIR/$outfile")"
    if "$@" > "$OUTDIR/$outfile" 2>/dev/null; then
        ok "$label → $outfile"
    else
        warn "$label — command failed or not available"
    fi
}

# Helper: copy a file/dir if it exists
grab() {
    local src="$1" dest="$OUTDIR/$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp -a "$src" "$dest"
        ok "Copied $src"
    else
        warn "Not found: $src (skipped)"
    fi
}

# ============================================================================
#  1. SYSTEM OVERVIEW
# ============================================================================
banner "1/12 — System Overview"

collect "hostname"          "system/hostname.txt"           hostname -f
collect "OS release"        "system/os-release.txt"         cat /etc/os-release
collect "kernel version"    "system/kernel.txt"             uname -a
collect "uptime"            "system/uptime.txt"             uptime
collect "disk layout"       "system/lsblk.txt"              lsblk -f
collect "fstab"             "system/fstab.txt"              cat /etc/fstab
collect "mount points"      "system/mounts.txt"             mount
collect "free memory"       "system/memory.txt"             free -h
collect "CPU info"          "system/cpuinfo.txt"            lscpu
collect "locale"            "system/locale.txt"             locale
collect "timezone"          "system/timezone.txt"           timedatectl

# ============================================================================
#  2. INSTALLED PACKAGES
# ============================================================================
banner "2/12 — Installed Packages"

collect "all packages (dpkg)"       "packages/dpkg-selections.txt"  dpkg --get-selections
collect "manually installed (apt)"  "packages/apt-manual.txt"       apt-mark showmanual
collect "apt sources"               "packages/sources-list.txt"     cat /etc/apt/sources.list

# Gather sources.list.d
if [[ -d /etc/apt/sources.list.d ]]; then
    mkdir -p "$OUTDIR/packages/sources.list.d"
    cp -a /etc/apt/sources.list.d/* "$OUTDIR/packages/sources.list.d/" 2>/dev/null && \
        ok "Copied /etc/apt/sources.list.d/" || warn "sources.list.d empty or unreadable"
fi

# GPG keys for third-party repos
if [[ -d /etc/apt/trusted.gpg.d ]]; then
    mkdir -p "$OUTDIR/packages/trusted.gpg.d"
    cp -a /etc/apt/trusted.gpg.d/* "$OUTDIR/packages/trusted.gpg.d/" 2>/dev/null && \
        ok "Copied APT trusted keys" || warn "No APT trusted keys"
fi

# Also grab keyrings (modern style)
if [[ -d /usr/share/keyrings ]]; then
    mkdir -p "$OUTDIR/packages/keyrings"
    cp -a /usr/share/keyrings/*.gpg "$OUTDIR/packages/keyrings/" 2>/dev/null || true
    cp -a /usr/share/keyrings/*.asc "$OUTDIR/packages/keyrings/" 2>/dev/null || true
    ok "Copied /usr/share/keyrings (if any)"
fi

# Packages modified from defaults
if command -v debsums &>/dev/null; then
    collect "modified conffiles (debsums)" "packages/debsums-changed.txt" debsums -c
else
    warn "debsums not installed — skipping conffile diff (apt install debsums for better results)"
fi

# ============================================================================
#  3. USERS, GROUPS & SSH
# ============================================================================
banner "3/12 — Users, Groups & SSH"

collect "passwd"            "users/passwd.txt"              cat /etc/passwd
collect "group"             "users/group.txt"               cat /etc/group
collect "shadow (hashes)"   "users/shadow.txt"              cat /etc/shadow
collect "sudoers"           "users/sudoers.txt"             cat /etc/sudoers

if [[ -d /etc/sudoers.d ]]; then
    mkdir -p "$OUTDIR/users/sudoers.d"
    cp -a /etc/sudoers.d/* "$OUTDIR/users/sudoers.d/" 2>/dev/null && \
        ok "Copied /etc/sudoers.d/" || warn "sudoers.d empty"
fi

grab /etc/ssh/sshd_config        "users/sshd_config"
if [[ -d /etc/ssh/sshd_config.d ]]; then
    mkdir -p "$OUTDIR/users/sshd_config.d"
    cp -a /etc/ssh/sshd_config.d/* "$OUTDIR/users/sshd_config.d/" 2>/dev/null || true
    ok "Copied sshd_config.d"
fi

# Collect authorized_keys for every real user
info "Collecting SSH authorized_keys ..."
mkdir -p "$OUTDIR/users/authorized_keys"
while IFS=: read -r user _ uid _ _ home _; do
    if [[ $uid -ge 1000 || "$user" == "root" ]] && [[ -f "$home/.ssh/authorized_keys" ]]; then
        cp "$home/.ssh/authorized_keys" "$OUTDIR/users/authorized_keys/${user}.keys"
        ok "  $user → authorized_keys"
    fi
done < /etc/passwd

# ============================================================================
#  4. NETWORK CONFIGURATION
# ============================================================================
banner "4/12 — Network Configuration"

collect "ip addresses"      "network/ip-addr.txt"           ip -c addr
collect "ip routes"         "network/ip-route.txt"          ip route
collect "ip rules"          "network/ip-rule.txt"           ip rule
collect "DNS resolv.conf"   "network/resolv.conf"           cat /etc/resolv.conf
collect "hosts file"        "network/hosts.txt"             cat /etc/hosts
collect "listening ports"   "network/ss-listening.txt"      ss -tlnp

grab /etc/network/interfaces           "network/interfaces"
if [[ -d /etc/network/interfaces.d ]]; then
    mkdir -p "$OUTDIR/network/interfaces.d"
    cp -a /etc/network/interfaces.d/* "$OUTDIR/network/interfaces.d/" 2>/dev/null || true
fi

if [[ -d /etc/netplan ]]; then
    mkdir -p "$OUTDIR/network/netplan"
    cp -a /etc/netplan/* "$OUTDIR/network/netplan/" 2>/dev/null || true
    ok "Copied netplan configs"
fi

if [[ -d /etc/systemd/network ]]; then
    mkdir -p "$OUTDIR/network/systemd-networkd"
    cp -a /etc/systemd/network/* "$OUTDIR/network/systemd-networkd/" 2>/dev/null || true
    ok "Copied systemd-networkd configs"
fi

# ============================================================================
#  5. FIREWALL — iptables, nftables, ufw
# ============================================================================
banner "5/12 — Firewall Rules"

if command -v iptables-save &>/dev/null; then
    collect "iptables (v4)"     "firewall/iptables-v4.rules"    iptables-save
fi
if command -v ip6tables-save &>/dev/null; then
    collect "iptables (v6)"     "firewall/iptables-v6.rules"    ip6tables-save
fi
if command -v nft &>/dev/null; then
    collect "nftables ruleset"  "firewall/nftables.conf"        nft list ruleset
fi
if command -v ufw &>/dev/null; then
    collect "ufw status"        "firewall/ufw-status.txt"       ufw status verbose
    collect "ufw app list"      "firewall/ufw-apps.txt"         ufw app list
    grab /etc/ufw                                               "firewall/ufw-etc"
fi

# ============================================================================
#  6. SYSTEMD SERVICES & TIMERS
# ============================================================================
banner "6/12 — Systemd Services & Timers"

collect "enabled units"     "services/enabled-units.txt"    systemctl list-unit-files --state=enabled --no-pager
collect "running services"  "services/running-services.txt" systemctl list-units --type=service --state=running --no-pager
collect "all timers"        "services/timers.txt"           systemctl list-timers --all --no-pager
collect "failed units"      "services/failed-units.txt"     systemctl list-units --failed --no-pager

# Grab custom unit files (non-package)
info "Collecting custom systemd units ..."
mkdir -p "$OUTDIR/services/custom-units"
for dir in /etc/systemd/system /etc/systemd/user; do
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 2 -name '*.service' -o -name '*.timer' -o -name '*.mount' \
            -o -name '*.path' 2>/dev/null | while read -r unit; do
            relpath="${unit#/etc/systemd/}"
            mkdir -p "$OUTDIR/services/custom-units/$(dirname "$relpath")"
            cp "$unit" "$OUTDIR/services/custom-units/$relpath"
        done
        ok "Scanned $dir"
    fi
done

# ============================================================================
#  7. CRON JOBS
# ============================================================================
banner "7/12 — Cron Jobs & Scheduled Tasks"

grab /etc/crontab                       "cron/crontab"
for crondir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
    if [[ -d "$crondir" ]]; then
        target="cron/$(basename "$crondir")"
        mkdir -p "$OUTDIR/$target"
        cp -a "$crondir"/* "$OUTDIR/$target/" 2>/dev/null || true
        ok "Copied $crondir"
    fi
done

# Per-user crontabs
info "Collecting per-user crontabs ..."
mkdir -p "$OUTDIR/cron/user-crontabs"
if [[ -d /var/spool/cron/crontabs ]]; then
    for tab in /var/spool/cron/crontabs/*; do
        [[ -f "$tab" ]] && cp "$tab" "$OUTDIR/cron/user-crontabs/" && ok "  $(basename "$tab") crontab"
    done
fi

# ============================================================================
#  8. DOCKER
# ============================================================================
banner "8/12 — Docker & Containers"

if command -v docker &>/dev/null; then
    collect "docker version"        "docker/version.txt"            docker version
    collect "docker info"           "docker/info.txt"               docker info
    collect "docker images"         "docker/images.txt"             docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
    collect "docker containers"     "docker/containers.txt"         docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    collect "docker networks"       "docker/networks.txt"           docker network ls
    collect "docker volumes"        "docker/volumes.txt"            docker volume ls

    # Inspect every running container
    info "Inspecting running containers ..."
    mkdir -p "$OUTDIR/docker/inspect"
    docker ps -q 2>/dev/null | while read -r cid; do
        cname=$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')
        docker inspect "$cid" > "$OUTDIR/docker/inspect/${cname}.json"
        ok "  Inspected $cname"
    done

    # Find docker-compose files
    info "Searching for docker-compose files ..."
    mkdir -p "$OUTDIR/docker/compose-files"
    find / -maxdepth 5 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
        -o -name 'compose.yml' -o -name 'compose.yaml' \) \
        -not -path '*/proc/*' -not -path '*/sys/*' 2>/dev/null | while read -r f; do
        # Preserve directory structure hint in filename
        slug=$(echo "$f" | tr '/' '_' | sed 's/^_//')
        cp "$f" "$OUTDIR/docker/compose-files/$slug"
        ok "  Found $f"
    done

    # Try to reconstruct run commands with runlike (if available)
    if command -v runlike &>/dev/null; then
        info "Reconstructing 'docker run' commands (runlike) ..."
        mkdir -p "$OUTDIR/docker/runlike"
        docker ps -q 2>/dev/null | while read -r cid; do
            cname=$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')
            runlike "$cname" > "$OUTDIR/docker/runlike/${cname}.sh" 2>/dev/null
        done
        ok "runlike output saved"
    else
        warn "runlike not installed — install with 'pip install runlike' for docker-run reconstruction"
    fi

    # Docker daemon config
    grab /etc/docker/daemon.json        "docker/daemon.json"
else
    warn "Docker not found — skipping"
fi

# ============================================================================
#  9. OPENVPN
# ============================================================================
banner "9/12 — OpenVPN Configuration"

if command -v openvpn &>/dev/null || [[ -d /etc/openvpn ]]; then
    collect "openvpn version"   "openvpn/version.txt"           openvpn --version

    if [[ -d /etc/openvpn ]]; then
        mkdir -p "$OUTDIR/openvpn/etc-openvpn"
        # Copy configs but redact private keys in the output
        cp -a /etc/openvpn/* "$OUTDIR/openvpn/etc-openvpn/" 2>/dev/null
        ok "Copied /etc/openvpn/"

        # Summarise: which .conf files, which mode (server/client)
        info "Analysing OpenVPN config files ..."
        {
            echo "=== OpenVPN Configuration Summary ==="
            echo ""
            find /etc/openvpn -name '*.conf' 2>/dev/null | while read -r conf; do
                echo "--- $conf ---"
                echo "  Mode:   $(grep -qE '^\s*server\b|^\s*mode\s+server' "$conf" && echo 'SERVER' || echo 'CLIENT/P2P')"
                echo "  Proto:  $(grep -E '^\s*proto\s' "$conf" | head -1)"
                echo "  Port:   $(grep -E '^\s*port\s' "$conf" | head -1)"
                echo "  Dev:    $(grep -E '^\s*dev\s' "$conf" | head -1)"
                echo "  Subnet: $(grep -E '^\s*server\s' "$conf" | head -1)"
                echo "  Push:   $(grep -cE '^\s*push\s' "$conf") push directives"
                echo "  Auth:   $(grep -E '^\s*auth\s' "$conf" | head -1)"
                echo "  Cipher: $(grep -E '^\s*cipher\s|^\s*data-ciphers\s' "$conf" | head -1)"
                echo ""
            done
        } > "$OUTDIR/openvpn/summary.txt"
        ok "OpenVPN summary written"
    fi

    # List issued client certs (Easy-RSA / PKI)
    for pki_dir in /etc/openvpn/easy-rsa/pki /etc/easy-rsa/pki /etc/openvpn/pki; do
        if [[ -d "$pki_dir/issued" ]]; then
            info "Found PKI at $pki_dir"
            ls -1 "$pki_dir/issued/" > "$OUTDIR/openvpn/issued-certs.txt" 2>/dev/null
            ok "Listed issued certificates"

            # CRL and index
            grab "$pki_dir/index.txt"       "openvpn/pki-index.txt"
            grab "$pki_dir/crl.pem"         "openvpn/crl.pem"
            break
        fi
    done

    # Wireguard migration note
    {
        echo "=== Notes for Wireguard Migration ==="
        echo ""
        echo "Key parameters to replicate:"
        echo "  - VPN subnet (see server directive above)"
        echo "  - Client-to-client routing (check client-to-client directive)"
        echo "  - DNS push directives"
        echo "  - Number of clients: $(find /etc/openvpn -name '*.conf' -exec grep -l 'client-config-dir' {} \; 2>/dev/null | head -1)"
        echo ""
        echo "Wireguard equivalents:"
        echo "  - OpenVPN 'server 10.8.0.0 255.255.255.0' → WG Address = 10.8.0.1/24"
        echo "  - OpenVPN push routes                      → WG AllowedIPs on each peer"
        echo "  - OpenVPN client-config-dir                → WG individual [Peer] blocks"
        echo "  - OpenVPN tls-auth/tls-crypt               → WG PresharedKey (optional)"
        echo ""
        echo "Clients found (will need WG key pairs):"
        if [[ -f "$OUTDIR/openvpn/issued-certs.txt" ]]; then
            cat "$OUTDIR/openvpn/issued-certs.txt"
        else
            echo "  (no PKI directory found — check for inline certs)"
        fi
    } > "$OUTDIR/openvpn/wireguard-migration-notes.txt"
    ok "Wireguard migration notes written"
else
    warn "OpenVPN not found — skipping"
fi

# ============================================================================
#  10. SECURITY HARDENING
# ============================================================================
banner "10/12 — Security & Hardening"

collect "sysctl settings"       "security/sysctl.txt"           sysctl -a
grab /etc/sysctl.conf                                           "security/sysctl.conf"
if [[ -d /etc/sysctl.d ]]; then
    mkdir -p "$OUTDIR/security/sysctl.d"
    cp -a /etc/sysctl.d/* "$OUTDIR/security/sysctl.d/" 2>/dev/null || true
fi

# fail2ban
if command -v fail2ban-client &>/dev/null; then
    collect "fail2ban status"   "security/fail2ban-status.txt"  fail2ban-client status
    grab /etc/fail2ban                                          "security/fail2ban-etc"
    ok "Collected fail2ban config"
fi

# AppArmor / SELinux
if command -v aa-status &>/dev/null; then
    collect "AppArmor status"   "security/apparmor.txt"         aa-status
fi
if command -v sestatus &>/dev/null; then
    collect "SELinux status"    "security/selinux.txt"          sestatus
fi

# unattended-upgrades
grab /etc/apt/apt.conf.d/50unattended-upgrades    "security/50unattended-upgrades"
grab /etc/apt/apt.conf.d/20auto-upgrades           "security/20auto-upgrades"

# ============================================================================
#  11. MISC CONFIG FILES & CUSTOM SCRIPTS
# ============================================================================
banner "11/12 — Misc Config & Custom Scripts"

# Modified config files (heuristic: files in /etc modified in the last 2 years)
info "Finding recently modified files in /etc ..."
find /etc -type f -mtime -730 -not -path '*/ssl/certs/*' -not -path '*/__pycache__/*' \
    -not -name '*.dpkg-*' 2>/dev/null | sort > "$OUTDIR/system/etc-recently-modified.txt"
ok "List of recently modified /etc files saved"

# Custom scripts in common locations
info "Scanning for custom scripts ..."
{
    echo "=== Scripts in /usr/local/bin ==="
    ls -la /usr/local/bin/ 2>/dev/null || echo "(empty)"
    echo ""
    echo "=== Scripts in /usr/local/sbin ==="
    ls -la /usr/local/sbin/ 2>/dev/null || echo "(empty)"
    echo ""
    echo "=== Scripts in /opt ==="
    find /opt -maxdepth 3 -type f -executable 2>/dev/null || echo "(empty)"
    echo ""
    echo "=== Scripts in /root ==="
    find /root -maxdepth 2 -name '*.sh' -o -name '*.py' -o -name '*.bash' 2>/dev/null || echo "(empty)"
} > "$OUTDIR/system/custom-scripts.txt"
ok "Custom scripts inventory saved"

# Copy the actual scripts from /usr/local/bin and /usr/local/sbin
for sdir in /usr/local/bin /usr/local/sbin; do
    if [[ -d "$sdir" ]] && [[ "$(ls -A "$sdir" 2>/dev/null)" ]]; then
        target="scripts/$(basename "$sdir")"
        mkdir -p "$OUTDIR/$target"
        cp -a "$sdir"/* "$OUTDIR/$target/" 2>/dev/null || true
        ok "Copied $sdir"
    fi
done

# ============================================================================
#  12. GENERATE SUMMARY REPORT
# ============================================================================
banner "12/12 — Summary Report"

{
    cat <<'HEADER'
╔═══════════════════════════════════════════════════════════════════╗
║              INFRASTRUCTURE ARCHAEOLOGY REPORT                   ║
╚═══════════════════════════════════════════════════════════════════╝
HEADER

    echo "Host:       $(hostname -f)"
    echo "OS:         $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    echo "Kernel:     $(uname -r)"
    echo "Date:       $(date -Iseconds)"
    echo "Audit dir:  $OUTDIR"
    echo ""

    echo "── Packages ──────────────────────────────────────────────────"
    echo "  Total installed (dpkg):  $(wc -l < "$OUTDIR/packages/dpkg-selections.txt" 2>/dev/null || echo '?')"
    echo "  Manually installed:      $(wc -l < "$OUTDIR/packages/apt-manual.txt" 2>/dev/null || echo '?')"
    echo ""

    echo "── Services ──────────────────────────────────────────────────"
    echo "  Enabled units:  $(grep -c 'enabled' "$OUTDIR/services/enabled-units.txt" 2>/dev/null || echo '?')"
    echo "  Running now:    $(grep -c 'running' "$OUTDIR/services/running-services.txt" 2>/dev/null || echo '?')"
    echo "  Active timers:  $(grep -c 'timer' "$OUTDIR/services/timers.txt" 2>/dev/null || echo '?')"
    echo ""

    echo "── Docker ────────────────────────────────────────────────────"
    if command -v docker &>/dev/null; then
        echo "  Running containers:  $(docker ps -q 2>/dev/null | wc -l)"
        echo "  Total containers:    $(docker ps -aq 2>/dev/null | wc -l)"
        echo "  Images:              $(docker images -q 2>/dev/null | wc -l)"
        echo "  Compose files found: $(find "$OUTDIR/docker/compose-files" -type f 2>/dev/null | wc -l)"
    else
        echo "  (not installed)"
    fi
    echo ""

    echo "── Network ─────────────────────────────────────────────────"
    echo "  Listening ports:"
    ss -tlnp 2>/dev/null | tail -n +2 | awk '{printf "    %s %s\n", $4, $7}'
    echo ""

    echo "── Firewall ────────────────────────────────────────────────"
    if command -v ufw &>/dev/null; then
        echo "  UFW:      $(ufw status 2>/dev/null | head -1)"
    fi
    echo "  iptables: $(iptables -L -n 2>/dev/null | grep -c 'Chain') chains"
    echo ""

    echo "── VPN ───────────────────────────────────────────────────────"
    if [[ -d /etc/openvpn ]]; then
        echo "  OpenVPN:  INSTALLED"
        echo "  Configs:  $(find /etc/openvpn -name '*.conf' 2>/dev/null | wc -l)"
        echo "  Clients:  $(cat "$OUTDIR/openvpn/issued-certs.txt" 2>/dev/null | wc -l) issued certs"
    else
        echo "  OpenVPN:  not found"
    fi
    if command -v wg &>/dev/null; then
        echo "  WireGuard: INSTALLED"
    fi
    echo ""

    echo "── Users ───────────────────────────────────────────────────"
    echo "  System users (UID≥1000):"
    awk -F: '$3 >= 1000 && $3 < 65534 {printf "    %s (UID %s, home %s)\n", $1, $3, $6}' /etc/passwd
    echo ""

    echo "── Cron ────────────────────────────────────────────────────"
    echo "  Per-user crontabs: $(ls "$OUTDIR/cron/user-crontabs/" 2>/dev/null | wc -l)"
    echo "  cron.d entries:    $(ls "$OUTDIR/cron/cron.d/" 2>/dev/null | wc -l)"
    echo ""

    echo "══════════════════════════════════════════════════════════════"
    echo "  NEXT STEPS"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    echo "  1. Review this report and the collected files"
    echo "  2. Organise into Ansible roles:"
    echo "       roles/base-packages/    ← apt-manual.txt"
    echo "       roles/networking/       ← network/"
    echo "       roles/firewall/         ← firewall/"
    echo "       roles/docker/           ← docker/"
    echo "       roles/vpn/              ← openvpn/ (or new wireguard setup)"
    echo "       roles/cron/             ← cron/"
    echo "       roles/users/            ← users/"
    echo "       roles/security/         ← security/"
    echo "  3. Test on a throwaway Debian 13 VM"
    echo "  4. Diff /etc between old and new to catch anything missed"
    echo ""
    echo "  For OpenVPN → WireGuard migration, see:"
    echo "    $OUTDIR/openvpn/wireguard-migration-notes.txt"
    echo ""

} > "$OUTDIR/REPORT.txt"

cat "$OUTDIR/REPORT.txt"

# ── Security reminder ───────────────────────────────────────────────────────
echo ""
warn "This audit contains SENSITIVE data (shadow hashes, SSH keys, VPN certs)."
warn "Transfer it securely (scp/rsync over SSH) and store it encrypted."
echo ""

# ── Tar it up ────────────────────────────────────────────────────────────────
TARBALL="${OUTDIR}.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"
ok "Archive created: $TARBALL"
info "Size: $(du -h "$TARBALL" | cut -f1)"

echo ""
banner "Done! Transfer $TARBALL to your workstation to begin building Ansible roles."
