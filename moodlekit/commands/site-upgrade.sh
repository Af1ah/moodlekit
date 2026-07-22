#!/usr/bin/env bash
# =============================================================================
# commands/site-upgrade.sh — Upgrade a Moodle site to a newer version
# =============================================================================

cmd_site_upgrade() {
    require_root
    load_global_conf

    local SLUG="${1:-}"
    if [[ -z "${SLUG}" ]]; then
        if ! _pick_site_slug SLUG "Select site to upgrade:"; then
            return 1
        fi
    fi

    site_exists "${SLUG}" || { err "Site '${SLUG}' not found"; exit 1; }
    load_site_conf "${SLUG}"
    
    init_logging "site-upgrade-${SLUG}"
    acquire_lock "site-${SLUG}"
    
    section "MoodleKit — Upgrade Site: ${SLUG}"
    info "Current version: ${MOODLE_VERSION}"
    
    # Target version selection
    local target_version=""
    select_one target_version "Select target version for upgrade:" \
        "4.5 (from 4.1+)" \
        "5.2 (from 4.5+)"
    
    local TARGET_VER
    local TARGET_BRANCH
    local IS_TARGET_MOODLE5=0
    
    if [[ "${target_version}" == *"4.5"* ]]; then
        TARGET_VER="4.5"
        TARGET_BRANCH="MOODLE_405_STABLE"
    elif [[ "${target_version}" == *"5.2"* ]]; then
        TARGET_VER="5.2"
        TARGET_BRANCH="MOODLE_502_STABLE"
        IS_TARGET_MOODLE5=1
    else
        err "Invalid selection"
        exit 1
    fi
    
    if [[ "${TARGET_VER}" == "${MOODLE_VERSION}" ]]; then
        err "Target version ${TARGET_VER} is the same as the current version."
        exit 1
    fi

    warn "Upgrading from ${MOODLE_VERSION} to ${TARGET_VER}."
    warn "Direct major upgrades (e.g. 4.1 to 5.2) may conflict. Use staging if needed."
    confirm "Are you sure you want to proceed?" "y" || exit 0
    
    local BACKUP_CODE=1
    if ! confirm "Backup (mv) current codebase to ${MOODLE_DIR}.bak?" "y"; then
        BACKUP_CODE=0
    fi
    
    local admin_cli="${MOODLE_DIR}/admin/cli"
    
    step 1 7 "Enable maintenance mode"
    if [[ -f "${admin_cli}/maintenance.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/maintenance.php" --enable 2>/dev/null || true
    fi
    ok "Maintenance mode enabled"
    
    step 2 7 "Database backup"
    local TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    local BACKUP_PATH="${MOODLEKIT_BACKUP_DIR}/${SLUG}/upgrade_${TIMESTAMP}"
    mkdir -p "${BACKUP_PATH}"
    local dump_file="${BACKUP_PATH}/database.sql.gz"
    
    case "${DB_TYPE}" in
        postgres) db_pg_dump    "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mariadb)  db_maria_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mysql)    db_mysql_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
    esac
    ok "Database dumped to ${dump_file}"
    
    step 3 7 "Backup old code & prepare new directory"
    # Save config.php to temp location to ensure we don't lose it
    local tmp_config="$(mktemp)"
    cp "${MOODLE_DIR}/config.php" "${tmp_config}"

    if [[ "${BACKUP_CODE}" -eq 1 ]]; then
        rm -rf "${MOODLE_DIR}.bak"
        mv "${MOODLE_DIR}" "${MOODLE_DIR}.bak"
        ok "Moved ${MOODLE_DIR} to ${MOODLE_DIR}.bak"
    else
        rm -rf "${MOODLE_DIR}"
        ok "Deleted old code"
    fi
    mkdir -p "${MOODLE_DIR}"
    
    step 4 7 "Download Moodle ${TARGET_VER}"
    spinner_start "Cloning Moodle ${TARGET_VER}..."
    git clone --depth 1 --branch "${TARGET_BRANCH}" https://github.com/moodle/moodle.git "${MOODLE_DIR}"
    
    local composer_json="${MOODLE_DIR}/composer.json"
    if [[ -f "${composer_json}" ]]; then
        COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev --optimize-autoloader --no-interaction \
            --working-dir="${MOODLE_DIR}" 2>&1 | tee -a "${_LOG_FILE}"
    fi
    
    cp "${tmp_config}" "${MOODLE_DIR}/config.php"
    rm -f "${tmp_config}"
    
    chown -R root:www-data "${MOODLE_DIR}"
    find "${MOODLE_DIR}" -type d -exec chmod 755 {} \;
    find "${MOODLE_DIR}" -type f -exec chmod 644 {} \;
    chown root:www-data "${MOODLE_DIR}/config.php"
    chmod 640 "${MOODLE_DIR}/config.php"
    spinner_stop 0 "Code downloaded and permissions set"
    
    step 5 7 "Update Nginx configuration"
    local nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
    [[ "${IS_TARGET_MOODLE5}" -eq 1 ]] && nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"
    
    render_template_to_file "${nginx_tpl}" "${NGINX_CONF}" \
        "DOMAIN=${DOMAIN}" "MOODLE_DIR=${MOODLE_DIR}" \
        "MOODLEDATA_DIR=${MOODLEDATA_DIR}" "PHP_VERSION=${PHP_VERSION}" "SLUG=${SLUG}"
    reload_nginx
    ok "Nginx configuration updated for Moodle ${TARGET_VER}"
    
    step 6 7 "Run upgrade & purge caches"
    local new_admin_cli="${MOODLE_DIR}/admin/cli"
    
    # We must first purge caches for the new code to be recognized
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
    
    # Check if plugins are missing, Moodle upgrade might fail if 3rd party plugins were installed
    info "Running Moodle upgrade..."
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${new_admin_cli}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
    
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
    ok "Upgrade completed"
    
    step 7 7 "Disable maintenance & update state"
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${new_admin_cli}/maintenance.php" --disable 2>/dev/null || true
    
    # Run cron once
    sudo -u www-data "/usr/bin/php${PHP_VERSION}" "${new_admin_cli}/cron.php" 2>&1 | tee -a "${_LOG_FILE}" > /dev/null
    
    # Update config
    sed -i "s/^MOODLE_VERSION=.*/MOODLE_VERSION=\"${TARGET_VER}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf"
    sed -i "s/^IS_MOODLE5=.*/IS_MOODLE5=\"${IS_TARGET_MOODLE5}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf"
    
    clear_rollbacks
    
    print_box "Upgrade Complete: ${SLUG} ✓" \
        "URL:            https://${DOMAIN}" \
        "Old Version:    ${MOODLE_VERSION}" \
        "New Version:    ${TARGET_VER}" \
        "Backup path:    ${BACKUP_PATH}" \
        "Code backup:    $([ "${BACKUP_CODE}" -eq 1 ] && echo "${MOODLE_DIR}.bak" || echo "Skipped")" \
        "Log:            ${_LOG_FILE}"
}
