#!/usr/bin/env bash
# ============================================================================
#  review-playbook.sh — Human-readable summary of the Ansible rebuild project
#                       it avoids having to open and read multiple files into
#                       multiple folders
# ============================================================================
#  Run from the ansible-rebuild/ directory:
#    bash review-playbook.sh
#    bash review-playbook.sh | less -R
#    bash review-playbook.sh > REVIEW.md
# ============================================================================

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

section() { printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  %s${NC}\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n" "$*"; }
subsect() { printf "  ${CYAN}── %s ──${NC}\n\n" "$*"; }
warn()    { printf "  ${RED}⚠  %s${NC}\n" "$*"; }
note()    { printf "  ${DIM}%s${NC}\n" "$*"; }
show()    { printf "  ${GREEN}→${NC} %s\n" "$*"; }
indent()  { sed 's/^/    /'; }

# ── Check we're in the right directory ──────────────────────────────────────
if [[ ! -f site.yml ]]; then
    echo "Error: run this from the ansible-rebuild/ directory." >&2
    exit 1
fi

section "PLAYBOOK REVIEW — $(date -Idate)"

# ============================================================================
section "1. INVENTORY — Who is this deploying to?"
# ============================================================================

echo "  File: inventory/hosts.ini"
echo ""
cat inventory/hosts.ini 2>/dev/null | indent
echo ""

# ============================================================================
section "2. VARIABLES — What controls the playbook?"
# ============================================================================

subsect "group_vars/rebuild.yml (takes precedence over role defaults)"
cat group_vars/rebuild.yml 2>/dev/null | indent
echo ""

# Show role defaults that aren't overridden
for role_dir in roles/*/; do
    role=$(basename "$role_dir")
    if [[ -f "$role_dir/defaults/main.yml" ]]; then
        subsect "Role defaults: $role"
        cat "$role_dir/defaults/main.yml" | indent
        echo ""
    fi
done

# ============================================================================
section "3. EXECUTION ORDER — What runs and when?"
# ============================================================================

note "Roles execute in this order (from site.yml):"
echo ""
grep 'role:' site.yml 2>/dev/null | sed 's/.*role: //' | sed 's/,.*//' | \
    awk '{printf "  %d. %s\n", NR, $0}'
echo ""

# For each role, show its tasks
for role_dir in roles/*/; do
    role=$(basename "$role_dir")
    if [[ -f "$role_dir/tasks/main.yml" ]]; then
        subsect "Tasks in role: $role"

        # Extract task names and conditions
        awk '
        /^- name:/ {
            name = $0; sub(/^- name: */, "", name); gsub(/"/, "", name)
            printf "  → %s\n", name
        }
        /^  when:/ {
            cond = $0; sub(/^  when: */, "", cond)
            printf "      when: %s\n", cond
        }
        ' "$role_dir/tasks/main.yml" 2>/dev/null

        # Also show included task files
        for extra in "$role_dir"/tasks/*.yml; do
            [[ "$(basename "$extra")" == "main.yml" ]] && continue
            [[ -f "$extra" ]] || continue
            echo ""
            note "  ↳ included: $(basename "$extra")"
            awk '
            /^- name:/ {
                name = $0; sub(/^- name: */, "", name); gsub(/"/, "", name)
                printf "    → %s\n", name
            }
            ' "$extra" 2>/dev/null
        done
        echo ""
    fi
done

# ============================================================================
section "4. PACKAGES — What gets installed?"
# ============================================================================

if [[ -f roles/base-packages/defaults/main.yml ]]; then
    subsect "APT packages (from apt-mark showmanual on old server)"
    grep '^ *- ' roles/base-packages/defaults/main.yml | sort | indent
    echo ""
    count=$(grep -c '^ *- ' roles/base-packages/defaults/main.yml 2>/dev/null || echo 0)
    show "$count packages in the list"
    echo ""
fi

# ============================================================================
section "5. USERS — Who gets created?"
# ============================================================================

if [[ -f roles/users/defaults/main.yml ]]; then
    subsect "Managed users"
    awk '/^  - name:/{name=$3} /uid:/{uid=$2} /shell:/{printf "  → %-16s UID=%-6s shell=%s\n", name, uid, $2}' \
        roles/users/defaults/main.yml 2>/dev/null
    echo ""
fi

subsect "SSH authorized_keys to deploy"
for f in roles/users/files/*_authorized_keys 2>/dev/null; do
    [[ -f "$f" ]] || continue
    user=$(basename "$f" | sed 's/_authorized_keys//')
    keys=$(wc -l < "$f")
    show "$user: $keys key(s)"
done
echo ""

subsect "sudoers.d files from old server"
if ls roles/users/files/sudoers.d/* &>/dev/null; then
    for f in roles/users/files/sudoers.d/*; do
        warn "$(basename "$f"):"
        cat "$f" | indent
    done
    echo ""
    note "These are ONLY deployed if deploy_old_sudoers: true (default: false)"
else
    show "None collected"
fi
echo ""

# ============================================================================
section "6. FIREWALL — What rules get applied?"
# ============================================================================

if [[ -f roles/firewall/defaults/main.yml ]]; then
    subsect "UFW rules"
    awk '/ufw_default_incoming/{printf "  Default incoming: %s\n", $2}
         /ufw_default_outgoing/{printf "  Default outgoing: %s\n", $2}' \
        roles/firewall/defaults/main.yml 2>/dev/null
    echo ""
    grep '^ *- {' roles/firewall/defaults/main.yml 2>/dev/null | indent
    echo ""
fi

# ============================================================================
section "7. DOCKER — What compose projects get deployed?"
# ============================================================================

if [[ -f roles/docker/defaults/main.yml ]]; then
    subsect "Compose project directories"
    grep '^ *- ' roles/docker/defaults/main.yml 2>/dev/null | indent
    echo ""
fi

subsect "Compose files available in role"
for f in roles/docker/files/*.yml 2>/dev/null; do
    [[ -f "$f" ]] || continue
    show "$(basename "$f")"
done
if [[ -f roles/docker/files/daemon.json ]]; then
    echo ""
    subsect "Docker daemon.json"
    cat roles/docker/files/daemon.json | indent
fi
echo ""

# ============================================================================
section "8. VPN — What gets configured?"
# ============================================================================

if [[ -f roles/vpn/defaults/main.yml ]]; then
    cat roles/vpn/defaults/main.yml | indent
    echo ""
fi

if [[ -d roles/vpn/files/openvpn-old ]]; then
    subsect "OpenVPN configs from old server"
    find roles/vpn/files/openvpn-old -name '*.conf' 2>/dev/null | while read -r f; do
        show "$(basename "$f")"
        grep -E '^\s*(server|port|proto|dev|cipher|push|client-to-client)' "$f" 2>/dev/null | indent
    done
    echo ""
fi

if [[ -f roles/vpn/files/wireguard-migration-notes.txt ]]; then
    subsect "WireGuard migration notes"
    cat roles/vpn/files/wireguard-migration-notes.txt | indent
    echo ""
fi

# ============================================================================
section "9. CRON — What scheduled jobs get created?"
# ============================================================================

if [[ -f roles/cron/tasks/main.yml ]]; then
    awk '
    /^- name:/ {
        name = $0; sub(/^- name: */, "", name); gsub(/"/, "", name)
    }
    /job:/ {
        job = $0; sub(/^.*job: */, "", job); gsub(/"/, "", job)
        printf "  → %s\n    %s\n\n", name, job
    }
    ' roles/cron/tasks/main.yml 2>/dev/null
fi

# ============================================================================
section "10. SECURITY — What hardening gets applied?"
# ============================================================================

if [[ -f roles/security/defaults/main.yml ]]; then
    cat roles/security/defaults/main.yml | indent
    echo ""
fi

if [[ -f roles/users/templates/sshd_config.j2 ]]; then
    subsect "sshd_config from old server (DANGEROUS — opt-in only)"
    warn "This file is deployed ONLY if deploy_old_sshd_config: true"
    echo ""
    note "Key settings:"
    grep -iE '^\s*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|AllowGroups|Port|ListenAddress|UsePAM)' \
        roles/users/templates/sshd_config.j2 2>/dev/null | indent
    echo ""
fi

if [[ -d roles/security/files ]] && ls roles/security/files/jail.* &>/dev/null 2>&1; then
    subsect "fail2ban configuration"
    for f in roles/security/files/jail.*; do
        show "$(basename "$f")"
    done
    echo ""
fi

# ============================================================================
section "11. NETWORK — What gets configured?"
# ============================================================================

if [[ -d roles/networking/templates ]]; then
    for f in roles/networking/templates/*; do
        [[ -f "$f" ]] || continue
        subsect "Template: $(basename "$f")"
        cat "$f" | indent
        echo ""
    done
fi

# ============================================================================
section "SAFETY CHECKLIST"
# ============================================================================

echo ""
show "bootstrap_user is set and won't be modified by the users role"

# Check dangerous flags
if grep -q 'deploy_old_sudoers: true' group_vars/rebuild.yml 2>/dev/null; then
    warn "deploy_old_sudoers is TRUE — old sudoers.d/ will overwrite new server's"
else
    show "deploy_old_sudoers is false (safe default)"
fi

if grep -q 'deploy_old_sshd_config: true' group_vars/rebuild.yml 2>/dev/null; then
    warn "deploy_old_sshd_config is TRUE — old sshd_config will overwrite new server's"
else
    show "deploy_old_sshd_config is false (safe default)"
fi

echo ""

# Check if docker data needs rsync
compose_count=$(grep -c '^ *- /' roles/docker/defaults/main.yml 2>/dev/null || echo 0)
if [[ "$compose_count" -gt 0 ]]; then
    note "$compose_count Docker compose projects configured."
    note "Have you rsynced data dirs from the old server? (rsync -avHAX)"
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Review complete. Run the playbook when satisfied:${NC}"
echo -e "${BOLD}    ansible-playbook -i inventory/hosts.ini site.yml -K${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
