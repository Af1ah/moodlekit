#!/usr/bin/env bash
# =============================================================================
# commands/status.sh — Server health check
# =============================================================================

cmd_status() {
    require_root
    load_global_conf
    
    section "MoodleKit — Server Status"
    
    detect_hardware
    
    echo -e "${C_BOLD}Hardware:${C_RESET}"
    echo "  RAM:  ${RAM_TOTAL_GB}GB"
    echo "  CPU:  ${CPU_CORES} cores"
    echo "  Disk: ${DISK_TYPE}"
    
    # Storage
    echo ""
    echo -e "${C_BOLD}Storage:${C_RESET}"
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    echo "  Root (/): ${disk_usage} used"
    if [[ -d "/var/moodledata" ]]; then
        local data_usage
        data_usage=$(du -sh /var/moodledata 2>/dev/null | awk '{print $1}')
        echo "  Moodle Data: ${data_usage:-0}"
    fi
    
    # Services
    echo ""
    echo -e "${C_BOLD}Services:${C_RESET}"
    
    _check_service() {
        local svc="$1"
        local name="$2"
        if systemctl is-active --quiet "${svc}"; then
            echo -e "  ${name}: ${C_BOLD_GREEN}active${C_RESET}"
        else
            echo -e "  ${name}: ${C_BOLD_RED}inactive or failed${C_RESET}"
        fi
    }
    
    _check_service "nginx" "Nginx"
    _check_service "php${PHP_VERSION}-fpm" "PHP-FPM (${PHP_VERSION})"
    
    case "${DB_TYPE}" in
        postgres) _check_service "postgresql" "PostgreSQL" ;;
        mariadb)  _check_service "mariadb" "MariaDB" ;;
        mysql)    _check_service "mysql" "MySQL" ;;
    esac
    
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        _check_service "redis-server" "Redis"
    fi
    
    if [[ "${USE_MEMCACHED:-0}" == "1" ]]; then
        _check_service "memcached" "Memcached"
    fi
    
    _check_service "cron" "Cron"
    _check_service "ufw" "Firewall (UFW)"
    _check_service "fail2ban" "Fail2ban"
    
    # Active sites
    echo ""
    echo -e "${C_BOLD}Managed Sites:${C_RESET}"
    local sites_count
    sites_count=$(list_site_slugs | wc -l)
    echo "  Total: ${sites_count}"
    
    # Backup status
    echo ""
    echo -e "${C_BOLD}Backups:${C_RESET}"
    if systemctl is-active --quiet moodlekit-backup.timer; then
        local next_run
        next_run=$(systemctl list-timers moodlekit-backup.timer | awk 'NR==2 {print $1, $2}')
        echo -e "  Cloud Backup: ${C_BOLD_GREEN}active${C_RESET} (next run: ${next_run})"
    else
        echo -e "  Cloud Backup: ${C_DIM}inactive${C_RESET} (run 'moodlekit backup deploy' to enable)"
    fi
}
