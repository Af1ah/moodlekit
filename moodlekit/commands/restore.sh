#!/usr/bin/env bash
# =============================================================================
# commands/restore.sh — 2-method Moodle restore
# =============================================================================
# Method 1: In-place — restores DB + moodledata into existing site
# Method 2: Fresh — provisions a brand-new site from backup manifest
# =============================================================================

cmd_restore() {
    require_root
    load_global_conf

    local SLUG="${1:-}"
    local BACKUP_PATH="${2:-}"

    if [[ "${SLUG}" == "manual" ]]; then
        _restore_manual
        return 0
    fi

    [[ -z "${SLUG}" || -z "${BACKUP_PATH}" ]] && {
        err "Usage: moodlekit restore <slug> <backup-path>"
        err "   Or: moodlekit restore manual (for interactive recovery from raw files)"
        exit 1
    }

    [[ -d "${BACKUP_PATH}" ]] || { err "Backup directory not found: ${BACKUP_PATH}"; exit 1; }

    local MANIFEST="${BACKUP_PATH}/manifest.json"
    [[ -f "${MANIFEST}" ]] || { err "No manifest.json in ${BACKUP_PATH}"; exit 1; }

    init_logging "restore-${SLUG}"
    section "MoodleKit — Restore: ${SLUG}"

    # Parse manifest
    local bk_db_type bk_moodle_version bk_is_moodle5 bk_php_version
    local bk_domain bk_moodle_dir bk_moodledata_dir bk_db_name
    bk_db_type="$(grep -o '"db_type": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_moodle_version="$(grep -o '"moodle_version": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_is_moodle5="$(grep -o '"is_moodle5": *[0-9]*' "${MANIFEST}" | grep -o '[0-9]*')"
    bk_php_version="$(grep -o '"php_version": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_domain="$(grep -o '"domain": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_moodle_dir="$(grep -o '"moodle_dir": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_moodledata_dir="$(grep -o '"moodledata_dir": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"
    bk_db_name="$(grep -o '"db_name": *"[^"]*"' "${MANIFEST}" | cut -d'"' -f4)"

    info "Backup details:"
    echo "  Moodle version: ${bk_moodle_version}"
    echo "  DB type:        ${bk_db_type}"
    echo "  PHP version:    ${bk_php_version}"
    echo "  Original domain:${bk_domain}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # Select restore method
    # ─────────────────────────────────────────────────────────────────────────
    local method="${OPT_METHOD:-}"
    if [[ -z "${method}" ]]; then
        local method_choice=""
        select_one method_choice "Select restore method:" \
            "Method 1: In-place — restore into existing site '${SLUG}'" \
            "Method 2: Fresh instance — create new site from backup"
        [[ "${method_choice}" == *"Method 1"* ]] && method="inplace"
        [[ "${method_choice}" == *"Method 2"* ]] && method="fresh"
    fi

    case "${method}" in
        inplace|1) _restore_inplace "${SLUG}" "${BACKUP_PATH}" "${bk_db_type}" "${bk_moodle_version}" "${bk_is_moodle5}" ;;
        fresh|2)   _restore_fresh   "${SLUG}" "${BACKUP_PATH}" "${bk_db_type}" "${bk_moodle_version}" "${bk_is_moodle5}" "${bk_php_version}" "${bk_domain}" ;;
        *) err "Invalid method '${method}'. Use 'inplace' or 'fresh'"; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Method 1: In-place restore
# ---------------------------------------------------------------------------
_restore_inplace() {
    local slug="$1"
    local backup_path="$2"
    local bk_db_type="$3"
    local bk_moodle_version="$4"
    local bk_is_moodle5="$5"

    # Site must exist
    site_exists "${slug}" || {
        err "Site '${slug}' does not exist. Use Method 2 (fresh) to create from backup."
        exit 1
    }
    load_site_conf "${slug}"

    # DB type must match
    if [[ "${bk_db_type}" != "${DB_TYPE}" ]]; then
        err "DB type mismatch: backup is '${bk_db_type}', current site uses '${DB_TYPE}'."
        err "Cross-database restore is not supported."
        exit 1
    fi

    section "Restore Method 1: In-place into '${slug}'"
    warn "This will REPLACE the database and moodledata for '${slug}'."
    confirm "Proceed?" "y"    # Define paths
    local admin_cli="${MOODLE_DIR}/$([ "${IS_MOODLE5:-0}" -eq 1 ] && echo "public/")admin/cli"
    local dump_file="${backup_path}/database.sql.gz"
    local data_archive="${backup_path}/moodledata.tar.gz"

    # ── Step 1: Maintenance mode ───────────────────────────────────────────
    step 1 6 "Enable maintenance mode"
    [[ -f "${admin_cli}/maintenance.php" ]] && \
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
        "${admin_cli}/maintenance.php" --enable 2>/dev/null || true
    ok "Maintenance mode ON"

    # ── Step 2: Restore database ───────────────────────────────────────────
    step 2 6 "Restore database"
    [[ -f "${dump_file}" ]] || { err "No database.sql.gz in backup"; exit 1; }

    case "${DB_TYPE}" in
        postgres)
            sudo -u postgres psql -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" 2>/dev/null || true
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null || true
            sudo -u postgres psql -c \
                "CREATE DATABASE ${DB_NAME} WITH OWNER=${DB_USER} ENCODING='UTF8' TEMPLATE=template0;" 2>/dev/null
            db_pg_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
        mariadb)
            mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
            mysql -u root -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4;" 2>/dev/null
            mysql -u root -e "GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" 2>/dev/null
            db_maria_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
        mysql)
            mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
            mysql -u root -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4;" 2>/dev/null
            mysql -u root -e "GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';" 2>/dev/null
            db_mysql_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
    esac

    # ── Step 3: Restore moodledata ─────────────────────────────────────────
    step 3 6 "Restore moodledata"
    if [[ -f "${data_archive}" ]]; then
        spinner_start "Extracting moodledata..."
        rm -rf "${MOODLEDATA_DIR}"
        mkdir -p "$(dirname "${MOODLEDATA_DIR}")"
        tar --extract --gzip \
            --file="${data_archive}" \
            --directory="$(dirname "${MOODLEDATA_DIR}")"
        chown -R www-data:www-data "${MOODLEDATA_DIR}"
        spinner_stop 0 "moodledata restored"
    else
        warn "No moodledata.tar.gz found — skipping data restore"
    fi

    # ── Step 4: Purge caches ───────────────────────────────────────────────
    step 4 6 "Purge caches"
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
        "${admin_cli}/purge_caches.php" 2>/dev/null || true
    ok "Caches purged"

    # ── Step 5: Upgrade if version differs ────────────────────────────────
    step 5 6 "Run upgrade check"
    if [[ "${bk_moodle_version}" != "${MOODLE_VERSION}" ]]; then
        warn "Version mismatch (backup: ${bk_moodle_version}, current: ${MOODLE_VERSION})"
        info "Running Moodle upgrade..."
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
    else
        ok "No upgrade needed (same version)"
    fi

    # ── Step 6: Disable maintenance ────────────────────────────────────────
    step 6 6 "Disable maintenance mode"
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
        "${admin_cli}/maintenance.php" --disable 2>/dev/null || true
    ok "Site '${slug}' restored and online"

    print_box "Restore Complete: ${slug} ✓" \
        "URL:    https://${DOMAIN}" \
        "Method: In-place" \
        "Log:    ${_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Method 2: Fresh instance from backup
# ---------------------------------------------------------------------------
_restore_fresh() {
    local slug="$1"
    local backup_path="$2"
    local bk_db_type="$3"
    local bk_moodle_version="$4"
    local bk_is_moodle5="$5"
    local bk_php_version="$6"
    local bk_domain="$7"

    local dump_file="${backup_path}/database.sql.gz"
    local data_archive="${backup_path}/moodledata.tar.gz"
    local code_archive="${backup_path}/code.tar.gz"

    _do_fresh_provisioning "${slug}" "${dump_file}" "${data_archive}" "${code_archive}" \
        "${bk_db_type}" "${bk_moodle_version}" "${bk_is_moodle5}" "${bk_php_version}" "${bk_domain}" "${backup_path}"
}

# ---------------------------------------------------------------------------
# Method 3: Manual / Legacy Restore
# ---------------------------------------------------------------------------
_restore_manual() {
    section "Restore Method 3: Manual / Legacy Recovery"
    info "Use this method if you are recovering from a crash and only have raw .sql and data files."

    local slug=""
    input_text slug "Enter site slug (e.g. mysite)" "" '^[a-z][a-z0-9-]{2,19}$' "Invalid slug format"

    local dump_file=""
    input_path dump_file "Path to .sql or .sql.gz file [leave blank to skip]" "" "1"
    if [[ -n "${dump_file}" && ! -f "${dump_file}" ]]; then
        err "File not found: ${dump_file}"
        exit 1
    fi

    local data_archive=""
    input_path data_archive "Path to moodledata archive (.tar.gz) or raw data directory [leave blank to skip]" "" "1"
    if [[ -n "${data_archive}" && ! -f "${data_archive}" && ! -d "${data_archive}" ]]; then
        err "Not found (file or directory): ${data_archive}"
        exit 1
    fi

    local full_domain=""
    input_text full_domain "Full domain (e.g. site.example.com)" "${slug}.${BASE_DOMAIN:-example.com}" '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' "Invalid domain"

    local bk_db_type=""
    select_one bk_db_type "Select Database Type inside backup:" "postgres" "mariadb" "mysql"
    bk_db_type=$(echo "${bk_db_type}" | awk '{print $1}')

    local bk_moodle_version=""
    select_one bk_moodle_version "Select Moodle Version:" "5.2" "4.5"
    bk_moodle_version=$(echo "${bk_moodle_version}" | awk '{print $1}')

    local bk_php_version=""
    select_one bk_php_version "Select PHP Version:" "8.4" "8.3" "8.1"
    bk_php_version=$(echo "${bk_php_version}" | awk '{print $1}')

    local bk_is_moodle5=0
    [[ "${bk_moodle_version}" == *"5."* ]] && bk_is_moodle5=1

    _do_fresh_provisioning "${slug}" "${dump_file}" "${data_archive}" "" \
        "${bk_db_type}" "${bk_moodle_version}" "${bk_is_moodle5}" "${bk_php_version}" "${full_domain}" "manual"
}

# ---------------------------------------------------------------------------
# Core Provisioning Logic for Fresh & Manual Restores
# ---------------------------------------------------------------------------
_do_fresh_provisioning() {
    local slug="$1"
    local dump_file="$2"
    local data_archive="$3"
    local code_archive="$4"
    local bk_db_type="$5"
    local bk_moodle_version="$6"
    local bk_is_moodle5="$7"
    local bk_php_version="$8"
    local bk_domain="$9"
    local backup_path="${10}"

    # Use different slug if site already exists
    if site_exists "${slug}"; then
        warn "Site '${slug}' already exists."
        local new_slug="${slug}-restored"
        input_text slug "Choose new slug for restored site" "${new_slug}" \
            '^[a-z][a-z0-9-]{2,19}$' "Invalid slug format"
    fi

    init_logging "restore-fresh-${slug}"
    section "Provisioning fresh instance '${slug}'"

    local DOMAIN="${bk_domain}"
    
    local SKIP_TLS=0
    # Auto-skip TLS for local/testing domains
    if [[ "${DOMAIN}" == *.local || "${DOMAIN}" == *.test || "${DOMAIN}" == "localhost" || "${DOMAIN}" != *.* ]]; then
        SKIP_TLS=1
    fi
    
    local MOODLE_DIR="/var/www/moodle/${slug}"
    local MOODLEDATA_DIR="/var/moodledata/${slug}"
    local DB_NAME="moodle_${slug}"
    local DB_USER="moodle_${slug}"
    local DB_PASS="$(gen_password 24)"
    local IS_MOODLE5="${bk_is_moodle5}"
    local MOODLE_VERSION="${bk_moodle_version}"
    local PHP_VERSION="${bk_php_version:-${PHP_VERSION}}"

    local NGINX_CONF="/etc/nginx/sites-available/moodle-${slug}"
    local FPM_SOCK="/run/php/php${PHP_VERSION}-fpm-moodle_${slug}.sock"
    local FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/moodle_${slug}.conf"
    local ADMIN_CLI="${MOODLE_DIR}/$([ "${IS_MOODLE5}" -eq 1 ] && echo "public/")admin/cli"

    # ── Resume detection ───────────────────────────────────────────────────
    local SKIP_DB_PROVISION=0
    local SKIP_DB_IMPORT=0
    local SKIP_CLONE=0
    local SKIP_MOODLEDATA=0

    # 1. Database check
    local db_exists=0
    case "${bk_db_type}" in
        postgres) sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DB_NAME}" && db_exists=1 ;;
        mariadb|mysql) mysql -u root -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null | grep -qw "${DB_NAME}" && db_exists=1 ;;
    esac

    if [[ "${db_exists}" -eq 1 ]]; then
        warn "Database '${DB_NAME}' already exists."
        local db_action=""
        select_one db_action "How to handle existing database?" \
            "Keep it and skip import (resume)" \
            "Drop and recreate (fresh import)" \
            "Abort"
        case "${db_action}" in
            *Keep*) 
                SKIP_DB_PROVISION=1
                SKIP_DB_IMPORT=1 
                ;;
            *Drop*) 
                SKIP_DB_PROVISION=0
                SKIP_DB_IMPORT=0 
                info "Dropping existing database '${DB_NAME}'..."
                case "${bk_db_type}" in
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
        
        [[ -n "${ex_db_name}" ]] && DB_NAME="${ex_db_name}"
        [[ -n "${ex_db_user}" ]] && DB_USER="${ex_db_user}"
        [[ -n "${ex_db_pass}" ]] && DB_PASS="${ex_db_pass}"
        [[ -n "${ex_domain}" ]] && DOMAIN="${ex_domain}"
    fi

    # 3. Moodle Dir check
    if [[ -d "${MOODLE_DIR}" && "$(ls -A "${MOODLE_DIR}" 2>/dev/null)" ]]; then
        warn "Directory ${MOODLE_DIR} already contains files."
        if confirm "Skip Moodle source code extraction/cloning?" "y"; then
            SKIP_CLONE=1
        fi
    fi

    # 4. Moodledata check
    if [[ -d "${MOODLEDATA_DIR}" && "$(ls -A "${MOODLEDATA_DIR}" 2>/dev/null)" ]]; then
        warn "Directory ${MOODLEDATA_DIR} already contains files."
        if confirm "Skip moodledata extraction?" "y"; then
            SKIP_MOODLEDATA=1
        fi
    fi

    # ── Step 1: Provision database ─────────────────────────────────────────
    step 1 10 "Provision database"
    if [[ "${SKIP_DB_PROVISION}" -eq 1 ]]; then
        info "Skipped (using existing database)"
    else
        case "${bk_db_type}" in
            postgres) db_pg_create "${slug}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" ;;
            mariadb)  db_maria_create "${slug}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" ;;
            mysql)    db_mysql_create "${slug}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" ;;
        esac
        register_rollback "_db_drop_by_type '${bk_db_type}' '${DB_NAME}' '${DB_USER}'"
    fi

    # ── Step 2: Import database ────────────────────────────────────────────
    step 2 10 "Import database"
    if [[ "${SKIP_DB_IMPORT}" -eq 1 ]]; then
        info "Skipped (using existing database data)"
    elif [[ -z "${dump_file}" || ! -f "${dump_file}" ]]; then
        info "No database dump file provided, skipping import"
    else
        local actual_dump="${dump_file}"
        if [[ "${dump_file}" == *.sql ]]; then
            info "Compressing raw SQL on the fly..."
            actual_dump="$(mktemp --suffix=.sql.gz)"
            gzip -c "${dump_file}" > "${actual_dump}"
            register_rollback "rm -f '${actual_dump}'"
        fi
        
        case "${bk_db_type}" in
            postgres) db_pg_restore    "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${actual_dump}" ;;
            mariadb)  db_maria_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${actual_dump}" ;;
            mysql)    db_mysql_restore  "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${actual_dump}" ;;
        esac
    fi

    # ── Step 3: Download Moodle ────────────────────────────────────────────
    step 3 10 "Download Moodle (${MOODLE_VERSION})"
    if [[ "${SKIP_CLONE}" -eq 1 ]]; then
        info "Skipped (using existing files in ${MOODLE_DIR})"
    else
        mkdir -p "${MOODLE_DIR}"
        register_rollback "rm -rf '${MOODLE_DIR}'"

        if [[ -f "${code_archive}" ]]; then
            spinner_start "Extracting code archive..."
            tar --extract --gzip \
                --file="${code_archive}" \
                --directory="$(dirname "${MOODLE_DIR}")"
            # Rename if slug differs from backup
            local extracted_dir
            extracted_dir="$(tar -tzf "${code_archive}" | head -1 | cut -f1 -d"/")"
            if [[ -n "${extracted_dir}" && "${extracted_dir}" != "${slug}" ]]; then
                mv "$(dirname "${MOODLE_DIR}")/${extracted_dir}" "${MOODLE_DIR}"
            fi
            spinner_stop 0 "Code extracted from archive"
        else
            # Clone fresh matching version
            local branch="$(moodle_version_to_branch "${bk_moodle_version}")"
            info "No code archive — cloning Moodle ${bk_moodle_version}..."
            git clone --depth 1 --branch "${branch}" \
                https://github.com/moodle/moodle.git "${MOODLE_DIR}"

            # Run Composer if needed
            local composer_json="${MOODLE_DIR}/composer.json"
            if [[ -f "${composer_json}" ]]; then
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
    fi

    # ── Step 4: Restore moodledata ─────────────────────────────────────────
    step 4 10 "Restore moodledata"
    if [[ "${SKIP_MOODLEDATA}" -eq 1 ]]; then
        info "Skipped (using existing moodledata)"
    else
        mkdir -p "$(dirname "${MOODLEDATA_DIR}")"
        if [[ -f "${data_archive}" ]]; then
            # Archive: extract .tar.gz
            spinner_start "Extracting moodledata archive..."
            tar --extract --gzip \
                --file="${data_archive}" \
                --directory="$(dirname "${MOODLEDATA_DIR}")"
            spinner_stop 0 "moodledata extracted"
        elif [[ -d "${data_archive}" ]]; then
            # Raw directory: copy in place
            spinner_start "Copying raw moodledata directory..."
            rm -rf "${MOODLEDATA_DIR}"
            cp -a "${data_archive}" "${MOODLEDATA_DIR}"
            spinner_stop 0 "moodledata copied"
        else
            # Nothing provided: create an empty data dir
            warn "No moodledata source provided — creating empty data directory."
            mkdir -p "${MOODLEDATA_DIR}"
        fi
        chown -R www-data:www-data "${MOODLEDATA_DIR}"
        chmod -R 02777 "${MOODLEDATA_DIR}"
        register_rollback "rm -rf '${MOODLEDATA_DIR}'"
        ok "moodledata ready"
    fi

    # ── Step 5: Generate config.php ────────────────────────────────────────
    step 5 10 "Generate config.php"
    local moodle_dbtype
    case "${bk_db_type}" in
        postgres) moodle_dbtype="pgsql"   ;;
        mariadb)  moodle_dbtype="mariadb" ;;
        mysql)    moodle_dbtype="mysqli"  ;;
    esac
    local DB_PORT="5432"
    [[ "${bk_db_type}" != "postgres" ]] && DB_PORT="3306"

    local tpl="${MOODLEKIT_TPL}/config-moodle5.php.tpl"
    [[ "${IS_MOODLE5}" -ne 1 ]] && tpl="${MOODLEKIT_TPL}/config-moodle4.php.tpl"

    local cache_block=""
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        cache_block+="
// ── Redis Session Handler ─────────────────────────────────────────────────
\$CFG->session_handler_class = '\core\session\redis';
\$CFG->session_redis_host    = '127.0.0.1';
\$CFG->session_redis_port    = 6379;
\$CFG->session_redis_database = 0;
\$CFG->session_redis_prefix  = 'mdl_${slug}_sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire          = 7200;
\$CFG->session_redis_serializer_use_igbinary = false;"
    fi

    if [[ "${USE_MEMCACHED:-0}" == "1" ]]; then
        cache_block+="
// ── Memcached (MUC Application Cache — sessions handled by Redis) ─────────
// Store instance 'memcached_muc' configured below.
// MUC mapping is done via Site Admin → Plugins → Caching → Configuration"
    fi

    render_template_to_file "${tpl}" "${MOODLE_DIR}/config.php" \
        "SLUG=${slug}" \
        "DB_TYPE=${moodle_dbtype}" \
        "DB_NAME=${DB_NAME}" \
        "DB_USER=${DB_USER}" \
        "DB_PASS=${DB_PASS}" \
        "DB_PORT=${DB_PORT}" \
        "DOMAIN=${DOMAIN}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "PHP_VERSION=${PHP_VERSION}" \
        "CACHE_CONFIG=${cache_block}"

    chown root:www-data "${MOODLE_DIR}/config.php"
    chmod 640 "${MOODLE_DIR}/config.php"
    ok "config.php generated"

    # MUC Redis setup — create store instance programmatically
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        _configure_muc_redis "${slug}" "${MOODLE_DIR}" "${IS_MOODLE5}"
    fi

    # ── Step 6: Permissions ────────────────────────────────────────────────
    step 6 10 "Set permissions"
    chown -R root:www-data "${MOODLE_DIR}"
    find "${MOODLE_DIR}" -type d -exec chmod 755 {} \;
    find "${MOODLE_DIR}" -type f -exec chmod 644 {} \;
    chown root:www-data "${MOODLE_DIR}/config.php"
    chmod 640 "${MOODLE_DIR}/config.php"
    ok "Permissions set"

    # ── Step 7: FPM pool + Nginx HTTP ──────────────────────────────────────
    step 7 10 "FPM pool + Nginx vhost"
    local num_sites
    num_sites="$(list_site_slugs | wc -l)"
    num_sites=$(( num_sites + 1 ))
    calculate_tuning "balanced" "${num_sites}" "${bk_db_type}"

    render_template_to_file "${MOODLEKIT_TPL}/fpm-pool.conf.tpl" "${FPM_POOL_CONF}" \
        "SLUG=${slug}" "PHP_VERSION=${PHP_VERSION}" \
        "MAX_CHILDREN=${TUNE_FPM_MAX_CHILDREN}" "START_SERVERS=${TUNE_FPM_START_SERVERS}" \
        "MIN_SPARE=${TUNE_FPM_MIN_SPARE}" "MAX_SPARE=${TUNE_FPM_MAX_SPARE}" \
        "MOODLE_DIR=${MOODLE_DIR}" "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "TIMEZONE=UTC" "TIMESTAMP=$(date)"
    reload_fpm "${PHP_VERSION}"
    wait_for_fpm_socket "${FPM_SOCK}" 30

    local nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
    [[ "${IS_MOODLE5}" -eq 1 ]] && nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"

    render_template_to_file "${nginx_tpl}" "${NGINX_CONF}" \
        "DOMAIN=${DOMAIN}" "MOODLE_DIR=${MOODLE_DIR}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" "PHP_VERSION=${PHP_VERSION}" "SLUG=${slug}"

    # For initial HTTP-only (before certbot), strip TLS directives temporarily
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

    ln -sf "${NGINX_CONF}.http-only" "/etc/nginx/sites-enabled/moodle-${slug}"
    register_rollback "rm -f '${NGINX_CONF}' '${NGINX_CONF}.http-only' '/etc/nginx/sites-enabled/moodle-${slug}'"
    reload_nginx
    ok "Nginx HTTP vhost active"

    # ── Step 8: TLS certificate ────────────────────────────────────────────
    step 8 10 "TLS certificate"
    if [[ "${SKIP_TLS}" == "1" ]]; then
        warn "TLS skipped (local domain). Site will use HTTPS with a self-signed fallback."
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

    ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/moodle-${slug}"
    reload_nginx

    # ── Step 9: Run upgrade ────────────────────────────────────────────────
    step 9 10 "Moodle upgrade"
    if [[ -f "${ADMIN_CLI}/upgrade.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${ADMIN_CLI}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}" || true
    else
        warn "upgrade.php not found at ${ADMIN_CLI}, skipping upgrade"
    fi

    # ── Step 10: Cron + State ───────────────────────────────────────────────
    step 10 10 "Cron + Save state"
    _configure_task_processing "${ADMIN_CLI}"
    _configure_cron "${slug}" "${MOODLE_DIR}" "${IS_MOODLE5}"

    cat > "${MOODLEKIT_SITES_DIR}/${slug}.conf" << SITECONF
SLUG="${slug}"
DOMAIN="${DOMAIN}"
MOODLE_VERSION="${MOODLE_VERSION}"
IS_MOODLE5="${IS_MOODLE5}"
MOODLE_DIR="${MOODLE_DIR}"
MOODLEDATA_DIR="${MOODLEDATA_DIR}"
DB_TYPE="${bk_db_type}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_PORT="${DB_PORT}"
PHP_VERSION="${PHP_VERSION}"
FPM_POOL_CONF="${FPM_POOL_CONF}"
FPM_SOCK="${FPM_SOCK}"
NGINX_CONF="${NGINX_CONF}"
USE_REDIS_SESSIONS="${USE_REDIS:-0}"
RESTORED_FROM="${backup_path}"
CREATED_AT="$(date -Iseconds)"
SITECONF
    chmod 600 "${MOODLEKIT_SITES_DIR}/${slug}.conf"
    clear_rollbacks

    print_box "Restore Complete: ${slug} ✓" \
        "URL:    https://${DOMAIN}" \
        "Method: Fresh instance from backup/manual" \
        "Log:    ${_LOG_FILE}"
}

# Helper for rollback
_db_drop_by_type() {
    local db_type="$1" db_name="$2" db_user="$3"
    case "${db_type}" in
        postgres) db_pg_drop    "${db_name}" "${db_user}" ;;
        mariadb)  db_maria_drop "${db_name}" "${db_user}" ;;
        mysql)    db_mysql_drop "${db_name}" "${db_user}" ;;
    esac
}
