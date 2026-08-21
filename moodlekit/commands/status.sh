#!/usr/bin/env bash
# =============================================================================
# commands/status.sh — Server health, stack diagnostics & Moodle site status
# =============================================================================
# Works gracefully whether server is bootstrapped or not.
# Displays hardware, active services, encrypted vault state, and all detected sites.
# =============================================================================

cmd_status() {
    load_global_conf 0 || true
    
    section "MoodleKit — Server & Moodle Status"
    
    detect_hardware
    detect_installed
    
    echo ""
    echo -e "${C_BOLD}Hardware Overview:${C_RESET}"
    echo "  RAM:  ${RAM_TOTAL_GB}GB total (~${RAM_USABLE_GB}GB usable)"
    echo "  CPU:  ${CPU_CORES} cores"
    echo "  Disk: ${DISK_TYPE}"
    
    # Storage
    echo ""
    echo -e "${C_BOLD}Storage Usage:${C_RESET}"
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    echo "  Root (/): ${disk_usage} used"
    if [[ -d "/var/moodledata" ]]; then
        local data_usage
        data_usage=$(du -sh /var/moodledata 2>/dev/null | awk '{print $1}')
        echo "  Moodle Data (/var/moodledata): ${data_usage:-0}"
    fi
    
    # Services
    echo ""
    echo -e "${C_BOLD}Service Status:${C_RESET}"
    
    _check_service() {
        local svc="$1"
        local name="$2"
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo -e "  ${name}: ${C_BOLD_GREEN}active (running)${C_RESET}"
        elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            echo -e "  ${name}: ${C_BOLD_YELLOW}inactive / stopped${C_RESET}"
        elif command -v "${svc}" &>/dev/null; then
            echo -e "  ${name}: ${C_DIM}installed (not running)${C_RESET}"
        else
            echo -e "  ${name}: ${C_DIM}not installed${C_RESET}"
        fi
    }
    
    _check_service "nginx" "Nginx"
    
    # Check all PHP-FPM versions installed
    for pver in 8.4 8.3 8.2 8.1; do
        if command -v "php${pver}" &>/dev/null; then
            _check_service "php${pver}-fpm" "PHP-FPM ${pver}"
        fi
    done
    
    _check_service "postgresql" "PostgreSQL"
    _check_service "mariadb" "MariaDB"
    _check_service "mysql" "MySQL"
    _check_service "redis-server" "Redis"
    _check_service "memcached" "Memcached"
    _check_service "cron" "Cron"
    _check_service "fail2ban" "Fail2ban"
    _check_service "ufw" "Firewall (UFW)"
    
    # Encrypted Vault State
    echo ""
    echo -e "${C_BOLD}Security & Vault:${C_RESET}"
    if [[ -f "/etc/moodlekit/vault.bin" ]]; then
        local vault_stat
        vault_stat="$(python3 "${MOODLEKIT_LIB}/vault.py" status 2>/dev/null || echo "{}")"
        echo -e "  Encrypted Vault: ${C_BOLD_GREEN}active (/etc/moodlekit/vault.bin)${C_RESET}"
        echo -e "  Encryption:      AES-256-CBC + HMAC-SHA256 (PBKDF2 100k iter)"
        if [[ -f "/etc/moodlekit/.master.key" ]]; then
            echo -e "  Master Key:      ${C_BOLD_GREEN}present (0600 secure)${C_RESET}"
        fi
    else
        echo -e "  Encrypted Vault: ${C_DIM}not initialized yet${C_RESET}"
    fi

    # Managed Moodle Sites
    echo ""
    echo -e "${C_BOLD}Managed Moodle Sites:${C_RESET}"
    local sites_count=0
    local slugs=()
    while IFS= read -r slug; do
        [[ -n "${slug}" ]] && slugs+=("${slug}")
    done < <(list_site_slugs)
    
    sites_count="${#slugs[@]}"
    if [[ "${sites_count}" -gt 0 ]]; then
        echo -e "  Total registered sites: ${C_BOLD_CYAN}${sites_count}${C_RESET}"
        for s in "${slugs[@]}"; do
            local s_domain s_ver s_type
            s_domain="$(python3 "${MOODLEKIT_LIB}/vault.py" sget "${s}" 2>/dev/null | jq -r '.domain // "unknown"' 2>/dev/null || echo "legacy")"
            s_ver="$(python3 "${MOODLEKIT_LIB}/vault.py" sget "${s}" 2>/dev/null | jq -r '.moodle_version // "unknown"' 2>/dev/null || echo "")"
            s_type="$(python3 "${MOODLEKIT_LIB}/vault.py" sget "${s}" 2>/dev/null | jq -r '.type // "managed"' 2>/dev/null || echo "site")"
            echo -e "    • ${C_BOLD}${s}${C_RESET} (${s_domain}) — Moodle ${s_ver} [${s_type}]"
        done
    else
        echo -e "  ${C_DIM}No managed sites registered in MoodleKit vault.${C_RESET}"
    fi
    
    # Auto-detected unmanaged Moodle installations
    local unmanaged_sites=()
    while IFS= read -r mdir; do
        [[ -z "${mdir}" ]] && continue
        # Check if already managed
        local already_managed=0
        for s in "${slugs[@]}"; do
            local s_dir
            s_dir="$(python3 "${MOODLEKIT_LIB}/vault.py" sget "${s}" 2>/dev/null | jq -r '.moodle_dir // ""' 2>/dev/null || echo "")"
            if [[ "${s_dir}" == "${mdir}" ]]; then
                already_managed=1
                break
            fi
        done
        if [[ "${already_managed}" -eq 0 ]]; then
            unmanaged_sites+=("${mdir}")
        fi
    done < <(find_moodle_installations 2>/dev/null)

    if [[ ${#unmanaged_sites[@]} -gt 0 ]]; then
        echo ""
        echo -e "${C_BOLD_YELLOW}Discovered Unmanaged Moodle Installations:${C_RESET}"
        for u in "${unmanaged_sites[@]}"; do
            local u_ver="unknown"
            if [[ -f "${u}/version.php" ]]; then
                u_ver=$(grep -E '^\$release\s*=' "${u}/version.php" 2>/dev/null | head -1 | cut -d"'" -f2 || echo "unknown")
            fi
            echo -e "  ⚠  ${u} (${u_ver})"
            echo -e "     ${C_DIM}→ To manage/fix/backup this site, run: moodlekit adopt \"${u}\"${C_RESET}"
        done
    fi

    # Backup status
    echo ""
    echo -e "${C_BOLD}Cloud Backup & Automation:${C_RESET}"
    if systemctl is-active --quiet moodlekit-backup.timer 2>/dev/null; then
        local next_run
        next_run=$(systemctl list-timers moodlekit-backup.timer 2>/dev/null | awk 'NR==2 {print $1, $2}')
        echo -e "  Cloud Backup Timer: ${C_BOLD_GREEN}active${C_RESET} (next run: ${next_run})"
    else
        echo -e "  Cloud Backup Timer: ${C_DIM}inactive${C_RESET} (run 'moodlekit backup deploy' to enable)"
    fi
}
