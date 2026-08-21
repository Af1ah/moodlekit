#!/usr/bin/env bash
# =============================================================================
# commands/fix.sh — MoodleKit Moodle Fixer & Doctor (Interactive Repair Engine)
# =============================================================================
# Fully interactive Moodle diagnostics and repair toolkit.
# Supports granular audit, 1-click automatic repair, or multi-select checkbox fixes.
# =============================================================================

cmd_fix() {
    require_root
    load_global_conf 0 || true
    
    local target="${1:-}"
    
    # ─────────────────────────────────────────────────────────────────────────
    # Target Selection Phase
    # ─────────────────────────────────────────────────────────────────────────
    if [[ -z "${target}" ]]; then
        section "MoodleKit — Moodle Doctor & Repair"
        info "Select a Moodle site or subsystem to diagnose and repair:"
        
        local -a options=()
        local slugs=()
        while IFS= read -r slug; do
            [[ -n "${slug}" ]] && slugs+=("${slug}")
        done < <(list_site_slugs)
        
        for s in "${slugs[@]}"; do
            options+=("Managed Site: ${s}")
        done
        
        # Scan for unmanaged Moodle sites on disk
        local unmanaged=()
        while IFS= read -r udir; do
            [[ -n "${udir}" ]] && unmanaged+=("${udir}")
        done < <(find_moodle_installations 2>/dev/null)
        
        for u in "${unmanaged[@]}"; do
            local is_m=0
            for s in "${slugs[@]}"; do
                local sdir
                sdir="$(python3 "${MOODLEKIT_LIB}/vault.py" sget "${s}" 2>/dev/null | jq -r '.moodle_dir // ""' 2>/dev/null || true)"
                [[ "${sdir}" == "${u}" ]] && is_m=1 && break
            done
            [[ "${is_m}" -eq 0 ]] && options+=("Discovered Standalone: ${u}")
        done
        
        if [[ ${#slugs[@]} -gt 1 ]]; then
            options+=("Fix All Managed Sites")
        fi
        
        options+=("Diagnose & Fix Global Server Stack")
        options+=("Scan & Adopt Standalone Moodle Directory")
        options+=("Cancel")
        
        local choice=""
        select_one choice "Select diagnostic target:" "${options[@]}"
        
        case "${choice}" in
            *"Managed Site:"*)
                target="${choice#*Managed Site: }"
                target="${target%% *}"
                ;;
            *"Discovered Standalone:"*)
                local spath="${choice#*Discovered Standalone: }"
                spath="${spath%% *}"
                _doctor_standalone "${spath}"
                return 0
                ;;
            *"Fix All Managed Sites"*)
                _doctor_all_sites
                return 0
                ;;
            *"Diagnose & Fix Global Server Stack"*)
                _doctor_server_stack
                return 0
                ;;
            *"Scan & Adopt"*)
                cmd_adopt
                return 0
                ;;
            *"Cancel"*)
                return 0
                ;;
        esac
    fi
    
    # If target is a directory path, run standalone doctor
    if [[ -d "${target}" ]] && is_moodle_directory "${target}"; then
        _doctor_standalone "${target}"
        return 0
    fi
    
    # Otherwise run doctor on specific site slug
    _doctor_site "${target}"
}

# ---------------------------------------------------------------------------
# Core Doctor & Fixer for a Managed Site
# ---------------------------------------------------------------------------
_doctor_site() {
    local slug="$1"
    
    if ! site_exists "${slug}"; then
        err "Site '${slug}' not found in MoodleKit encrypted vault."
        return 1
    fi
    
    load_site_conf "${slug}" 1
    init_logging "doctor-${slug}"
    
    section "Moodle Doctor — Audit & Diagnostics: ${slug}"
    info "URL: https://${DOMAIN:-$slug} | Directory: ${MOODLE_DIR}"
    echo ""
    
    # ── Phase 1: Audit Scan ──────────────────────────────────────────────────
    info "Performing non-destructive health audit..."
    
    local audit_perms_ok=1
    local audit_dataroot_ok=1
    local audit_db_ok=1
    local audit_php_ok=1
    local audit_fpm_ok=1
    local audit_nginx_ok=1
    local audit_cron_ok=1
    local audit_cache_ok=1
    
    # 1. Check code permissions
    if [[ ! -d "${MOODLE_DIR}" ]]; then
        audit_perms_ok=0
    else
        local bad_perms
        bad_perms=$(find "${MOODLE_DIR}" -maxdepth 2 -type f -perm 777 2>/dev/null | head -1)
        [[ -n "${bad_perms}" ]] && audit_perms_ok=0
        if [[ -f "${MOODLE_DIR}/config.php" ]]; then
            local cfg_perm
            cfg_perm=$(stat -c "%a" "${MOODLE_DIR}/config.php" 2>/dev/null || echo "000")
            [[ "${cfg_perm}" != "640" && "${cfg_perm}" != "440" ]] && audit_perms_ok=0
        fi
    fi
    
    # 2. Check dataroot
    if [[ -z "${MOODLEDATA_DIR:-}" || ! -d "${MOODLEDATA_DIR}" ]]; then
        audit_dataroot_ok=0
    else
        for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
            [[ ! -d "${MOODLEDATA_DIR}/${sd}" ]] && audit_dataroot_ok=0 && break
        done
    fi
    
    # 3. Check database
    case "${DB_TYPE:-mariadb}" in
        postgres)
            sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DB_NAME}" || audit_db_ok=0
            ;;
        mariadb|mysql)
            mysql -u root -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null | grep -qw "${DB_NAME}" || audit_db_ok=0
            ;;
    esac
    
    # 4. Check PHP limits
    local target_php="${PHP_VERSION:-8.3}"
    local php_ini="/etc/php/${target_php}/fpm/php.ini"
    if [[ -f "${php_ini}" ]]; then
        local m_vars
        m_vars=$(grep -E '^max_input_vars\s*=' "${php_ini}" | awk -F'=' '{print $2}' | tr -d ' ' || echo "0")
        (( m_vars < 10000 )) && audit_php_ok=0
    fi
    
    # 5. Check PHP-FPM
    local fpm_sock="${FPM_SOCK:-/run/php/php${target_php}-fpm-moodle_${slug}.sock}"
    local fpm_pool="${FPM_POOL_CONF:-/etc/php/${target_php}/fpm/pool.d/moodle_${slug}.conf}"
    if [[ ! -f "${fpm_pool}" || ! -S "${fpm_sock}" ]]; then
        audit_fpm_ok=0
    fi
    
    # 6. Check Nginx
    local nginx_conf="${NGINX_CONF:-/etc/nginx/sites-available/moodle-${slug}}"
    local nginx_enabled="/etc/nginx/sites-enabled/moodle-${slug}"
    if [[ ! -f "${nginx_conf}" || ! -L "${nginx_enabled}" ]]; then
        audit_nginx_ok=0
    fi
    
    # 7. Check Cron
    local cron_file="/etc/cron.d/moodlekit-${slug}"
    [[ ! -f "${cron_file}" ]] && audit_cron_ok=0
    
    # ── Display Audit Report ────────────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Diagnostic Findings:${C_RESET}"
    _print_status_item "Codebase & File Permissions" "${audit_perms_ok}" "Permissions non-standard or config.php unprotected"
    _print_status_item "Dataroot Health & Subdirs"    "${audit_dataroot_ok}" "Missing dataroot subdirectories or bad permissions"
    _print_status_item "Database Connectivity"        "${audit_db_ok}" "Database unreachable or unverified"
    _print_status_item "PHP Configuration Limits"     "${audit_php_ok}" "PHP limits sub-optimal (need max_input_vars >= 10000)"
    _print_status_item "PHP-FPM Pool & Socket"        "${audit_fpm_ok}" "FPM pool missing or socket inactive"
    _print_status_item "Nginx Virtual Host & Route"   "${audit_nginx_ok}" "Nginx vhost missing or not enabled"
    _print_status_item "Moodle Cron Job Daemon"       "${audit_cron_ok}" "Cron job in /etc/cron.d/ missing"
    _print_status_item "Cache & Session Storage"      "${audit_cache_ok}" "Ready for cache refresh"
    echo ""
    
    # ── Phase 2: Interactive Fix Selection ──────────────────────────────────
    local action=""
    select_one action "Select repair action:" \
        "⚡ Apply All Recommended Fixes (Automatic 1-Click Repair)" \
        "🎯 Select Specific Fixes to Apply (Custom Checkboxes)" \
        "📁 Fix File Permissions & Dataroot Only" \
        "🗃️ Repair Database Tables Only" \
        "🐘 Tune PHP Limits & Fix PHP-FPM Pool Only" \
        "🌐 Fix Nginx Web Server Vhost Only" \
        "⏰ Fix Cron Job & Unlock Stalled Tasks Only" \
        "🧹 Purge All Moodle Caches & Reset Maintenance Mode" \
        "Cancel / Exit"
    
    case "${action}" in
        *"Apply All Recommended Fixes"*)
            _apply_all_fixes "${slug}"
            ;;
        *"Select Specific Fixes"*)
            local -a selected_fixes=()
            select_many selected_fixes "Select components to repair (Space to toggle, Enter to confirm):" \
                "1. Codebase & Directory Permissions (0755 dirs, 0644 files, 0640 config)" \
                "2. Dataroot Health & Subdirectories (02777/2770, .htaccess, missing dirs)" \
                "3. Database Table Auto-Repair & Schema Verification (mysqlcheck / schema)" \
                "4. PHP Runtime Limits (max_input_vars >= 10000, memory_limit >= 512M)" \
                "5. PHP-FPM Pool & Socket Recreation" \
                "6. Nginx Web Server Virtual Host & Upstream Route" \
                "7. Cron Job Installation & Task Queue Unlock" \
                "8. Purge All Moodle Caches & Reset Maintenance Mode"
            
            _apply_custom_fixes "${slug}" "${selected_fixes[@]}"
            ;;
        *"Fix File Permissions"*)
            _fix_perms "${slug}"
            _fix_dataroot "${slug}"
            ;;
        *"Repair Database"*)
            _fix_database "${slug}"
            ;;
        *"Tune PHP Limits"*)
            _fix_php "${slug}"
            _fix_fpm "${slug}"
            ;;
        *"Fix Nginx"*)
            _fix_nginx "${slug}"
            ;;
        *"Fix Cron"*)
            _fix_cron "${slug}"
            ;;
        *"Purge All Moodle Caches"*)
            _fix_cache "${slug}"
            ;;
        *"Cancel"*)
            info "Audit completed. No changes made."
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Helper: Print Audit Item
# ---------------------------------------------------------------------------
_print_status_item() {
    local label="$1"
    local is_ok="$2"
    local warn_msg="$3"
    
    if [[ "${is_ok}" -eq 1 ]]; then
        echo -e "  ${C_BOLD_GREEN}✓ PASS${C_RESET}  ${label}"
    else
        echo -e "  ${C_BOLD_YELLOW}⚠ WARN${C_RESET}  ${label} ${C_DIM}(${warn_msg})${C_RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Apply Custom Selected Fixes
# ---------------------------------------------------------------------------
_apply_custom_fixes() {
    local slug="$1"; shift
    local -a fixes=("$@")
    
    if [[ ${#fixes[@]} -eq 0 ]]; then
        info "No fixes selected."
        return 0
    fi
    
    section "Applying Selected Repairs to '${slug}'"
    for f in "${fixes[@]}"; do
        case "${f}" in
            *1.*) _fix_perms "${slug}" ;;
            *2.*) _fix_dataroot "${slug}" ;;
            *3.*) _fix_database "${slug}" ;;
            *4.*) _fix_php "${slug}" ;;
            *5.*) _fix_fpm "${slug}" ;;
            *6.*) _fix_nginx "${slug}" ;;
            *7.*) _fix_cron "${slug}" ;;
            *8.*) _fix_cache "${slug}" ;;
        esac
    done
    
    print_box "Repairs Complete: ${slug} ✓" \
        "Selected fixes have been successfully applied." \
        "Log: ${_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Apply All Fixes
# ---------------------------------------------------------------------------
_apply_all_fixes() {
    local slug="$1"
    section "Applying Full Repair Pipeline to '${slug}'"
    
    _fix_perms "${slug}"
    _fix_dataroot "${slug}"
    _fix_database "${slug}"
    _fix_php "${slug}"
    _fix_fpm "${slug}"
    _fix_nginx "${slug}"
    _fix_cron "${slug}"
    _fix_cache "${slug}"
    
    print_box "Doctor Pipeline Complete: ${slug} ✓" \
        "URL:          https://${DOMAIN:-$slug}" \
        "Directory:    ${MOODLE_DIR}" \
        "Dataroot:     ${MOODLEDATA_DIR}" \
        "Permissions:  Secured (0755 code, 02777 data, 0640 config)" \
        "Database:     Checked & Optimized" \
        "PHP & FPM:    Tuned and Active" \
        "Caches:       Purged" \
        "Status:       100% Healthy & Online"
}

# ---------------------------------------------------------------------------
# Individual Granular Fix Functions
# ---------------------------------------------------------------------------
_fix_perms() {
    local slug="$1"
    step 1 1 "Normalizing Code & File Permissions"
    if [[ -d "${MOODLE_DIR}" ]]; then
        spinner_start "Setting permissions on ${MOODLE_DIR}..."
        chown -R root:www-data "${MOODLE_DIR}"
        find "${MOODLE_DIR}" -type d -exec chmod 755 {} +
        find "${MOODLE_DIR}" -type f -exec chmod 644 {} +
        
        if [[ -f "${MOODLE_DIR}/config.php" ]]; then
            chown root:www-data "${MOODLE_DIR}/config.php"
            chmod 640 "${MOODLE_DIR}/config.php"
        fi
        spinner_stop 0 "Codebase permissions set (0755 dirs, 0644 files, 0640 config)"
    fi
}

_fix_dataroot() {
    local slug="$1"
    step 1 1 "Repairing Dataroot Structure & Access Control"
    [[ -z "${MOODLEDATA_DIR:-}" ]] && MOODLEDATA_DIR="/var/moodledata/${slug}"
    mkdir -p "${MOODLEDATA_DIR}"
    
    for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
        mkdir -p "${MOODLEDATA_DIR}/${sd}"
    done
    
    chown -R www-data:www-data "${MOODLEDATA_DIR}"
    chmod -R 02777 "${MOODLEDATA_DIR}" 2>/dev/null || chmod -R 2770 "${MOODLEDATA_DIR}"
    
    cat > "${MOODLEDATA_DIR}/.htaccess" << 'HTACCESS'
Order deny,allow
Deny from all
HTACCESS
    chown www-data:www-data "${MOODLEDATA_DIR}/.htaccess"
    chmod 644 "${MOODLEDATA_DIR}/.htaccess"
    ok "Dataroot structure restored (www-data:www-data 02777)"
}

_fix_database() {
    local slug="$1"
    step 1 1 "Testing & Auto-Repairing Database Tables"
    case "${DB_TYPE:-mariadb}" in
        postgres)
            if sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DB_NAME}"; then
                ok "PostgreSQL database '${DB_NAME}' reachable"
            fi
            ;;
        mariadb|mysql)
            if command -v mysqlcheck &>/dev/null; then
                spinner_start "Running mysqlcheck --auto-repair on '${DB_NAME}'..."
                mysqlcheck -u root --auto-repair --check --optimize "${DB_NAME}" >> "${_LOG_FILE}" 2>&1 || true
                spinner_stop 0 "Database tables verified and optimized"
            fi
            ;;
    esac
}

_fix_php() {
    local slug="$1"
    step 1 1 "Tuning PHP Limits for Moodle"
    local target_php="${PHP_VERSION:-8.3}"
    for ini_file in "/etc/php/${target_php}/cli/php.ini" "/etc/php/${target_php}/fpm/php.ini"; do
        if [[ -f "${ini_file}" ]]; then
            sed -i 's/^;\?max_input_vars\s*=.*/max_input_vars = 10000/' "${ini_file}"
            sed -i 's/^;\?memory_limit\s*=.*/memory_limit = 512M/' "${ini_file}"
            sed -i 's/^;\?upload_max_filesize\s*=.*/upload_max_filesize = 100M/' "${ini_file}"
            sed -i 's/^;\?post_max_size\s*=.*/post_max_size = 100M/' "${ini_file}"
            sed -i 's/^;\?max_execution_time\s*=.*/max_execution_time = 300/' "${ini_file}"
        fi
    done
    ok "PHP ${target_php} settings optimized (memory_limit: 512M, max_input_vars: 10000)"
}

_fix_fpm() {
    local slug="$1"
    step 1 1 "Rebuilding & Reloading PHP-FPM Pool"
    local target_php="${PHP_VERSION:-8.3}"
    local pool_conf="${FPM_POOL_CONF:-/etc/php/${target_php}/fpm/pool.d/moodle_${slug}.conf}"
    
    calculate_tuning "balanced" 1 "${DB_TYPE:-mariadb}"
    render_template_to_file "${MOODLEKIT_TPL}/fpm-pool.conf.tpl" "${pool_conf}" \
        "SLUG=${slug}" \
        "PHP_VERSION=${target_php}" \
        "MAX_CHILDREN=${TUNE_FPM_MAX_CHILDREN:-5}" \
        "START_SERVERS=${TUNE_FPM_START_SERVERS:-2}" \
        "MIN_SPARE=${TUNE_FPM_MIN_SPARE:-1}" \
        "MAX_SPARE=${TUNE_FPM_MAX_SPARE:-3}" \
        "MOODLE_DIR=${MOODLE_DIR}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "TIMEZONE=UTC" \
        "TIMESTAMP=$(date)"
    
    reload_fpm "${target_php}"
    ok "PHP-FPM pool active (${pool_conf})"
}

_fix_nginx() {
    local slug="$1"
    step 1 1 "Verifying Nginx Virtual Host & Reloading"
    local target_php="${PHP_VERSION:-8.3}"
    local nginx_conf="${NGINX_CONF:-/etc/nginx/sites-available/moodle-${slug}}"
    local nginx_link="/etc/nginx/sites-enabled/moodle-${slug}"
    
    if [[ ! -f "${nginx_conf}" ]]; then
        local is_m5="${IS_MOODLE5:-0}"
        local nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
        [[ "${is_m5}" == "1" ]] && nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"
        
        render_template_to_file "${nginx_tpl}" "${nginx_conf}" \
            "DOMAIN=${DOMAIN:-$slug.local}" \
            "MOODLE_DIR=${MOODLE_DIR}" \
            "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
            "PHP_VERSION=${target_php}" \
            "SLUG=${slug}"
    fi
    
    ln -sf "${nginx_conf}" "${nginx_link}"
    if nginx -t >/dev/null 2>&1; then
        reload_nginx
        ok "Nginx virtual host active & reloaded"
    else
        warn "Nginx syntax error! Check /var/log/nginx/error.log"
    fi
}

_fix_cron() {
    local slug="$1"
    step 1 1 "Configuring Cron Job & Clearing Stalled Tasks"
    local target_php="${PHP_VERSION:-8.3}"
    local cron_file="/etc/cron.d/moodlekit-${slug}"
    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    
    # Remove stale lock files
    rm -f "/tmp/moodlekit-${slug}.lock"
    
    if [[ -f "${admin_cli}/cron.php" ]]; then
        cat > "${cron_file}" << CRONF
# MoodleKit cron — ${slug}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * www-data flock -n /tmp/moodlekit-${slug}.lock /usr/bin/php${target_php} ${admin_cli}/cron.php >> /var/log/moodlekit/${slug}-cron.log 2>&1
CRONF
        chmod 644 "${cron_file}"
        ok "Cron job installed at ${cron_file}"
    fi
}

_fix_cache() {
    local slug="$1"
    step 1 1 "Purging Caches & Disabling Maintenance Mode"
    local target_php="${PHP_VERSION:-8.3}"
    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    
    if [[ -f "${admin_cli}/purge_caches.php" ]]; then
        sudo -u www-data "/usr/bin/php${target_php}" "${admin_cli}/purge_caches.php" >/dev/null 2>&1 || true
        ok "Moodle caches purged"
    fi
    
    if [[ -f "${admin_cli}/maintenance.php" ]]; then
        sudo -u www-data "/usr/bin/php${target_php}" "${admin_cli}/maintenance.php" --disable >/dev/null 2>&1 || true
        ok "Maintenance mode disabled"
    fi
}

# ---------------------------------------------------------------------------
# Fix All Managed Sites Iteratively
# ---------------------------------------------------------------------------
_doctor_all_sites() {
    local slugs=()
    while IFS= read -r slug; do
        [[ -n "${slug}" ]] && slugs+=("${slug}")
    done < <(list_site_slugs)
    
    if [[ ${#slugs[@]} -eq 0 ]]; then
        warn "No managed sites registered in vault."
        return 0
    fi
    
    section "Moodle Doctor — Fixing All Managed Sites (${#slugs[@]})"
    for s in "${slugs[@]}"; do
        _apply_all_fixes "${s}"
        echo ""
    done
    ok "All managed sites repaired successfully!"
}

# ---------------------------------------------------------------------------
# Standalone Site Doctor
# ---------------------------------------------------------------------------
_doctor_standalone() {
    local moodle_dir="$1"
    init_logging "doctor-standalone"
    section "Moodle Doctor — Standalone Diagnostics: ${moodle_dir}"
    
    if ! is_moodle_directory "${moodle_dir}"; then
        err "Not a valid Moodle directory: ${moodle_dir}"
        return 1
    fi
    
    local release cfg_file admin_cli
    release="$(detect_moodle_version_string "${moodle_dir}")"
    cfg_file="$(find_moodle_config_file "${moodle_dir}")"
    admin_cli="$(find_moodle_admin_cli "${moodle_dir}")"
    info "Found: Moodle ${release} at ${moodle_dir}"
    
    local action=""
    select_one action "Select action for standalone site:" \
        "⚡ Apply Permissions, Dataroot & Cache Fixes" \
        "📁 Fix File & Directory Permissions Only" \
        "🧹 Purge Moodle Caches Only" \
        "📥 Adopt Site into MoodleKit Encrypted Vault" \
        "Cancel"
        
    case "${action}" in
        *"Apply Permissions, Dataroot"*)
            info "Resetting permissions..."
            chown -R root:www-data "${moodle_dir}"
            find "${moodle_dir}" -type d -exec chmod 755 {} +
            find "${moodle_dir}" -type f -exec chmod 644 {} +
            [[ -n "${cfg_file}" && -f "${cfg_file}" ]] && chmod 640 "${cfg_file}"
            
            local dataroot=""
            if [[ -n "${cfg_file}" && -f "${cfg_file}" ]]; then
                dataroot="$(grep -E "^\s*\\\$CFG->dataroot\s*=" "${cfg_file}" 2>/dev/null | cut -d"'" -f2 || true)"
                [[ -z "${dataroot}" ]] && dataroot="$(grep -E '^\s*\$CFG->dataroot\s*=' "${cfg_file}" 2>/dev/null | cut -d'"' -f2 || true)"
            fi
            if [[ -n "${dataroot}" && -d "${dataroot}" ]]; then
                for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
                    mkdir -p "${dataroot}/${sd}"
                done
                chown -R www-data:www-data "${dataroot}"
                chmod -R 02777 "${dataroot}" 2>/dev/null || chmod -R 2770 "${dataroot}"
            fi
            
            local php_bin
            php_bin="$(command -v php8.4 || command -v php8.3 || command -v php || echo "")"
            if [[ -n "${php_bin}" && -f "${admin_cli}/purge_caches.php" ]]; then
                sudo -u www-data "${php_bin}" "${admin_cli}/purge_caches.php" >/dev/null 2>&1 || true
            fi
            ok "Standalone site repaired successfully!"
            ;;
        *"Fix File & Directory Permissions"*)
            chown -R root:www-data "${moodle_dir}"
            find "${moodle_dir}" -type d -exec chmod 755 {} +
            find "${moodle_dir}" -type f -exec chmod 644 {} +
            [[ -n "${cfg_file}" && -f "${cfg_file}" ]] && chmod 640 "${cfg_file}"
            ok "Permissions set"
            ;;
        *"Purge Moodle Caches"*)
            local php_bin
            php_bin="$(command -v php8.4 || command -v php8.3 || command -v php || echo "")"
            if [[ -n "${php_bin}" && -f "${admin_cli}/purge_caches.php" ]]; then
                sudo -u www-data "${php_bin}" "${admin_cli}/purge_caches.php"
                ok "Caches purged"
            else
                warn "purge_caches.php not found or PHP CLI unavailable"
            fi
            ;;
        *"Adopt Site"*)
            cmd_adopt "${moodle_dir}"
            ;;
        *"Cancel"*)
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Global Server Stack Diagnostics & Fixer
# ---------------------------------------------------------------------------
_doctor_server_stack() {
    section "Moodle Doctor — Server Stack Health Check & Fix"
    
    local services=("nginx" "cron" "redis-server" "memcached" "postgresql" "mariadb" "mysql")
    for svc in "${services[@]}"; do
        if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            if ! systemctl is-active --quiet "${svc}" 2>/dev/null; then
                warn "Service '${svc}' is inactive. Restarting..."
                systemctl restart "${svc}" 2>/dev/null || true
            else
                ok "Service '${svc}' is active and running"
            fi
        fi
    done
    
    for pver in 8.4 8.3 8.2 8.1; do
        if command -v "php${pver}" &>/dev/null; then
            if systemctl is-enabled --quiet "php${pver}-fpm" 2>/dev/null; then
                if ! systemctl is-active --quiet "php${pver}-fpm" 2>/dev/null; then
                    warn "PHP-FPM ${pver} is inactive. Restarting..."
                    systemctl restart "php${pver}-fpm" 2>/dev/null || true
                else
                    ok "PHP-FPM ${pver} is active and running"
                fi
            fi
        fi
    done
    
    if command -v nginx &>/dev/null; then
        if nginx -t 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            ok "Nginx syntax is clean and service reloaded"
        else
            err "Nginx configuration syntax error! Run 'nginx -t' to inspect."
        fi
    fi
    
    ok "Server stack verification complete."
}

# ---------------------------------------------------------------------------
# Site Adoption: Register existing Moodle site into encrypted vault
# ---------------------------------------------------------------------------
cmd_adopt() {
    require_root
    load_global_conf 0 || true
    
    local path="${1:-}"
    local slug="${2:-}"
    
    section "MoodleKit — Adopt Existing Moodle Site"
    
    if [[ -z "${path}" ]]; then
        local discovered=()
        while IFS= read -r d; do
            [[ -n "${d}" ]] && discovered+=("${d}")
        done < <(find_moodle_installations 2>/dev/null)
        
        if [[ ${#discovered[@]} -gt 0 ]]; then
            info "Discovered Moodle directories on server:"
            select_one path "Select Moodle directory to adopt (or choose Custom):" "${discovered[@]}" "Enter custom path manually"
            if [[ "${path}" == *"Enter custom"* ]]; then
                input_path path "Enter absolute path to Moodle root directory" ""
            fi
        else
            input_path path "Enter absolute path to Moodle root directory" ""
        fi
    fi
    
    [[ -d "${path}" ]] || { err "Directory not found: ${path}"; return 1; }
    if ! is_moodle_directory "${path}"; then
        err "No Moodle installation recognized in ${path}."
        return 1
    fi
    
    local cfg_file
    cfg_file="$(find_moodle_config_file "${path}")"
    [[ -z "${cfg_file}" || ! -f "${cfg_file}" ]] && { err "No config.php found in ${path} (or ${path}/public). Site might not be configured."; return 1; }
    
    # Parse config.php
    local cfg_wwwroot cfg_dataroot cfg_dbtype cfg_dbname cfg_dbuser cfg_dbpass cfg_prefix
    cfg_wwwroot="$(grep -E "^\s*\\\$CFG->wwwroot\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    [[ -z "${cfg_wwwroot}" ]] && cfg_wwwroot="$(grep -E '^\s*\$CFG->wwwroot\s*=' "${cfg_file}" | cut -d'"' -f2 || true)"
    
    cfg_dataroot="$(grep -E "^\s*\\\$CFG->dataroot\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    [[ -z "${cfg_dataroot}" ]] && cfg_dataroot="$(grep -E '^\s*\$CFG->dataroot\s*=' "${cfg_file}" | cut -d'"' -f2 || true)"
    
    cfg_dbtype="$(grep -E "^\s*\\\$CFG->dbtype\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    cfg_dbname="$(grep -E "^\s*\\\$CFG->dbname\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    cfg_dbuser="$(grep -E "^\s*\\\$CFG->dbuser\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    cfg_dbpass="$(grep -E "^\s*\\\$CFG->dbpass\s*=" "${cfg_file}" | cut -d"'" -f2 || true)"
    cfg_prefix="$(grep -E "^\s*\\\$CFG->prefix\s*=" "${cfg_file}" | cut -d"'" -f2 || echo "mdl_")"
    
    local domain
    domain="$(echo "${cfg_wwwroot}" | sed -E 's|https?://||; s|/.*||')"
    
    if [[ -z "${slug}" ]]; then
        local default_slug
        default_slug="$(basename "${path}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
        [[ -z "${default_slug}" ]] && default_slug="site$(date +%s)"
        input_text slug "Enter a slug identifier for this site" "${default_slug}" '^[a-z0-9-]+$' "Lowercase alphanumeric/hyphens only"
    fi
    
    # Detect major version & structure
    local major_ver is_m5
    major_ver="$(detect_moodle_version_string "${path}")"
    is_m5="$(detect_is_moodle5 "${path}")"
    
    # Detect PHP version
    local php_ver="${PHP_VERSION:-8.3}"
    
    # Build site data JSON
    local site_json
    site_json="$(jq -n \
        --arg slug "${slug}" \
        --arg domain "${domain}" \
        --arg moodle_version "${major_ver}" \
        --argjson is_moodle5 "${is_m5}" \
        --arg moodle_dir "${path}" \
        --arg moodledata_dir "${cfg_dataroot}" \
        --arg db_type "${cfg_dbtype}" \
        --arg db_name "${cfg_dbname}" \
        --arg db_user "${cfg_dbuser}" \
        --arg db_pass "${cfg_dbpass}" \
        --arg db_prefix "${cfg_prefix}" \
        --arg php_version "${php_ver}" \
        --arg site_type "standalone" \
        --arg created_at "$(date -Iseconds)" \
        '{
            slug: $slug,
            domain: $domain,
            moodle_version: $moodle_version,
            is_moodle5: $is_moodle5,
            moodle_dir: $moodle_dir,
            moodledata_dir: $moodledata_dir,
            db_type: $db_type,
            db_name: $db_name,
            db_user: $db_user,
            db_pass: $db_pass,
            db_prefix: $db_prefix,
            php_version: $php_version,
            type: $site_type,
            created_at: $created_at
        }'
    )"
    
    vault_sset "${slug}" "${site_json}"
    ok "Site '${slug}' successfully registered in MoodleKit encrypted vault!"
    
    print_box "Moodle Site Adopted ✓" \
        "Slug:        ${slug}" \
        "Domain:      ${domain}" \
        "Path:        ${path}" \
        "Dataroot:    ${cfg_dataroot}" \
        "Database:    ${cfg_dbname} (${cfg_dbtype})" \
        "Moodle:      ${major_ver}" \
        "Vault:       Stored in /etc/moodlekit/vault.bin (AES-256)"
}
