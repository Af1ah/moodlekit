#!/usr/bin/env bash
# =============================================================================
# commands/site-create.sh — Create a new Moodle site/tenant
# =============================================================================
# 12-step provisioning pipeline with all bugs from reference scripts fixed.
# Supports Moodle 4.5 (traditional) and 5.2 (public/ + r.php) structure.
# Supports PostgreSQL, MariaDB, MySQL.
# =============================================================================

cmd_site_create() {
    require_root
    load_global_conf

    local SLUG="${1:-}"
    if [[ -z "${SLUG}" ]]; then
        info "Creating a new Moodle tenant."
        input_text SLUG "Enter a short, lowercase name (slug) for this site (e.g. mysite)" "" '^[a-z0-9]+$' "Slug must be lowercase alphanumeric only."
        echo ""
    fi
    validate_slug "${SLUG}"

    init_logging "site-create-${SLUG}"
    acquire_lock "site-${SLUG}"

    section "MoodleKit — Site Create: ${SLUG}"

    # ─────────────────────────────────────────────────────────────────────────
    # Interactive options
    # ─────────────────────────────────────────────────────────────────────────

    # Moodle version
    local MOODLE_VERSION="${OPT_MOODLE_VERSION:-}"
    local MOODLE_TAG="${OPT_MOODLE_TAG:-}"
    if [[ -z "${MOODLE_VERSION}" ]]; then
        local mv_choice=""
        select_one mv_choice "Select Moodle version:" \
            "Moodle 5.2 (latest stable)" \
            "Moodle 4.5 LTS (long-term support)" \
            "Custom git tag"
        case "${mv_choice}" in
            *5.2*) MOODLE_VERSION="5.2" ;;
            *4.5*) MOODLE_VERSION="4.5" ;;
            *Custom*)
                input_text MOODLE_TAG "Enter git tag (e.g. v5.2.0)" "" \
                    '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' "Format: v5.2.0"
                MOODLE_VERSION="${MOODLE_TAG#v}"
                MOODLE_VERSION="${MOODLE_VERSION%%.*}.${MOODLE_VERSION#*.}"
                ;;
        esac
    fi

    # Domain
    local default_domain="${SLUG}.${BASE_DOMAIN}"
    [[ -z "${BASE_DOMAIN}" ]] && default_domain="${SLUG}"
    
    local DOMAIN=""
    if [[ -n "${OPT_DOMAIN:-}" ]]; then
        DOMAIN="${OPT_DOMAIN}"
    else
        input_text DOMAIN "Enter the full domain for this site" "${default_domain}" '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' "Invalid domain format"
    fi
    validate_domain "${DOMAIN}"
    local domain_owner=""
    domain_owner="$(site_slug_for_domain "${DOMAIN}" || true)"
    if [[ -n "${domain_owner}" && "${domain_owner}" != "${SLUG}" ]]; then
        err "Domain '${DOMAIN}' is already assigned to managed site '${domain_owner}'."
        err "Choose a different domain before provisioning '${SLUG}'."
        return 1
    fi

    # Initialize skip flags from CLI options
    local SKIP_DNS="${OPT_SKIP_DNS:-0}"
    local SKIP_TLS="${OPT_SKIP_TLS:-0}"

    # Auto-skip TLS for local/testing domains
    if [[ "${DOMAIN}" == *.local || "${DOMAIN}" == *.test || "${DOMAIN}" == "localhost" || "${DOMAIN}" != *.* ]]; then
        SKIP_TLS=1
    fi

    # Admin email (with smart default)
    local ADMIN_EMAIL="${OPT_ADMIN_EMAIL:-}"
    [[ -z "${ADMIN_EMAIL}" ]] && \
        input_text ADMIN_EMAIL "Admin email" "admin@${DOMAIN}" '^[^@]+@[^@]+\.[^@]+$' "Invalid email"

    # Redis sessions
    local USE_REDIS_SESSIONS=1
    if [[ "${USE_REDIS}" == "1" ]] && [[ "${MOODLEKIT_YES:-0}" != "1" ]]; then
        confirm "Enable Redis session handler?" "y" || USE_REDIS_SESSIONS=0
    fi
    [[ "${USE_REDIS:-0}" != "1" ]] && USE_REDIS_SESSIONS=0

    # Web plugin install (ACLs on plugin dirs)
    local ENABLE_PLUGIN_INSTALL=0
    if [[ "${MOODLEKIT_YES:-0}" != "1" ]]; then
        confirm "Enable web-based plugin installation? (sets ACLs)" "n" && ENABLE_PLUGIN_INSTALL=1
    fi

    # Correct stale/misdetected global configuration by asking the actual
    # database server. Client executable names cannot distinguish these forks.
    if [[ "${DB_TYPE}" == "mariadb" || "${DB_TYPE}" == "mysql" ]]; then
        local actual_mysql_flavor
        actual_mysql_flavor="$(detect_mysql_server_flavor)"
        if [[ -n "${actual_mysql_flavor}" && "${actual_mysql_flavor}" != "${DB_TYPE}" ]]; then
            warn "Configured database type is '${DB_TYPE}', but the running server is '${actual_mysql_flavor}'."
            info "Using '${actual_mysql_flavor}' so Moodle applies the correct compatibility checks."
            DB_TYPE="${actual_mysql_flavor}"
        fi
    fi

    MOODLE_DIR="/var/www/moodle/${SLUG}"
    MOODLEDATA_DIR="/var/moodledata/${SLUG}"
    DB_NAME="moodle_${SLUG}"
    DB_USER="moodle_${SLUG}"
    DB_PASS="$(gen_password 24)"
    DB_PREFIX="mdl_"
    ADMIN_PASS="M00dle123#"
    DB_PORT="5432"
    [[ "${DB_TYPE}" == "mariadb" || "${DB_TYPE}" == "mysql" ]] && DB_PORT="3306"

    # Moodle git branch
    if [[ -z "${MOODLE_TAG}" ]]; then
        case "${MOODLE_VERSION}" in
            5.2) MOODLE_BRANCH="MOODLE_502_STABLE" ;;
            5.1) MOODLE_BRANCH="MOODLE_501_STABLE" ;;
            4.5) MOODLE_BRANCH="MOODLE_405_STABLE" ;;
            4.4) MOODLE_BRANCH="MOODLE_404_STABLE" ;;
            *)   MOODLE_BRANCH="$(moodle_version_to_branch "${MOODLE_VERSION}")" ;;
        esac
    fi

    # PHP version compatibility check
    validate_php_moodle_compat "${PHP_VERSION}" "${MOODLE_VERSION}"

    # Moodle 5.x uses public/ structure
    local IS_MOODLE5=0
    local major_ver="${MOODLE_VERSION%%.*}"
    (( major_ver >= 5 )) && IS_MOODLE5=1

    # Admin CLI path depends on structure
    local ADMIN_CLI="${MOODLE_DIR}/admin/cli"

    # Config.php location (always in root, not public/)
    local CONFIG_PHP="${MOODLE_DIR}/config.php"

    # FPM socket & pool
    local FPM_SOCK
    FPM_SOCK="$(detect_fpm_socket "${SLUG}" "${PHP_VERSION}")"
    local FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/${SLUG}.conf"
    local NGINX_CONF="/etc/nginx/sites-available/moodle-${SLUG}"
    local NGINX_ENABLED="/etc/nginx/sites-enabled/moodle-${SLUG}"

    section "Site Creation Summary"
    echo -e "  ${C_BOLD}Slug:${C_RESET}       ${SLUG}"
    echo -e "  ${C_BOLD}Domain:${C_RESET}     ${DOMAIN}"
    echo -e "  ${C_BOLD}Moodle:${C_RESET}     ${MOODLE_VERSION} (${MOODLE_BRANCH:-$MOODLE_TAG})"
    echo -e "  ${C_BOLD}Structure:${C_RESET}  $([ "${IS_MOODLE5}" -eq 1 ] && echo "Moodle 5.x (public/ router)" || echo "Moodle 4.x (classic)")"
    echo -e "  ${C_BOLD}PHP:${C_RESET}        ${PHP_VERSION}"
    echo -e "  ${C_BOLD}Database:${C_RESET}   ${DB_TYPE} (${DB_NAME})"
    echo -e "  ${C_BOLD}Directory:${C_RESET}  ${MOODLE_DIR}"
    echo -e "  ${C_BOLD}Data Dir:${C_RESET}   ${MOODLEDATA_DIR}"
    echo ""

    if ! confirm "Proceed with creating this site?" "y"; then
        info "Site creation cancelled."
        exit 0
    fi
    echo ""
    state_operation_start "site-create" "${SLUG}" "$(jq -nc --arg domain "${DOMAIN}" --arg version "${MOODLE_VERSION}" '{domain:$domain,moodle_version:$version}')"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1/12 — Validate + conflict check
    # ─────────────────────────────────────────────────────────────────────────
    step 1 12 "Validate slug and check conflicts"
    check_slug_conflicts "${SLUG}"
    check_disk_space "/var/www" 3

    # Moodle's installer requires the XML parser. Repair this bootstrap
    # dependency before creating any site resources rather than failing late.
    if ! "/usr/bin/php${PHP_VERSION}" -r \
        'exit(function_exists("xml_parser_create") ? 0 : 1);' 2>/dev/null; then
        warn "PHP ${PHP_VERSION} XML parser extension is missing; installing it now."
        DEBIAN_FRONTEND=noninteractive apt-get install -y "php${PHP_VERSION}-xml"
        if ! "/usr/bin/php${PHP_VERSION}" -r \
            'exit(function_exists("xml_parser_create") ? 0 : 1);' 2>/dev/null; then
            err "PHP XML parser is still unavailable after installing php${PHP_VERSION}-xml."
            err "Check /etc/php/${PHP_VERSION}/cli/conf.d for the XML module configuration."
            return 1
        fi
        ok "PHP XML parser extension installed"
    fi
    ok "No conflicts — proceeding"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 2/12 — DNS check
    # ─────────────────────────────────────────────────────────────────────────
    step 2 12 "DNS check"
    dns_check "${DOMAIN}" "${SKIP_DNS}"

    # ── Resume detection ───────────────────────────────────────────────────
    local SKIP_DB=0
    local SKIP_CLONE=0
    local SKIP_INSTALLER=0

    # 1. Database check
    local db_exists=0
    case "${DB_TYPE}" in
        postgres) sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DB_NAME}" && db_exists=1 ;;
        mariadb|mysql) mysql -u root -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null | grep -qw "${DB_NAME}" && db_exists=1 ;;
    esac

    if [[ "${db_exists}" -eq 1 ]]; then
        warn "Database '${DB_NAME}' already exists."
        local db_action=""
        select_one db_action "How to handle existing database?" \
            "Keep it (skip DB creation)" \
            "Drop and recreate" \
            "Abort"
        case "${db_action}" in
            *Keep*) SKIP_DB=1 ;;
            *Drop*) 
                SKIP_DB=0 
                info "Dropping existing database '${DB_NAME}'..."
                case "${DB_TYPE}" in
                    postgres) db_pg_drop "${DB_NAME}" "${DB_USER}" ;;
                    mariadb)  db_maria_drop "${DB_NAME}" "${DB_USER}" ;;
                    mysql)    db_mysql_drop "${DB_NAME}" "${DB_USER}" ;;
                esac
                ;;
            *Abort*) exit 1 ;;
        esac
    fi

    # 2. Existing config.php check
    if [[ -f "${MOODLE_DIR}/config.php" ]]; then
        info "Found existing config.php. Extracting credentials..."
        local ex_db_name="$(grep -E "^\s*\\\$CFG->dbname\s*=" "${MOODLE_DIR}/config.php" | cut -d"'" -f2 || true)"
        local ex_db_user="$(grep -E "^\s*\\\$CFG->dbuser\s*=" "${MOODLE_DIR}/config.php" | cut -d"'" -f2 || true)"
        local ex_db_pass="$(grep -E "^\s*\\\$CFG->dbpass\s*=" "${MOODLE_DIR}/config.php" | cut -d"'" -f2 || true)"
        local ex_domain="$(grep -E "^\s*\\\$CFG->wwwroot\s*=" "${MOODLE_DIR}/config.php" | cut -d"'" -f2 | sed 's|https://||' | sed 's|http://||' || true)"
        local ex_db_prefix="$(grep -E "^\s*\\\$CFG->prefix\s*=" "${MOODLE_DIR}/config.php" | cut -d"'" -f2 || true)"
        
        [[ -n "${ex_db_name}" ]] && DB_NAME="${ex_db_name}"
        [[ -n "${ex_db_user}" ]] && DB_USER="${ex_db_user}"
        [[ -n "${ex_db_pass}" ]] && DB_PASS="${ex_db_pass}"
        [[ -n "${ex_domain}" ]] && DOMAIN="${ex_domain}"
        [[ -n "${ex_db_prefix}" ]] && DB_PREFIX="${ex_db_prefix}"
        
        if confirm "config.php exists. Skip running the Moodle installer?" "y"; then
            SKIP_INSTALLER=1
        fi
    fi

    # 3. Moodle Dir check
    if [[ -d "${MOODLE_DIR}" && "$(ls -A "${MOODLE_DIR}" 2>/dev/null)" ]]; then
        if confirm "Directory ${MOODLE_DIR} is not empty. Skip cloning Moodle?" "y"; then
            SKIP_CLONE=1
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3/12 — Create database
    # ─────────────────────────────────────────────────────────────────────────
    step 3 12 "Create database (${DB_TYPE})"
    if [[ "${SKIP_DB}" -eq 1 ]]; then
        info "Skipped (using existing database)"
    else
        case "${DB_TYPE}" in
            postgres)
                db_pg_create "${SLUG}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
                register_rollback "db_pg_drop '${DB_NAME}' '${DB_USER}'"
                ;;
            mariadb)
                db_maria_create "${SLUG}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
                register_rollback "db_maria_drop '${DB_NAME}' '${DB_USER}'"
                ;;
            mysql)
                db_mysql_create "${SLUG}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
                register_rollback "db_mysql_drop '${DB_NAME}' '${DB_USER}'"
                ;;
        esac
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 4/12 — Clone Moodle
    # ─────────────────────────────────────────────────────────────────────────
    step 4 12 "Clone Moodle ${MOODLE_VERSION}"
    if [[ "${SKIP_CLONE}" -eq 1 ]]; then
        info "Skipped (using existing Moodle files)"
    else
        mkdir -p "${MOODLE_DIR}"
        register_rollback "rm -rf '${MOODLE_DIR}'"

        if [[ -n "${MOODLE_TAG}" ]]; then
            git clone --depth 1 --branch "${MOODLE_TAG}" \
                https://github.com/moodle/moodle.git "${MOODLE_DIR}"
        else
            git clone --depth 1 --branch "${MOODLE_BRANCH}" \
                https://github.com/moodle/moodle.git "${MOODLE_DIR}"
        fi
        ok "Moodle cloned"

        # Run Composer if needed (Moodle 5.x always needs it)
        local composer_json
        if [[ "${IS_MOODLE5}" -eq 1 ]]; then
            composer_json="${MOODLE_DIR}/composer.json"
        else
            composer_json="${MOODLE_DIR}/composer.json"
        fi

        if [[ -f "${composer_json}" ]]; then
            # Auto-install Composer if missing
            if ! command -v composer &>/dev/null; then
                spinner_start "Installing Composer..."
                curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
                spinner_stop 0 "Composer installed"
            fi
            spinner_start "Running composer install..."
            COMPOSER_ALLOW_SUPERUSER=1 composer install \
                --no-dev --optimize-autoloader --no-interaction \
                --working-dir="${MOODLE_DIR}" 2>&1 | tee -a "${_LOG_FILE}"
            spinner_stop 0 "Composer done"
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 5/12 — Set permissions
    # ─────────────────────────────────────────────────────────────────────────
    step 5 12 "Set permissions"

    # Moodle code: root:www-data, not writable by web server
    normalize_moodle_code_permissions "${MOODLE_DIR}"

    # moodledata: fully writable by www-data
    mkdir -p "${MOODLEDATA_DIR}"
    chown -R www-data:www-data "${MOODLEDATA_DIR}"
    chmod -R 02777 "${MOODLEDATA_DIR}"
    # The CLI installer runs as www-data and must be able to traverse parents.
    chmod o+x /var/www /var/www/moodle "$(dirname "${MOODLEDATA_DIR}")"
    register_rollback "rm -rf '${MOODLEDATA_DIR}'"

    # Optional: ACLs for web-based plugin installation
    if [[ "${ENABLE_PLUGIN_INSTALL}" -eq 1 ]]; then
        local plugin_dirs=(
            "mod" "blocks" "theme" "auth" "enrol" "local"
            "filter" "report" "admin/tool" "question/type"
            "grade/export" "grade/import" "grade/report"
        )
        local code_root="${MOODLE_DIR}"
        [[ "${IS_MOODLE5}" -eq 1 ]] && code_root="${MOODLE_DIR}/public"
        for d in "${plugin_dirs[@]}"; do
            [[ -d "${code_root}/${d}" ]] && \
                setfacl -R -m u:www-data:rwx "${code_root}/${d}" 2>/dev/null || true
        done
        info "Plugin install ACLs applied"
    fi

    ok "Permissions set"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 6/12 — PHP-FPM pool
    # ─────────────────────────────────────────────────────────────────────────
    step 6 12 "PHP-FPM pool"

    # Calculate workers based on number of existing sites
    local num_sites
    num_sites=0
    if [[ -d "${MOODLEKIT_SITES_DIR}" ]]; then
        num_sites="$(find "${MOODLEKIT_SITES_DIR}" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l)"
    fi
    num_sites=$(( num_sites + 1 ))  # include this new site

    info "Sizing PHP-FPM for ${num_sites} managed site(s)..."
    calculate_tuning "balanced" "${num_sites}" "${DB_TYPE}"
    info "Measured worker model: ${TUNE_FPM_WORKER_MEMORY_MB}MB reserved per worker (${TUNE_FPM_MEMORY_SOURCE})"
    info "Recommended pool: max_children=${TUNE_FPM_MAX_CHILDREN}; server safety cap=${TUNE_FPM_WORKER_CAP}"

    if is_interactive; then
        local fpm_size_choice=""
        select_one fpm_size_choice "Choose PHP-FPM pool sizing for '${SLUG}':" \
            "Use recommended ${TUNE_FPM_MAX_CHILDREN} workers (Recommended)" \
            "Choose a custom worker count (2-${TUNE_FPM_WORKER_CAP})"
        if [[ "${fpm_size_choice}" == *"custom"* ]]; then
            local custom_workers="${TUNE_FPM_MAX_CHILDREN}"
            while true; do
                input_text custom_workers \
                    "Maximum PHP-FPM workers for this site (2-${TUNE_FPM_WORKER_CAP})" \
                    "${TUNE_FPM_MAX_CHILDREN}" '^[0-9]+$' "Enter a whole number"
                if set_fpm_pool_workers "${custom_workers}"; then
                    break
                fi
            done
        fi
    fi

    if [[ ! -d "/etc/php/${PHP_VERSION}/fpm/pool.d" ]]; then
        err "PHP-FPM ${PHP_VERSION} is not installed or its pool directory is missing."
        err "Expected: /etc/php/${PHP_VERSION}/fpm/pool.d"
        err "Run 'moodlekit doctor' or re-run bootstrap before creating the site."
        return 1
    fi
    if ! systemctl list-unit-files "php${PHP_VERSION}-fpm.service" --no-legend 2>/dev/null | grep -q .; then
        err "PHP-FPM service php${PHP_VERSION}-fpm.service was not found."
        err "Run 'moodlekit doctor' or re-run bootstrap before creating the site."
        return 1
    fi

    render_template_to_file "${MOODLEKIT_TPL}/fpm-pool.conf.tpl" "${FPM_POOL_CONF}" \
        "SLUG=${SLUG}" \
        "PHP_VERSION=${PHP_VERSION}" \
        "FPM_SOCK=${FPM_SOCK}" \
        "MAX_CHILDREN=${TUNE_FPM_MAX_CHILDREN}" \
        "START_SERVERS=${TUNE_FPM_START_SERVERS}" \
        "MIN_SPARE=${TUNE_FPM_MIN_SPARE}" \
        "MAX_SPARE=${TUNE_FPM_MAX_SPARE}" \
        "MOODLE_DIR=${MOODLE_DIR}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "TIMEZONE=UTC" \
        "TIMESTAMP=$(date)"
    register_rollback "rm -f '${FPM_POOL_CONF}'"

    reload_fpm "${PHP_VERSION}"
    wait_for_fpm_socket "${FPM_SOCK}" 30
    ok "FPM pool created: max_children=${TUNE_FPM_MAX_CHILDREN}"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 7/12 — Nginx vhost
    # ─────────────────────────────────────────────────────────────────────────
    step 7 12 "Nginx vhost"

    local nginx_tpl
    if [[ "${IS_MOODLE5}" -eq 1 ]]; then
        nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"
    else
        nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
    fi

    render_template_to_file "${nginx_tpl}" "${NGINX_CONF}" \
        "DOMAIN=${DOMAIN}" \
        "MOODLE_DIR=${MOODLE_DIR}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "PHP_VERSION=${PHP_VERSION}" \
        "FPM_SOCK=${FPM_SOCK}" \
        "SLUG=${SLUG}"

    # For initial HTTP-only (before certbot), strip TLS directives temporarily
    # We use a simpler HTTP-only block first for certbot ACME challenge
    mkdir -p /var/www/letsencrypt/.well-known/acme-challenge
    chown root:www-data /var/www/letsencrypt
    chmod 755 /var/www/letsencrypt /var/www/letsencrypt/.well-known \
        /var/www/letsencrypt/.well-known/acme-challenge
    local initial_docroot
    initial_docroot="$(get_moodle_docroot "${MOODLE_DIR}")"
    cat > "${NGINX_CONF}.http-only" << HTTPONLY
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${initial_docroot};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }

    location / {
        return 200 "MoodleKit site provisioning in progress...";
        add_header Content-Type text/plain;
    }
}
HTTPONLY

    ln -sf "${NGINX_CONF}.http-only" "${NGINX_ENABLED}"
    register_rollback "rm -f '${NGINX_CONF}' '${NGINX_CONF}.http-only' '${NGINX_ENABLED}'"
    reload_nginx
    ok "Nginx HTTP vhost active"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 8/12 — TLS certificate
    # ─────────────────────────────────────────────────────────────────────────
    step 8 12 "TLS certificate"
    if [[ "${SKIP_TLS}" == "1" ]]; then
        warn "TLS skipped (--skip-tls). Site will use HTTPS with a self-signed fallback."
        generate_self_signed_fallback "${DOMAIN}" "${NGINX_CONF}"
    else
        local certbot_contact_args=()
        if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
            certbot_contact_args=(--email "${LETSENCRYPT_EMAIL}")
        else
            certbot_contact_args=(--register-unsafely-without-email)
            warn "No Let's Encrypt email configured; registering without an email address."
            warn "Certificate expiry and account notices will not be delivered by email."
        fi
        if ! certbot certonly \
            --webroot \
            --webroot-path /var/www/letsencrypt \
            --domain "${DOMAIN}" \
            "${certbot_contact_args[@]}" \
            --agree-tos \
            --non-interactive \
            --quiet; then
            
            warn "Certbot challenge failed (Domain might be behind Cloudflare/NAT)."
            generate_self_signed_fallback "${DOMAIN}" "${NGINX_CONF}"
        else
            ok "TLS certificate obtained for ${DOMAIN}"
        fi
    fi

    # Switch to HTTPS config
    ln -sf "${NGINX_CONF}" "${NGINX_ENABLED}"
    reload_nginx

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 9/12 — Run Moodle installer
    # ─────────────────────────────────────────────────────────────────────────
    step 9 12 "Moodle CLI install"

    if [[ "${SKIP_INSTALLER}" -eq 1 ]]; then
        info "Skipped (using existing config.php)"
    else
        # Moodle installer location differs by version
        local installer="${MOODLE_DIR}/admin/cli/install.php"

        # Map DB type to Moodle's dbtype string
        local moodle_dbtype
        case "${DB_TYPE}" in
            postgres) moodle_dbtype="pgsql"   ;;
            mariadb)  moodle_dbtype="mariadb" ;;
            mysql)    moodle_dbtype="mysqli"  ;;
        esac

        # Ensure baseline PHP limits meet Moodle's strict requirements automatically
        local php_ini_cli="/etc/php/${PHP_VERSION}/cli/php.ini"
        local php_ini_fpm="/etc/php/${PHP_VERSION}/fpm/php.ini"
        for ini_file in "${php_ini_cli}" "${php_ini_fpm}"; do
            if [[ -f "${ini_file}" ]]; then
                sed -i 's/^;\?max_input_vars\s*=.*/max_input_vars = 10000/' "${ini_file}"
                sed -i 's/^;\?memory_limit\s*=.*/memory_limit = 512M/' "${ini_file}"
                sed -i 's/^;\?upload_max_filesize\s*=.*/upload_max_filesize = 100M/' "${ini_file}"
                sed -i 's/^;\?post_max_size\s*=.*/post_max_size = 100M/' "${ini_file}"
                sed -i 's/^;\?max_execution_time\s*=.*/max_execution_time = 300/' "${ini_file}"
            fi
        done
        
        spinner_start "Running Moodle installer (this may take a few minutes)..."
        
        # Temporarily grant www-data ownership so it can write config.php
        chown www-data "${MOODLE_DIR}"

        set +e
        # Start from a directory www-data can traverse. Invoking MoodleKit from
        # /root would otherwise make Moodle's attempt to restore cwd emit EACCES.
        ( cd "${MOODLE_DIR}" && sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${installer}" \
            --chmod=02777 \
            --lang=en \
            --wwwroot="https://${DOMAIN}" \
            --dataroot="${MOODLEDATA_DIR}" \
            --dbtype="${moodle_dbtype}" \
            --dbhost="127.0.0.1" \
            --dbport="${DB_PORT}" \
            --dbname="${DB_NAME}" \
            --dbuser="${DB_USER}" \
            --dbpass="${DB_PASS}" \
            --prefix="mdl_" \
            --fullname="Moodle ${SLUG}" \
            --shortname="${SLUG}" \
            --adminuser="admin" \
            --adminpass="${ADMIN_PASS}" \
            --adminemail="${ADMIN_EMAIL}" \
            --agree-license \
            --non-interactive ) 2>&1 | tee -a "${_LOG_FILE}"
        local installer_exit="${PIPESTATUS[0]}"
        set -e

        # Lock ownership back to root for security
        chown root "${MOODLE_DIR}"

        if [[ "${installer_exit}" -ne 0 ]]; then
            spinner_stop 1 "Moodle installer failed (exit code ${installer_exit})"
            err "Installation stopped. Review: ${_LOG_FILE}"
            return "${installer_exit}"
        fi
        spinner_stop 0 "Moodle installed"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 10/12 — Patch config.php + MUC cache setup
    # ─────────────────────────────────────────────────────────────────────────
    step 10 12 "Configure config.php + MUC cache"

    # Build the cache config block
    local cache_config=""
    if [[ "${USE_REDIS_SESSIONS}" -eq 1 ]]; then
        cache_config+="
// ── Redis Session Handler ─────────────────────────────────────────────────
\$CFG->session_handler_class = '\core\session\redis';
\$CFG->session_redis_host    = '127.0.0.1';
\$CFG->session_redis_port    = 6379;
\$CFG->session_redis_database = 0;
\$CFG->session_redis_prefix  = 'mdl_${SLUG}_sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire          = 7200;
\$CFG->session_redis_serializer_use_igbinary = false;
"
    fi

    if [[ "${USE_MEMCACHED:-0}" == "1" ]]; then
        cache_config+="
// ── Memcached (MUC Application Cache — sessions handled by Redis) ─────────
// Store instance 'memcached_muc' configured below.
// MUC mapping is done via Site Admin → Plugins → Caching → Configuration
"
    fi

    # Patch config.php using awk (insert before require_once)
    local tmp_config
    tmp_config="$(mktemp)"

    local setup_require="require_once"
    [[ "${IS_MOODLE5}" -eq 1 ]] && setup_require="require_once(__DIR__ . '/lib/setup.php')"

    # Build additions to inject
    local config_additions
    config_additions="$(cat << CONFADD
// ── MoodleKit managed config ──────────────────────────────────────────────
\$CFG->xsendfile        = 'X-Accel-Redirect';
\$CFG->xsendfilealiases = ['/dataroot/' => \$CFG->dataroot];
\$CFG->sslproxy         = false;
\$CFG->cronclionly      = true;
\$CFG->pathtophp        = '/usr/bin/php${PHP_VERSION}';
$([ "${IS_MOODLE5}" -eq 1 ] && echo "\$CFG->routerconfigured = true;")
${cache_config}
CONFADD
)"

    export CONFIG_ADD="${config_additions}"
    awk '
        /^require_once/ && !done {
            print ENVIRON["CONFIG_ADD"]
            done = 1
        }
        { print }
    ' "${CONFIG_PHP}" > "${tmp_config}"

    cp "${tmp_config}" "${CONFIG_PHP}"
    rm -f "${tmp_config}"
    chown root:www-data "${CONFIG_PHP}"
    chmod 640 "${CONFIG_PHP}"
    ok "config.php patched"

    # Purge caches after config change
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
        "${ADMIN_CLI}/purge_caches.php" 2>&1 | tee -a "${_LOG_FILE}" || true

    # MUC Redis setup — create store instance programmatically
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        if ! _configure_muc_redis "${SLUG}" "${MOODLE_DIR}" "${IS_MOODLE5}"; then
            warn "Site installation is usable, but Redis MUC mapping needs manual review."
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 11/12 — Configure cron
    # ─────────────────────────────────────────────────────────────────────────
    step 11 12 "Configure cron"
    _configure_cron "${SLUG}" "${MOODLE_DIR}" "${IS_MOODLE5}"

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 12/12 — Moodle task processing + Save state
    # ─────────────────────────────────────────────────────────────────────────
    step 12 12 "Task processing + Save state"

    # Configure ad-hoc task processing (was dead code in reference — now called)
    _configure_task_processing "${ADMIN_CLI}"

    # Save site state into Encrypted Binary Vault
    local site_json
    site_json="$(jq -n \
        --arg slug "${SLUG}" \
        --arg domain "${DOMAIN}" \
        --arg moodle_version "${MOODLE_VERSION}" \
        --arg moodle_branch "${MOODLE_BRANCH:-}" \
        --arg moodle_tag "${MOODLE_TAG:-}" \
        --argjson is_moodle5 "${IS_MOODLE5}" \
        --arg moodle_dir "${MOODLE_DIR}" \
        --arg moodledata_dir "${MOODLEDATA_DIR}" \
        --arg db_type "${DB_TYPE}" \
        --arg db_name "${DB_NAME}" \
        --arg db_user "${DB_USER}" \
        --arg db_pass "${DB_PASS}" \
        --arg db_port "${DB_PORT}" \
        --arg php_version "${PHP_VERSION}" \
        --arg admin_email "${ADMIN_EMAIL}" \
        --arg admin_pass "${ADMIN_PASS}" \
        --arg fpm_pool_conf "${FPM_POOL_CONF}" \
        --arg fpm_sock "${FPM_SOCK}" \
        --arg nginx_conf "${NGINX_CONF}" \
        --argjson use_redis_sessions "${USE_REDIS_SESSIONS}" \
        --arg type "tenant" \
        --arg created_at "$(date -Iseconds)" \
        '{
            slug: $slug,
            domain: $domain,
            moodle_version: $moodle_version,
            moodle_branch: $moodle_branch,
            moodle_tag: $moodle_tag,
            is_moodle5: $is_moodle5,
            moodle_dir: $moodle_dir,
            moodledata_dir: $moodledata_dir,
            db_type: $db_type,
            db_name: $db_name,
            db_user: $db_user,
            db_pass: $db_pass,
            db_port: $db_port,
            php_version: $php_version,
            admin_email: $admin_email,
            admin_pass: $admin_pass,
            fpm_pool_conf: $fpm_pool_conf,
            fpm_sock: $fpm_sock,
            nginx_conf: $nginx_conf,
            use_redis_sessions: $use_redis_sessions,
            type: $type,
            created_at: $created_at
        }'
    )"
    vault_sset "${SLUG}" "${site_json}"
    state_site_upsert "${site_json}"

    # Legacy config compatibility
    mkdir -p "${MOODLEKIT_SITES_DIR}"
    cat > "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" << SITECONF
# MoodleKit site config — ${SLUG} — $(date)
SLUG="${SLUG}"
DOMAIN="${DOMAIN}"
MOODLE_VERSION="${MOODLE_VERSION}"
MOODLE_BRANCH="${MOODLE_BRANCH:-}"
MOODLE_TAG="${MOODLE_TAG:-}"
IS_MOODLE5="${IS_MOODLE5}"
MOODLE_DIR="${MOODLE_DIR}"
MOODLEDATA_DIR="${MOODLEDATA_DIR}"
DB_TYPE="${DB_TYPE}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_PORT="${DB_PORT}"
PHP_VERSION="${PHP_VERSION}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_PASS="${ADMIN_PASS}"
FPM_POOL_CONF="${FPM_POOL_CONF}"
FPM_SOCK="${FPM_SOCK}"
NGINX_CONF="${NGINX_CONF}"
USE_REDIS_SESSIONS="${USE_REDIS_SESSIONS}"
CREATED_AT="$(date -Iseconds)"
SITECONF
    chmod 600 "${MOODLEKIT_SITES_DIR}/${SLUG}.conf"

    release_lock
    clear_rollbacks
    state_operation_finish "completed" "Site creation completed"


    # ─────────────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────────────
    print_box "Site Created: ${SLUG} ✓" \
        "URL:          https://${DOMAIN}" \
        "Admin user:   admin" \
        "Admin pass:   ${ADMIN_PASS}" \
        "Admin email:  ${ADMIN_EMAIL}" \
        "" \
        "Moodle:       ${MOODLE_VERSION} ($([ "${IS_MOODLE5}" -eq 1 ] && echo "public/ structure" || echo "traditional"))" \
        "PHP:          ${PHP_VERSION}" \
        "Database:     ${DB_TYPE} / ${DB_NAME}" \
        "FPM workers:  ${TUNE_FPM_MAX_CHILDREN}" \
        "" \
        "Credentials:  ${MOODLEKIT_SITES_DIR}/${SLUG}.conf" \
        "Log:          ${_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Configure cron with stagger offset + flock to prevent overlap
# Bug fix: uses SLUG not SITE_SLUG; uses err not die
# ---------------------------------------------------------------------------
_configure_cron() {
    local slug="$1"
    local moodle_dir="$2"

    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${moodle_dir}")"
    local cron_php="${admin_cli}/cron.php"

    if [[ ! -f "${cron_php}" ]]; then
        err "Moodle cron.php not found: ${cron_php}"
        exit 1
    fi

    # Calculate stagger offset: 12 seconds per existing site
    local existing=0
    if [[ -d "${MOODLEKIT_SITES_DIR}" ]]; then
        existing="$(find "${MOODLEKIT_SITES_DIR}" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l)"
    fi
    local offset=$(( (existing * 12) % 60 ))

    # Lock file uses SLUG (not SITE_SLUG — BUG FIX from reference scripts)
    local lock_file="/tmp/moodlekit-${slug}.lock"

    local cron_file="/etc/cron.d/moodlekit-${slug}"
    mkdir -p /var/log/moodlekit
    cat > "${cron_file}" << CRONFILE
# MoodleKit cron — ${slug} — stagger offset: ${offset}s
# Generated: $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * www-data sleep ${offset} && flock -n ${lock_file} /usr/bin/php${PHP_VERSION} ${cron_php} >> /var/log/moodlekit/${slug}-cron.log 2>&1
CRONFILE
    chmod 644 "${cron_file}"
    register_rollback "rm -f '${cron_file}'"

    if [[ ! -s "${cron_file}" ]] || ! grep -Fq "${cron_php}" "${cron_file}"; then
        err "Cron verification failed: ${cron_file} was not written correctly."
        return 1
    fi
    systemctl enable --now cron >/dev/null 2>&1 || {
        err "Cron file was created, but the cron service could not be started."
        return 1
    }
    ok "Cron configured and verified: ${cron_file} (offset: ${offset}s)"
}

# ---------------------------------------------------------------------------
# Configure MUC Redis store — creates store instance in Moodle
# ---------------------------------------------------------------------------
_configure_muc_redis() {
    local slug="$1"
    local moodle_dir="$2"
    local is_moodle5="${3:-0}"

    # Create a temporary PHP script to set up Redis MUC store
    local muc_script
    muc_script="$(mktemp --suffix=.php)"
    cat > "${muc_script}" << MUCPHP
<?php
/**
 * MoodleKit: Configure Redis as MUC store for ${slug}
 * Runs after Moodle install to set up the Redis cache store instance.
 */
define('CLI_SCRIPT', true);
require('${moodle_dir}/config.php');

\$plugin = 'cachestore_redis';
\$instance_name = 'redis_${slug}';

// Check if store already exists
\$config = cache_config::instance();
\$stores = \$config->get_all_stores();
if (isset(\$stores[\$instance_name])) {
    mtrace("Redis store '{\$instance_name}' already exists — skipping");
    exit(0);
}

// Configure Redis store with per-site key prefix
\$store_config = [
    'server'     => '127.0.0.1:6379',
    'prefix'     => 'mdl_${slug}_muc_',
    'password'   => '',
    'serializer' => 1,
    'compressor' => 0,
    'timeout'    => 3,
    'readtimeout' => 3,
];

// Add the store instance
\$writer = cache_config_writer::instance();
\$writer->add_store_instance(\$instance_name, 'redis', \$store_config);
mtrace("Redis MUC store '{\$instance_name}' created.");
mtrace("To map it: Site Admin → Plugins → Caching → Configuration → Edit Mappings");
MUCPHP

    # mktemp creates a root-only 0600 file. Moodle runs as www-data, so grant
    # that group read access while keeping the generated script non-writable.
    chown root:www-data "${muc_script}"
    chmod 640 "${muc_script}"

    set +e
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${muc_script}" 2>&1 \
        | tee -a "${_LOG_FILE}"
    local muc_exit="${PIPESTATUS[0]}"
    set -e
    rm -f "${muc_script}"

    if [[ "${muc_exit}" -ne 0 ]]; then
        warn "MUC Redis store setup failed (exit ${muc_exit}) — configure manually in admin"
        return "${muc_exit}"
    fi
    ok "Redis MUC store configured"
    return 0
}

# ---------------------------------------------------------------------------
# Configure task processing
# Was dead code in reference scripts — now actually called
# ---------------------------------------------------------------------------
_configure_task_processing() {
    local admin_cli="$1"
    local task_cfg="${admin_cli}/../tool/task/cli/schedule_task.php"

    if [[ -f "${task_cfg}" ]]; then
        # Set cron keepalive to 0 (don't run indefinitely — each cron run exits)
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${admin_cli}/cfg.php" \
            --name=task_keepalive --set=0 2>&1 | tee -a "${_LOG_FILE}" || true
        ok "Task processing configured"
    fi
}
