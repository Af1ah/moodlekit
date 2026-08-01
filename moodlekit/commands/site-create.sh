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

    # FPM socket
    local FPM_SOCK="/run/php/php${PHP_VERSION}-fpm-moodle_${SLUG}.sock"
    local FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/moodle_${SLUG}.conf"
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

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1/12 — Validate + conflict check
    # ─────────────────────────────────────────────────────────────────────────
    step 1 12 "Validate slug and check conflicts"
    check_slug_conflicts "${SLUG}"
    check_disk_space "/var/www" 3
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
    chown -R root:www-data "${MOODLE_DIR}"
    find "${MOODLE_DIR}" -type d -exec chmod 755 {} \;
    find "${MOODLE_DIR}" -type f -exec chmod 644 {} \;

    # moodledata: fully writable by www-data
    mkdir -p "${MOODLEDATA_DIR}"
    chown -R www-data:www-data "${MOODLEDATA_DIR}"
    chmod -R 02777 "${MOODLEDATA_DIR}"
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
    num_sites="$(find "${MOODLEKIT_SITES_DIR}" -name '*.conf' -type f 2>/dev/null | wc -l)"
    num_sites=$(( num_sites + 1 ))  # include this new site

    calculate_tuning "balanced" "${num_sites}" "${DB_TYPE}"

    render_template_to_file "${MOODLEKIT_TPL}/fpm-pool.conf.tpl" "${FPM_POOL_CONF}" \
        "SLUG=${SLUG}" \
        "PHP_VERSION=${PHP_VERSION}" \
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
        "SLUG=${SLUG}"

    # For initial HTTP-only (before certbot), strip TLS directives temporarily
    # We use a simpler HTTP-only block first for certbot ACME challenge
    cat > "${NGINX_CONF}.http-only" << HTTPONLY
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${IS_MOODLE5:+${MOODLE_DIR}/public}${IS_MOODLE5:-${MOODLE_DIR}};

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
        if ! certbot certonly \
            --webroot \
            --webroot-path /var/www/letsencrypt \
            --domain "${DOMAIN}" \
            --email "${LETSENCRYPT_EMAIL}" \
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

        sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${installer}" \
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
            --non-interactive 2>&1 | tee -a "${_LOG_FILE}"

        # Lock ownership back to root for security
        chown root "${MOODLE_DIR}"

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
        _configure_muc_redis "${SLUG}" "${MOODLE_DIR}" "${IS_MOODLE5}"
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

    # Save site state
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

    clear_rollbacks

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
    local is_moodle5="${3:-0}"

    local cron_php="${moodle_dir}/admin/cli/cron.php"

    if [[ ! -f "${cron_php}" ]]; then
        err "Moodle cron.php not found: ${cron_php}"
        exit 1
    fi

    # Calculate stagger offset: 12 seconds per existing site
    local existing
    existing="$(find "${MOODLEKIT_SITES_DIR}" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l)"
    local offset=$(( (existing * 12) % 60 ))

    # Lock file uses SLUG (not SITE_SLUG — BUG FIX from reference scripts)
    local lock_file="/tmp/moodlekit-${slug}.lock"

    cat > "/etc/cron.d/moodlekit-${slug}" << CRONFILE
# MoodleKit cron — ${slug} — stagger offset: ${offset}s
# Generated: $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * www-data sleep ${offset} && flock -n ${lock_file} /usr/bin/php${PHP_VERSION} ${cron_php} >> /var/log/moodlekit/${slug}-cron.log 2>&1
CRONFILE
    chmod 644 "/etc/cron.d/moodlekit-${slug}"
    register_rollback "rm -f '/etc/cron.d/moodlekit-${slug}'"
    ok "Cron configured (offset: ${offset}s, lock: ${lock_file})"
}

# ---------------------------------------------------------------------------
# Configure MUC Redis store — creates store instance in Moodle
# ---------------------------------------------------------------------------
_configure_muc_redis() {
    local slug="$1"
    local moodle_dir="$2"
    local is_moodle5="${3:-0}"

    local php_script="${moodle_dir}/admin/cli"

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
cache_config_writer::add_store_instance(\$instance_name, 'redis', \$store_config);
mtrace("Redis MUC store '{\$instance_name}' created.");
mtrace("To map it: Site Admin → Plugins → Caching → Configuration → Edit Mappings");
MUCPHP

    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${muc_script}" 2>&1 \
        | tee -a "${_LOG_FILE}" || warn "MUC Redis store setup failed — configure manually in admin"
    rm -f "${muc_script}"
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
