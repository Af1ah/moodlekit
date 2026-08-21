#!/usr/bin/env bash
# =============================================================================
# commands/bootstrap.sh — MoodleKit server bootstrap
# =============================================================================
# Installs and configures all shared infrastructure:
# PHP (8.1/8.3/8.4) + Nginx + Database (Pg/MariaDB/MySQL) + Redis/Memcached
# + Certbot + UFW + fail2ban
# Skips components that are already installed at a compatible version.
# =============================================================================

cmd_bootstrap() {
    require_root
    init_logging "bootstrap"
    acquire_lock "bootstrap"

    section "MoodleKit — Server Bootstrap v${MOODLEKIT_VERSION}"
    info "Host: $(hostname -f) | $(date)"
    echo ""

    detect_os
    detect_hardware
    detect_installed

    # Check if already bootstrapped
    if [[ -f "${MOODLEKIT_STATE_DIR}/.bootstrap_complete" ]]; then
        warn "This server was already bootstrapped."
        if ! confirm "Re-run bootstrap for tuning/fixing? (allows installing new PHP versions or re-tuning)" "n"; then
            info "Aborted."
            exit 0
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Interactive stack selection
    # ─────────────────────────────────────────────────────────────────────────
    section "Stack Selection"

    # PHP version
    local php_ver=""
    if [[ -n "${OPT_PHP:-}" ]]; then
        php_ver="${OPT_PHP}"
    elif [[ -n "${PHP_INSTALLED:-}" ]] && [[ "${MOODLEKIT_YES:-0}" == "1" ]]; then
        php_ver="${PHP_INSTALLED}"
        info "Auto-selected PHP ${php_ver} (already installed)"
    else
        local php_choice=""
        local prompt_msg="Select PHP version:"
        if [[ -n "${PHP_INSTALLED:-}" ]]; then
            prompt_msg="Select PHP version (Currently installed: ${PHP_INSTALLED}):"
        fi
        select_one php_choice "${prompt_msg}" \
            "PHP 8.4 (recommended for Moodle 5.2)" \
            "PHP 8.3 (Moodle 4.5 LTS + Moodle 5.2)" \
            "PHP 8.1 (Moodle 4.5 LTS only)" \
            "Keep Current (${PHP_INSTALLED:-None})"
        case "${php_choice}" in
            *8.4*) php_ver="8.4" ;;
            *8.3*) php_ver="8.3" ;;
            *8.1*) php_ver="8.1" ;;
            *Keep*) php_ver="${PHP_INSTALLED}" ;;
        esac
        # Fallback if Keep Current was selected but nothing installed
        [[ -z "${php_ver}" ]] && php_ver="8.4"
    fi

    # Database
    local db_type=""
    if [[ -n "${OPT_DB:-}" ]]; then
        db_type="${OPT_DB}"
    elif [[ -n "${POSTGRES_INSTALLED:-}" || -n "${MARIADB_INSTALLED:-}" || -n "${MYSQL_INSTALLED:-}" ]] && [[ "${MOODLEKIT_YES:-0}" == "1" ]]; then
        if [[ -n "${POSTGRES_INSTALLED:-}" ]]; then db_type="postgres"; info "Auto-selected PostgreSQL (already installed)";
        elif [[ -n "${MARIADB_INSTALLED:-}" ]]; then db_type="mariadb"; info "Auto-selected MariaDB (already installed)";
        elif [[ -n "${MYSQL_INSTALLED:-}" ]]; then db_type="mysql"; info "Auto-selected MySQL (already installed)"; fi
    else
        local db_installed_msg="None"
        if [[ -n "${POSTGRES_INSTALLED:-}" ]]; then db_installed_msg="PostgreSQL";
        elif [[ -n "${MARIADB_INSTALLED:-}" ]]; then db_installed_msg="MariaDB";
        elif [[ -n "${MYSQL_INSTALLED:-}" ]]; then db_installed_msg="MySQL"; fi

        local db_choice=""
        select_one db_choice "Select database engine (Currently installed: ${db_installed_msg}):" \
            "PostgreSQL 17 (recommended)" \
            "MariaDB 10.11+" \
            "MySQL 8.4" \
            "Keep Current (${db_installed_msg})"
        case "${db_choice}" in
            *PostgreSQL*) db_type="postgres" ;;
            *MariaDB*)    db_type="mariadb"  ;;
            *MySQL*)      db_type="mysql"    ;;
            *Keep*)
                if [[ "${db_installed_msg}" == "PostgreSQL" ]]; then db_type="postgres";
                elif [[ "${db_installed_msg}" == "MariaDB" ]]; then db_type="mariadb";
                elif [[ "${db_installed_msg}" == "MySQL" ]]; then db_type="mysql";
                else db_type="postgres"; fi
                ;;
        esac
    fi

    # Cache
    local use_redis=0 use_memcached=0
    if [[ -n "${OPT_CACHE:-}" ]]; then
        local cache_choices=()
        IFS=',' read -ra cache_choices <<< "${OPT_CACHE}"
        for c in "${cache_choices[@]}"; do
            [[ "${c}" == *Redis*   ]] && use_redis=1
            [[ "${c}" == *Memcached* ]] && use_memcached=1
            [[ "${c}" == "None"   ]] && use_redis=0 && use_memcached=0
        done
    elif [[ -n "${REDIS_INSTALLED:-}" || -n "${MEMCACHED_INSTALLED:-}" ]] && [[ "${MOODLEKIT_YES:-0}" == "1" ]]; then
        [[ -n "${REDIS_INSTALLED:-}" ]] && use_redis=1
        [[ -n "${MEMCACHED_INSTALLED:-}" ]] && use_memcached=1
        info "Auto-selected existing cache layers: Redis($use_redis), Memcached($use_memcached)"
    else
        local current_cache=""
        [[ -n "${REDIS_INSTALLED:-}" ]] && current_cache="Redis"
        [[ -n "${MEMCACHED_INSTALLED:-}" ]] && current_cache="${current_cache} Memcached"
        [[ -z "${current_cache}" ]] && current_cache="None"

        local cache_choices=()
        select_many cache_choices "Select caching stack (Currently installed: ${current_cache}):" \
            "Redis (sessions + MUC — recommended)" \
            "Memcached (MUC application cache)" \
            "None"
        for c in "${cache_choices[@]}"; do
            [[ "${c}" == *Redis*   ]] && use_redis=1
            [[ "${c}" == *Memcached* ]] && use_memcached=1
            [[ "${c}" == "None"   ]] && use_redis=0 && use_memcached=0
        done
    fi

    # Auto-tune
    local do_tune=1
    if [[ "${MOODLEKIT_YES:-0}" != "1" ]]; then
        confirm "Auto-tune PHP/DB/Redis for this server (${RAM_TOTAL_GB}GB RAM)?" "y" \
            && do_tune=1 || do_tune=0
    fi

    # Timezone
    local target_tz
    target_tz="$(configure_system_timezone 0)"

    # Base domain
    local base_domain=""
    if [[ -n "${OPT_DOMAIN:-}" ]]; then
        base_domain="${OPT_DOMAIN}"
    else
        input_text base_domain "Base domain (e.g. example.com) [Optional, press enter to skip]" "" \
            '^$|^[a-zA-Z0-9][a-zA-Z0-9.-]*$' \
            "Invalid domain format"
    fi

    # Let's Encrypt email
    local le_email=""
    if [[ -n "${OPT_EMAIL:-}" ]]; then
        le_email="${OPT_EMAIL}"
    else
        input_text le_email "Let's Encrypt email [Optional, press enter to skip]" "" \
            '^$|^[^@]+@[^@]+\.[^@]+$' \
            "Invalid email format"
    fi

    # Summary before proceeding
    section "Bootstrap Summary"
    echo ""
    echo -e "  ${C_BOLD}PHP version:${C_RESET}  ${php_ver}"
    echo -e "  ${C_BOLD}Database:${C_RESET}     ${db_type}"
    echo -e "  ${C_BOLD}Timezone:${C_RESET}     ${target_tz}"
    echo -e "  ${C_BOLD}Redis:${C_RESET}        $([ "${use_redis}" -eq 1 ] && echo "yes" || echo "no")"
    echo -e "  ${C_BOLD}Memcached:${C_RESET}    $([ "${use_memcached}" -eq 1 ] && echo "yes" || echo "no")"
    echo -e "  ${C_BOLD}Auto-tune:${C_RESET}    $([ "${do_tune}" -eq 1 ] && echo "yes" || echo "no")"
    echo -e "  ${C_BOLD}Base domain:${C_RESET}  ${base_domain}"
    echo -e "  ${C_BOLD}LE email:${C_RESET}     ${le_email}"
    echo -e "  ${C_BOLD}RAM:${C_RESET}          ${RAM_TOTAL_GB}GB"
    echo ""

    if ! confirm "Proceed with bootstrap?" "y"; then
        info "Bootstrap cancelled."
        exit 0
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1/9 — System packages
    # ─────────────────────────────────────────────────────────────────────────
    step 1 9 "System packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget git unzip jq dnsutils acl logrotate \
        ufw fail2ban cron build-essential pkg-config \
        software-properties-common ca-certificates apt-transport-https \
        lsof net-tools gnupg2
    ok "Base packages installed"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2/9 — PHP
    # ─────────────────────────────────────────────────────────────────────────
    step 2 9 "PHP ${php_ver}"
    _install_php "${php_ver}"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3/9 — Database
    # ─────────────────────────────────────────────────────────────────────────
    step 3 9 "Database (${db_type})"
    case "${db_type}" in
        postgres) db_pg_install 17 ;;
        mariadb)  db_maria_install "10.11" ;;
        mysql)    db_mysql_install "8.4" ;;
    esac

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4/9 — Nginx
    # ─────────────────────────────────────────────────────────────────────────
    step 4 9 "Nginx"
    _install_nginx

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5/9 — Cache
    # ─────────────────────────────────────────────────────────────────────────
    step 5 9 "Cache layer"
    [[ "${use_redis}" -eq 1 ]] && _install_redis "${php_ver}"
    [[ "${use_memcached}" -eq 1 ]] && _install_memcached "${php_ver}"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 6/9 — Certbot
    # ─────────────────────────────────────────────────────────────────────────
    step 6 9 "Certbot"
    _install_certbot

    # ─────────────────────────────────────────────────────────────────────────
    # Step 7/9 — Firewall + fail2ban
    # ─────────────────────────────────────────────────────────────────────────
    step 7 9 "Firewall + fail2ban"
    _configure_firewall

    # ─────────────────────────────────────────────────────────────────────────
    # Step 8/9 — Cron daemon
    # ─────────────────────────────────────────────────────────────────────────
    step 8 9 "Cron daemon"
    systemctl enable --now cron
    ok "Cron daemon enabled"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 9/9 — Auto-tune + State
    # ─────────────────────────────────────────────────────────────────────────
    step 9 9 "Auto-tune + State"

    if [[ "${do_tune}" -eq 1 ]]; then
        calculate_tuning "balanced" 1 "${db_type}"
        apply_php_tuning "${php_ver}"
        [[ "${db_type}" == "postgres" ]] && apply_pg_tuning 17
        [[ "${db_type}" == "mariadb" || "${db_type}" == "mysql" ]] && apply_mysql_tuning "${db_type}"
        [[ "${use_redis}" -eq 1 ]] && apply_redis_tuning
    fi

    # State directory & Encrypted Vault
    mkdir -p "${MOODLEKIT_STATE_DIR}"
    chmod 700 "${MOODLEKIT_STATE_DIR}"

    # Save to Encrypted Vault (AES-256 binary storage)
    local global_json
    global_json="$(jq -n \
        --arg moodlekit_version "${MOODLEKIT_VERSION}" \
        --arg base_domain "${base_domain}" \
        --arg letsencrypt_email "${le_email}" \
        --arg php_version "${php_ver}" \
        --arg db_type "${db_type}" \
        --arg timezone "${target_tz}" \
        --argjson use_redis "${use_redis}" \
        --argjson use_memcached "${use_memcached}" \
        --arg bootstrapped_at "$(date -Iseconds)" \
        '{
            moodlekit_version: $moodlekit_version,
            base_domain: $base_domain,
            letsencrypt_email: $letsencrypt_email,
            php_version: $php_version,
            db_type: $db_type,
            timezone: $timezone,
            use_redis: $use_redis,
            use_memcached: $use_memcached,
            bootstrapped_at: $bootstrapped_at
        }'
    )"
    vault_gset_json "${global_json}"

    # Legacy config compatibility
    cat > "${MOODLEKIT_STATE_DIR}/global.conf" << GLOBALCONF
# MoodleKit global configuration — $(date)
# Regenerated by: moodlekit bootstrap
MOODLEKIT_VERSION="${MOODLEKIT_VERSION}"
BASE_DOMAIN="${base_domain}"
LETSENCRYPT_EMAIL="${le_email}"
PHP_VERSION="${php_ver}"
DB_TYPE="${db_type}"
TIMEZONE="${target_tz}"
USE_REDIS="${use_redis}"
USE_MEMCACHED="${use_memcached}"
GLOBALCONF
    chmod 600 "${MOODLEKIT_STATE_DIR}/global.conf"

    touch "${MOODLEKIT_STATE_DIR}/.bootstrap_complete"
    ok "Global configuration securely saved in encrypted vault (${MOODLEKIT_STATE_DIR}/vault.bin)"


    # ─────────────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────────────
    print_box "Bootstrap Complete ✓" \
        "PHP ${php_ver} + ${db_type} + Nginx installed" \
        "" \
        "Next steps:" \
        "  Set DNS wildcard: *.${base_domain} → $(curl -s https://api.ipify.org 2>/dev/null || echo '<server-ip>')" \
        "  Create a site:   moodlekit site create mysite" \
        "" \
        "Log: ${_LOG_FILE}"
    clear_rollbacks
}

# ---------------------------------------------------------------------------
# PHP installation sub-function
# ---------------------------------------------------------------------------
_install_php() {
    local php_ver="$1"

    # Skip if correct version already installed
    if command -v "php${php_ver}" &>/dev/null; then
        ok "PHP ${php_ver} already installed — skipping"
        # Still ensure all extensions are present
    fi

    # Add ondrej/php PPA
    if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -qq
    fi

    local exts=(
        "php${php_ver}-fpm"
        "php${php_ver}-cli"
        "php${php_ver}-curl"
        "php${php_ver}-gd"
        "php${php_ver}-intl"
        "php${php_ver}-mbstring"
        "php${php_ver}-xml"
        "php${php_ver}-xmlrpc"
        "php${php_ver}-zip"
        "php${php_ver}-soap"
        "php${php_ver}-opcache"
        "php${php_ver}-pgsql"
        "php${php_ver}-mysql"
        "php${php_ver}-redis"
        "php${php_ver}-memcached"
        "php${php_ver}-bcmath"
        "php${php_ver}-readline"
        "php${php_ver}-ldap"
        "php${php_ver}-imagick"
    )

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${exts[@]}"

    # Shrink the default www pool to minimal — each site gets its own pool
    local default_pool="/etc/php/${php_ver}/fpm/pool.d/www.conf"
    if [[ -f "${default_pool}" ]]; then
        sed -i 's|^pm\s*=.*|pm = ondemand|'   "${default_pool}"
        sed -i 's|^pm.max_children\s*=.*|pm.max_children = 2|' "${default_pool}"
        sed -i 's|^pm.process_idle_timeout\s*=.*|pm.process_idle_timeout = 10s|' "${default_pool}"
    fi

    # Apply Moodle baseline PHP requirements globally
    local php_ini_cli="/etc/php/${php_ver}/cli/php.ini"
    local php_ini_fpm="/etc/php/${php_ver}/fpm/php.ini"

    for ini_file in "${php_ini_cli}" "${php_ini_fpm}"; do
        if [[ -f "${ini_file}" ]]; then
            sed -i 's/^;\?max_input_vars\s*=.*/max_input_vars = 10000/' "${ini_file}"
            sed -i 's/^;\?memory_limit\s*=.*/memory_limit = 512M/' "${ini_file}"
            sed -i 's/^;\?upload_max_filesize\s*=.*/upload_max_filesize = 100M/' "${ini_file}"
            sed -i 's/^;\?post_max_size\s*=.*/post_max_size = 100M/' "${ini_file}"
            sed -i 's/^;\?max_execution_time\s*=.*/max_execution_time = 300/' "${ini_file}"
        fi
    done

    systemctl enable --now "php${php_ver}-fpm"
    ok "PHP ${php_ver} installed with all Moodle extensions"
}

# ---------------------------------------------------------------------------
# Nginx installation
# ---------------------------------------------------------------------------
_install_nginx() {
    # Port conflict check before installing/reloading Nginx
    if command -v lsof &>/dev/null; then
        if lsof -i :80 -sTCP:LISTEN -t >/dev/null 2>&1 || lsof -i :443 -sTCP:LISTEN -t >/dev/null 2>&1; then
            local pid
            pid=$(lsof -i :80 -sTCP:LISTEN -t | head -1)
            [[ -z "$pid" ]] && pid=$(lsof -i :443 -sTCP:LISTEN -t | head -1)
            local pname=""
            [[ -n "$pid" ]] && pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            if [[ "${pname}" != "nginx" && -n "${pname}" ]]; then
                err "Port 80/443 is in use by '${pname}' (PID: ${pid})."
                err "Please disable it (e.g. IIS, Apache) before running MoodleKit."
                exit 1
            fi
        fi
    fi

    if [[ -n "${NGINX_INSTALLED:-}" ]]; then
        ok "Nginx already installed — skipping install"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
        systemctl enable --now nginx
    fi

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    # Global Moodle config
    cat > /etc/nginx/conf.d/10-moodlekit-global.conf << 'NGINXGLOBAL'
# MoodleKit global Nginx settings
client_max_body_size    256M;
client_body_buffer_size 128k;
server_tokens           off;

keepalive_timeout  65;
keepalive_requests 100;

# Login brute-force rate limiting (per site via limit_req)
limit_req_zone $binary_remote_addr zone=moodle_login:10m rate=5r/m;
limit_req_log_level warn;
NGINXGLOBAL

    # Enable Gzip in main nginx.conf instead of conf.d to prevent duplicates
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i 's/# gzip_vary on;/gzip_vary on;/' /etc/nginx/nginx.conf
        sed -i 's/# gzip_proxied any;/gzip_proxied any;/' /etc/nginx/nginx.conf
        sed -i 's/# gzip_comp_level 6;/gzip_comp_level 5;/' /etc/nginx/nginx.conf
        sed -i 's/# gzip_types /gzip_types /' /etc/nginx/nginx.conf
    fi

    nginx -t 2>&1
    systemctl reload nginx
    ok "Nginx installed and configured"
}

# ---------------------------------------------------------------------------
# Redis installation
# ---------------------------------------------------------------------------
_install_redis() {
    local php_ver="$1"
    if [[ -n "${REDIS_INSTALLED:-}" ]]; then
        ok "Redis already installed — skipping"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
        systemctl enable --now redis-server
    fi

    # Tune: localhost only, no persistence, LRU eviction
    local redis_conf="/etc/redis/redis.conf"
    if [[ -f "${redis_conf}" ]]; then
        sed -i 's|^bind .*|bind 127.0.0.1 -::1|' "${redis_conf}"
        grep -q '^maxmemory-policy' "${redis_conf}" \
            || echo "maxmemory-policy allkeys-lru" >> "${redis_conf}"
        sed -i 's|^appendonly .*|appendonly no|' "${redis_conf}"
        sed -i 's|^save |# save |g' "${redis_conf}"
    fi
    systemctl restart redis-server
    ok "Redis installed and tuned (localhost only, allkeys-lru)"
}

# ---------------------------------------------------------------------------
# Memcached installation
# ---------------------------------------------------------------------------
_install_memcached() {
    local php_ver="$1"
    if [[ -n "${MEMCACHED_INSTALLED:-}" ]]; then
        ok "Memcached already installed — skipping"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y memcached "php${php_ver}-memcached"
        systemctl enable --now memcached
    fi

    # Tune
    local mc_conf="/etc/memcached.conf"
    if [[ -f "${mc_conf}" ]]; then
        sed -i 's|^-m .*|-m 512|' "${mc_conf}"       # 512MB
        sed -i 's|^-l .*|-l 127.0.0.1|' "${mc_conf}" # localhost only
        sed -i 's|^-c .*|-c 1024|' "${mc_conf}"       # max connections
        sed -i 's|^-t .*|-t 4|' "${mc_conf}"           # threads
    fi
    systemctl restart memcached
    ok "Memcached installed (localhost:11211, 512MB)"
}

# ---------------------------------------------------------------------------
# Certbot installation
# ---------------------------------------------------------------------------
_install_certbot() {
    if [[ -n "${CERTBOT_INSTALLED:-}" ]]; then
        ok "Certbot already installed — skipping"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
    systemctl enable --now certbot.timer 2>/dev/null || true
    ok "Certbot installed"
}

# ---------------------------------------------------------------------------
# UFW + fail2ban
# ---------------------------------------------------------------------------
_configure_firewall() {
    # UFW
    if [[ -n "${UFW_INSTALLED:-}" ]] || command -v ufw &>/dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow OpenSSH
        ufw allow 'Nginx Full'
        ufw --force enable
        ok "UFW firewall configured"
    fi

    # fail2ban
    if [[ -n "${FAIL2BAN_INSTALLED:-}" ]] || command -v fail2ban-server &>/dev/null; then
        cat > /etc/fail2ban/jail.d/moodlekit.conf << 'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*.error.log

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*.error.log
maxretry = 10
F2B
        systemctl restart fail2ban
        ok "fail2ban configured"
    fi
}
