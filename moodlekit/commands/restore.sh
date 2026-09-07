#!/usr/bin/env bash
# =============================================================================
# commands/restore.sh — 2-method Moodle restore
# =============================================================================
# Method 1: In-place — restores DB + moodledata into existing site
# Method 2: Fresh — provisions a brand-new site from backup manifest
# =============================================================================

cmd_restore() {
    require_root
    # Rollback snapshots and imported recovery configuration contain database
    # contents and credentials. Keep all newly-created restore artifacts private.
    umask 077
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

    validate_backup_bundle "${BACKUP_PATH}"

    # Parse manifest
    local bk_db_type bk_moodle_version bk_is_moodle5 bk_php_version
    local bk_domain bk_moodle_dir bk_moodledata_dir bk_db_name
    bk_db_type="$(jq -er '.db_type' "${MANIFEST}")"
    bk_moodle_version="$(jq -er '.moodle_version' "${MANIFEST}")"
    bk_is_moodle5="$(jq -r '.is_moodle5 // 0 | if . == true then 1 elif . == false then 0 else . end' "${MANIFEST}")"
    bk_php_version="$(jq -er '.php_version' "${MANIFEST}")"
    bk_domain="$(jq -r '.domain // ""' "${MANIFEST}")"
    bk_moodle_dir="$(jq -r '.moodle_dir // ""' "${MANIFEST}")"
    bk_moodledata_dir="$(jq -r '.moodledata_dir // ""' "${MANIFEST}")"
    bk_db_name="$(jq -r '.db_name // ""' "${MANIFEST}")"

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
    validate_site_runtime "${slug}"
    acquire_lock "site-${slug}"
    state_operation_start "restore-inplace" "${slug}" "$(jq -nc --arg backup_path "${backup_path}" '{backup_path:$backup_path}')"

    # DB type must match
    if [[ "${bk_db_type}" != "${DB_TYPE}" ]]; then
        err "DB type mismatch: backup is '${bk_db_type}', current site uses '${DB_TYPE}'."
        err "Cross-database restore is not supported."
        exit 1
    fi

    section "Restore Method 1: In-place into '${slug}'"
    warn "This will REPLACE the database and moodledata for '${slug}'."
    info "A verified safety snapshot of the current database, config, and moodledata will be created first."
    confirm_destructive "In-place restore is destructive." "restore-${slug}"
    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    local dump_file="${backup_path}/database.sql.gz"
    local data_archive="${backup_path}/moodledata.tar.gz"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local safety_path="${MOODLEKIT_BACKUP_DIR}/${slug}/pre_restore_${timestamp}"

    # ── Step 1: Maintenance mode ───────────────────────────────────────────
    step 1 9 "Enable and verify maintenance mode"
    enable_moodle_maintenance "${admin_cli}" "${PHP_VERSION}"

    # ── Step 2: Safety snapshot ────────────────────────────────────────────
    step 2 9 "Create rollback snapshot of current site"
    mkdir -p "${safety_path}"
    dump_site_database "${safety_path}/database.sql.gz"
    local config_file
    config_file="$(find_moodle_config_file "${MOODLE_DIR}")"
    [[ -n "${config_file}" && -f "${config_file}" ]] && cp -a "${config_file}" "${safety_path}/config.php"
    if [[ -d "${MOODLEDATA_DIR}" ]]; then
        tar --create --gzip --file="${safety_path}/moodledata.tar.gz" \
            --exclude="${MOODLEDATA_DIR}/cache" \
            --exclude="${MOODLEDATA_DIR}/localcache" \
            --exclude="${MOODLEDATA_DIR}/sessions" \
            --exclude="${MOODLEDATA_DIR}/temp" \
            --directory="$(dirname "${MOODLEDATA_DIR}")" "$(basename "${MOODLEDATA_DIR}")"
        gzip -t "${safety_path}/moodledata.tar.gz"
    fi
    chmod 600 "${safety_path}"/* 2>/dev/null || true
    RESTORE_SAFETY_PATH="${safety_path}"
    RESTORE_SAFETY_ADMIN_CLI="${admin_cli}"
    register_rollback "_rollback_inplace_restore"
    ok "Rollback snapshot verified: ${safety_path}"

    # ── Step 3: Restore database ───────────────────────────────────────────
    step 3 9 "Replace database from verified backup"
    [[ -f "${dump_file}" ]] || { err "No database.sql.gz in backup"; exit 1; }
    _replace_database_from_dump "${dump_file}"

    # ── Step 4: Restore moodledata ─────────────────────────────────────────
    step 4 9 "Replace moodledata from verified archive"
    if [[ -f "${data_archive}" ]]; then
        spinner_start "Extracting moodledata..."
        _extract_archive_to_target "${data_archive}" "${MOODLEDATA_DIR}"
        chown -R www-data:www-data "${MOODLEDATA_DIR}"
        spinner_stop 0 "moodledata restored"
    else
        warn "No moodledata.tar.gz found — skipping data restore"
    fi

    # ── Step 4: Purge caches ───────────────────────────────────────────────
    step 5 9 "Purge caches"
    if [[ -f "${admin_cli}/purge_caches.php" ]]; then
        if sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/purge_caches.php" >> "${_LOG_FILE}" 2>&1; then
            ok "Caches purged"
        else
            warn "Cache purge returned an error; continuing because caches can be rebuilt. See ${_LOG_FILE}."
        fi
    else
        warn "Cache purge CLI not found: ${admin_cli}/purge_caches.php"
    fi

    # ── Step 5: Upgrade if version differs ────────────────────────────────
    step 6 9 "Run upgrade check"
    if [[ "${bk_moodle_version}" != "${MOODLE_VERSION}" ]]; then
        warn "Version mismatch (backup: ${bk_moodle_version}, current: ${MOODLE_VERSION})"
        info "Running Moodle upgrade..."
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
    else
        ok "No upgrade needed (same version)"
    fi

    # ── Step 7: Verify the existing Nginx config ───────────────────────────
    step 7 9 "Preserve and verify Nginx configuration"
    # In-place restore does not change the domain, code tree, PHP pool, or TLS
    # policy. Re-rendering here used to discard Certbot/self-signed changes and
    # could leave Nginx pointing at certificate files that do not exist.
    [[ -n "${NGINX_CONF:-}" && -f "${NGINX_CONF}" ]] || {
        err "Managed Nginx configuration is missing: ${NGINX_CONF:-<unset>}"
        return 1
    }
    reload_nginx
    ok "Existing TLS-aware Nginx configuration preserved"

    # ── Step 7: Cron + Task Processing ─────────────────────────────────────
    step 8 9 "Configure and verify cron"
    _configure_task_processing "${admin_cli}"
    _configure_cron "${slug}" "${MOODLE_DIR}" "${IS_MOODLE5}"
    ok "Cron configured"

    # ── Step 8: Disable maintenance ────────────────────────────────────────
    step 9 9 "Disable maintenance mode and finalize state"
    disable_moodle_maintenance "${admin_cli}" "${PHP_VERSION}"
    release_lock
    clear_rollbacks
    local current_site_json
    current_site_json="$(vault_sget "${slug}")"
    [[ -z "${current_site_json}" ]] || state_site_upsert "${current_site_json}"
    state_operation_finish "completed" "In-place restore completed; safety snapshot: ${safety_path}"
    ok "Site '${slug}' restored and online"

    print_box "Restore Complete: ${slug} ✓" \
        "URL:    https://${DOMAIN}" \
        "Method: In-place" \
        "Safety: ${safety_path}" \
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
    if [[ -n "${data_archive}" && -f "${data_archive}" ]]; then
        python3 "${MOODLEKIT_LIB}/safety.py" validate-archive "${data_archive}" >/dev/null
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

    # Never reuse an existing site's resources. Repeated unattended restores
    # get a deterministic free suffix; interactive users can choose another
    # value, which is checked again before provisioning starts.
    local requested_slug="${slug}"
    local suffix candidate selected_slug
    local restore_number=1
    while site_exists "${slug}"; do
        warn "Site '${slug}' already exists."
        suffix="-restored"
        (( restore_number > 1 )) && suffix="-restored${restore_number}"
        candidate="${requested_slug:0:$((20 - ${#suffix}))}${suffix}"
        selected_slug="${candidate}"
        input_text selected_slug "Choose a unique slug for restored site" "${candidate}" \
            '^[a-z][a-z0-9-]{2,19}$' "Invalid slug format"
        slug="${selected_slug}"
        (( restore_number++ )) || true
    done

    local DOMAIN="${OPT_DOMAIN:-${bk_domain}}"
    if [[ -z "${DOMAIN}" ]]; then
        DOMAIN="${slug}.${BASE_DOMAIN:-local}"
    fi
    validate_domain "${DOMAIN}"

    local domain_owner=""
    domain_owner="$(site_slug_for_domain "${DOMAIN}" || true)"
    if [[ -n "${domain_owner}" && "${domain_owner}" != "${slug}" ]]; then
        if [[ -n "${OPT_DOMAIN:-}" ]]; then
            err "Domain '${DOMAIN}' is already assigned to managed site '${domain_owner}'."
            return 1
        fi
        local replacement_domain="${slug}.${BASE_DOMAIN:-local}"
        warn "Backup domain '${DOMAIN}' is already used by '${domain_owner}'."
        input_text DOMAIN "Enter a different domain for the restored site" "${replacement_domain}" \
            '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' "Invalid domain"
        validate_domain "${DOMAIN}"
        domain_owner="$(site_slug_for_domain "${DOMAIN}" || true)"
        [[ -z "${domain_owner}" || "${domain_owner}" == "${slug}" ]] || {
            err "Domain '${DOMAIN}' is already assigned to managed site '${domain_owner}'."
            return 1
        }
    fi

    init_logging "restore-fresh-${slug}"
    acquire_lock "site-${slug}"
    if [[ -z "${MOODLEKIT_OPERATION_ID:-}" ]]; then
        state_operation_start "restore-fresh" "${slug}" "$(jq -nc --arg backup_path "${backup_path}" '{backup_path:$backup_path}')"
    fi
    section "Provisioning fresh instance '${slug}'"
    
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
    local DB_PREFIX="mdl_"
    local IS_MOODLE5="${bk_is_moodle5}"
    local MOODLE_VERSION="${bk_moodle_version}"
    local PHP_VERSION="${bk_php_version:-${PHP_VERSION}}"

    local NGINX_CONF="/etc/nginx/sites-available/moodle-${slug}"
    local FPM_SOCK
    FPM_SOCK="$(detect_fpm_socket "${slug}" "${PHP_VERSION}")"
    local FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/${slug}.conf"
    local ADMIN_CLI="${MOODLE_DIR}/admin/cli"

    # ── Resume detection ───────────────────────────────────────────────────
    local SKIP_DB_PROVISION=0
    local SKIP_DB_IMPORT=0
    local SKIP_CLONE=0
    local SKIP_MOODLEDATA=0
    local DROP_EXISTING_DB=0

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
                DROP_EXISTING_DB=1
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

    validate_php_moodle_compat "${PHP_VERSION}" "${MOODLE_VERSION}"
    [[ -x "/usr/bin/php${PHP_VERSION}" ]] || { err "PHP CLI not found: /usr/bin/php${PHP_VERSION}"; return 1; }
    [[ -d "/etc/php/${PHP_VERSION}/fpm/pool.d" ]] || {
        err "PHP-FPM pool directory missing for PHP ${PHP_VERSION}."
        err "Run 'moodlekit doctor' or bootstrap PHP ${PHP_VERSION}, then retry."
        return 1
    }
    check_disk_space "/var/www" 3

    section "Fresh Restore Summary"
    info "Slug:       ${slug}"
    info "Domain:     ${DOMAIN}"
    info "Moodle:     ${MOODLE_VERSION}"
    info "Database:   ${bk_db_type} (${DB_NAME})"
    info "Code:       $([ "${SKIP_CLONE}" -eq 1 ] && echo 'keep existing' || echo 'restore/clone')"
    info "Moodledata: $([ "${SKIP_MOODLEDATA}" -eq 1 ] && echo 'keep existing' || echo 'restore')"
    if ! confirm "Proceed with this fresh restore plan?" "y"; then
        state_operation_finish "cancelled" "Cancelled at restore summary"
        release_lock
        clear_rollbacks
        info "Restore cancelled; no database or files were changed."
        return 0
    fi

    # ── Step 1: Provision database ─────────────────────────────────────────
    step 1 10 "Provision database"
    if [[ "${SKIP_DB_PROVISION}" -eq 1 ]]; then
        info "Skipped (using existing database)"
    else
        if [[ "${DROP_EXISTING_DB}" -eq 1 ]]; then
            info "Dropping existing database '${DB_NAME}' after confirmation..."
            _db_drop_by_type "${bk_db_type}" "${DB_NAME}" "${DB_USER}"
        fi
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

    # Auto-detect table prefix from the database (in case it was imported or exists)
    local detected_prefix=""
    case "${bk_db_type}" in
        postgres)
            detected_prefix=$(sudo -u postgres psql -At -c \
                "SELECT table_name
                   FROM information_schema.columns
                  WHERE table_schema='public' AND table_name LIKE '%config'
                  GROUP BY table_name
                 HAVING COUNT(*) = 3
                    AND COUNT(*) FILTER (WHERE column_name IN ('id','name','value')) = 3
                  ORDER BY LENGTH(table_name), table_name
                  LIMIT 1" "${DB_NAME}" 2>/dev/null | xargs || true)
            ;;
        mariadb|mysql)
            detected_prefix=$(mysql -u root -sN -e \
                "SELECT table_name
                   FROM information_schema.columns
                  WHERE table_schema='${DB_NAME}' AND table_name LIKE '%config'
                  GROUP BY table_name
                 HAVING COUNT(*) = 3
                    AND SUM(column_name IN ('id','name','value')) = 3
                  ORDER BY LENGTH(table_name), table_name
                  LIMIT 1;" 2>/dev/null || true)
            ;;
    esac
    if [[ -n "${detected_prefix}" ]]; then
        DB_PREFIX="${detected_prefix%config}"
        info "Detected database table prefix: ${DB_PREFIX}"
    else
        err "Could not identify Moodle's core config table after database import."
        err "Fresh restore stopped before config.php generation to avoid using an unsafe table prefix."
        return 1
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
            _extract_archive_to_target "${code_archive}" "${MOODLE_DIR}"
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

    # cmd_restore intentionally uses umask 077 for sensitive artifacts, which
    # also makes a newly cloned/extracted code root 0700. Normalize the code
    # before any Moodle CLI is executed as www-data.
    normalize_moodle_code_permissions "${MOODLE_DIR}"

    # ── Step 4: Restore moodledata ─────────────────────────────────────────
    step 4 10 "Restore moodledata"
    if [[ "${SKIP_MOODLEDATA}" -eq 1 ]]; then
        info "Skipped (using existing moodledata)"
    else
        mkdir -p "$(dirname "${MOODLEDATA_DIR}")"
        if [[ -f "${data_archive}" ]]; then
            spinner_start "Extracting moodledata archive..."
            _extract_archive_to_target "${data_archive}" "${MOODLEDATA_DIR}"
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
        "DB_PREFIX=${DB_PREFIX}" \
        "DOMAIN=${DOMAIN}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" \
        "PHP_VERSION=${PHP_VERSION}" \
        "CACHE_CONFIG=${cache_block}"

    chown root:www-data "${MOODLE_DIR}/config.php"
    chmod 640 "${MOODLE_DIR}/config.php"
    ok "config.php generated"

    # MUC Redis setup — create store instance programmatically
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        if ! _configure_muc_redis "${slug}" "${MOODLE_DIR}" "${IS_MOODLE5}"; then
            warn "Fresh restore is usable, but Redis MUC mapping needs manual review."
        fi
    fi

    # ── Step 6: Permissions ────────────────────────────────────────────────
    step 6 10 "Set permissions"
    normalize_moodle_code_permissions "${MOODLE_DIR}"
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
        "SLUG=${slug}" "PHP_VERSION=${PHP_VERSION}" "FPM_SOCK=${FPM_SOCK}" \
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
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" "PHP_VERSION=${PHP_VERSION}" \
        "FPM_SOCK=${FPM_SOCK}" "SLUG=${slug}"

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
        local certbot_contact_args=()
        if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
            certbot_contact_args=(--email "${LETSENCRYPT_EMAIL}")
        else
            certbot_contact_args=(--register-unsafely-without-email)
            warn "No Let's Encrypt email configured; registering without email notifications."
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

    ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/moodle-${slug}"
    reload_nginx

    # ── Step 9: Run upgrade ────────────────────────────────────────────────
    step 9 10 "Moodle upgrade"
    ADMIN_CLI="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    if [[ -f "${ADMIN_CLI}/upgrade.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${ADMIN_CLI}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
    else
        err "Required Moodle upgrade CLI not found: ${ADMIN_CLI}/upgrade.php"
        return 1
    fi

    # ── Step 10: Cron + State ───────────────────────────────────────────────
    step 10 10 "Cron + Save state"
    _configure_task_processing "${ADMIN_CLI}"
    _configure_cron "${slug}" "${MOODLE_DIR}" "${IS_MOODLE5}"

    # Save site state into Encrypted Binary Vault
    local site_json
    site_json="$(jq -n \
        --arg slug "${slug}" \
        --arg domain "${DOMAIN}" \
        --arg moodle_version "${MOODLE_VERSION}" \
        --argjson is_moodle5 "${IS_MOODLE5}" \
        --arg moodle_dir "${MOODLE_DIR}" \
        --arg moodledata_dir "${MOODLEDATA_DIR}" \
        --arg db_type "${bk_db_type}" \
        --arg db_name "${DB_NAME}" \
        --arg db_user "${DB_USER}" \
        --arg db_pass "${DB_PASS}" \
        --arg db_port "${DB_PORT}" \
        --arg php_version "${PHP_VERSION}" \
        --arg fpm_pool_conf "${FPM_POOL_CONF}" \
        --arg fpm_sock "${FPM_SOCK}" \
        --arg nginx_conf "${NGINX_CONF}" \
        --argjson use_redis_sessions "${USE_REDIS:-0}" \
        --arg restored_from "${backup_path}" \
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
            db_port: $db_port,
            php_version: $php_version,
            fpm_pool_conf: $fpm_pool_conf,
            fpm_sock: $fpm_sock,
            nginx_conf: $nginx_conf,
            use_redis_sessions: $use_redis_sessions,
            restored_from: $restored_from,
            created_at: $created_at
        }'
    )"
    vault_sset "${slug}" "${site_json}"
    state_site_upsert "${site_json}"

    # Legacy config compatibility
    mkdir -p "${MOODLEKIT_SITES_DIR}"
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
    release_lock
    clear_rollbacks
    state_operation_finish "completed" "Fresh restore completed"


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

_replace_database_from_dump() {
    local dump_file="$1"
    [[ -s "${dump_file}" ]] || { err "Database dump is missing or empty: ${dump_file}"; return 1; }
    gzip -t "${dump_file}"
    case "${DB_TYPE}" in
        postgres)
            sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();"
            sudo -u postgres dropdb --if-exists "${DB_NAME}"
            sudo -u postgres createdb --owner="${DB_USER}" --encoding=UTF8 --template=template0 "${DB_NAME}"
            db_pg_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
        mariadb)
            mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4; GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
            db_maria_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
        mysql)
            mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4; GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
            db_mysql_restore "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}"
            ;;
        *) err "Unsupported database type '${DB_TYPE}'."; return 1 ;;
    esac
}

_extract_archive_to_target() {
    local archive="$1" target="$2"
    local parent target_name staging source_dir
    parent="$(dirname "${target}")"
    target_name="$(basename "${target}")"
    mkdir -p "${parent}"
    staging="$(mktemp -d "${parent}/.moodlekit-restore.XXXXXX")"
    if ! tar --extract --gzip --file="${archive}" --directory="${staging}"; then
        rm -rf "${staging}"
        return 1
    fi
    source_dir="${staging}/${target_name}"
    if [[ ! -d "${source_dir}" ]]; then
        local -a roots=()
        mapfile -t roots < <(find "${staging}" -mindepth 1 -maxdepth 1 -type d -print)
        if [[ ${#roots[@]} -ne 1 ]]; then
            err "Archive must contain exactly one top-level data directory."
            rm -rf "${staging}"
            return 1
        fi
        source_dir="${roots[0]}"
    fi
    rm -rf "${target}"
    mv "${source_dir}" "${target}"
    rm -rf "${staging}"
}

_rollback_inplace_restore() {
    [[ -n "${RESTORE_SAFETY_PATH:-}" && -d "${RESTORE_SAFETY_PATH}" ]] || return 0
    warn "Restoring the pre-restore safety snapshot..."
    if [[ -s "${RESTORE_SAFETY_PATH}/database.sql.gz" ]]; then
        _replace_database_from_dump "${RESTORE_SAFETY_PATH}/database.sql.gz"
    fi
    if [[ -s "${RESTORE_SAFETY_PATH}/moodledata.tar.gz" ]]; then
        _extract_archive_to_target "${RESTORE_SAFETY_PATH}/moodledata.tar.gz" "${MOODLEDATA_DIR}"
        chown -R www-data:www-data "${MOODLEDATA_DIR}"
    fi
    local cfg
    cfg="$(find_moodle_config_file "${MOODLE_DIR}")"
    [[ -z "${cfg}" || ! -f "${RESTORE_SAFETY_PATH}/config.php" ]] || cp -a "${RESTORE_SAFETY_PATH}/config.php" "${cfg}"
    disable_moodle_maintenance "${RESTORE_SAFETY_ADMIN_CLI:-}" "${PHP_VERSION}"
    warn "Original site restored from ${RESTORE_SAFETY_PATH}"
}
