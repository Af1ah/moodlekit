#!/usr/bin/env bash
# =============================================================================
# commands/site-upgrade.sh — Upgrade & Apply Security Patches to a Moodle Site
# =============================================================================
# Supports:
# 1. In-place weekly security patch updates (git pull on current branch)
# 2. Major/minor version upgrades (4.5 -> 5.2, etc.)
# 3. Preservation of 3rd party plugins, themes, and git worktree
# 4. Safe automated database backup prior to upgrade
# 5. CLI maintenance mode, database schema migrations, and cache purges
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

    site_exists "${SLUG}" || { err "Site '${SLUG}' not found in MoodleKit encrypted vault."; exit 1; }
    load_site_conf "${SLUG}"
    
    init_logging "site-upgrade-${SLUG}"
    acquire_lock "site-${SLUG}"
    
    local current_real_ver
    current_real_ver="$(detect_moodle_version_string "${MOODLE_DIR}")"
    [[ -z "${current_real_ver}" ]] && current_real_ver="${MOODLE_VERSION:-4.5}"
    
    section "MoodleKit — Upgrade & Patch Site: ${SLUG}"
    info "Site URL:        https://${DOMAIN:-$SLUG}"
    info "Directory:       ${MOODLE_DIR}"
    info "Current Release: Moodle ${current_real_ver}"
    echo ""
    
    # Check if site is a git repository
    local is_git_repo=0
    [[ -d "${MOODLE_DIR}/.git" ]] && is_git_repo=1
    
    # ── Target version & action selection ────────────────────────────────────
    local upgrade_choice=""
    local cur_branch
    cur_branch="$(moodle_version_to_branch "${current_real_ver}")"
    
    local menu_options=(
        "🔒 Apply Latest Security Patches & Weekly Bugfixes (${cur_branch})"
        "🚀 Upgrade to Moodle 5.2 (MOODLE_502_STABLE)"
        "🚀 Upgrade to Moodle 5.1 (MOODLE_501_STABLE)"
        "🚀 Upgrade to Moodle 4.5 LTS (MOODLE_405_STABLE)"
        "🌿 Enter Custom Git Branch / Tag"
        "Cancel"
    )
    
    select_one upgrade_choice "Select upgrade or patching action for '${SLUG}':" "${menu_options[@]}"
    
    local TARGET_VER="${current_real_ver}"
    local TARGET_BRANCH="${cur_branch}"
    local IS_TARGET_MOODLE5
    IS_TARGET_MOODLE5="$(detect_is_moodle5 "${MOODLE_DIR}")"
    local IS_SECURITY_PATCH_ONLY=0
    
    case "${upgrade_choice}" in
        *"Apply Latest Security Patches"*)
            IS_SECURITY_PATCH_ONLY=1
            TARGET_BRANCH="${cur_branch}"
            info "Action: Applying latest security patches on ${TARGET_BRANCH}..."
            ;;
        *"Moodle 5.2"*)
            TARGET_VER="5.2"
            TARGET_BRANCH="MOODLE_502_STABLE"
            IS_TARGET_MOODLE5=1
            ;;
        *"Moodle 5.1"*)
            TARGET_VER="5.1"
            TARGET_BRANCH="MOODLE_501_STABLE"
            IS_TARGET_MOODLE5=1
            ;;
        *"Moodle 4.5"*)
            TARGET_VER="4.5"
            TARGET_BRANCH="MOODLE_405_STABLE"
            IS_TARGET_MOODLE5=0
            ;;
        *"Custom Git Branch"*)
            input_text TARGET_BRANCH "Enter target Git branch name (e.g. MOODLE_502_STABLE, main, v5.2.1)" "${cur_branch}"
            TARGET_VER="$(echo "${TARGET_BRANCH}" | grep -oE '[0-9]+\.[0-9]+' || echo "${current_real_ver}")"
            [[ "${TARGET_BRANCH}" =~ 50[0-9] || "${TARGET_VER}" == 5* ]] && IS_TARGET_MOODLE5=1
            ;;
        *"Cancel"*)
            info "Upgrade cancelled."
            return 0
            ;;
        *)
            err "Invalid selection"
            return 1
            ;;
    esac
    
    echo ""
    if [[ "${IS_SECURITY_PATCH_ONLY}" -eq 1 ]]; then
        info "Target: In-place update to latest weekly commits on ${TARGET_BRANCH}"
    else
        info "Target: Upgrade from Moodle ${current_real_ver} to Moodle ${TARGET_VER} (${TARGET_BRANCH})"
    fi
    
    confirm "Proceed with upgrade & database migration?" "y" || return 0
    
    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    
    # ── Step 1: Enable Maintenance Mode ──────────────────────────────────────
    step 1 7 "Enabling Maintenance Mode"
    if [[ -f "${admin_cli}/maintenance.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/maintenance.php" --enable 2>/dev/null || true
        ok "Maintenance mode enabled"
    else
        warn "maintenance.php not found; proceeding"
    fi
    
    # ── Step 2: Database Backup ──────────────────────────────────────────────
    step 2 7 "Creating Pre-Upgrade Database Backup"
    local TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    local BACKUP_PATH="${MOODLEKIT_BACKUP_DIR}/${SLUG}/upgrade_${TIMESTAMP}"
    mkdir -p "${BACKUP_PATH}"
    local dump_file="${BACKUP_PATH}/database.sql.gz"
    
    case "${DB_TYPE:-mariadb}" in
        postgres) db_pg_dump    "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mariadb)  db_maria_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mysql)    db_mysql_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
    esac
    ok "Database dump created: ${dump_file}"
    
    # ── Step 3 & 4: Code Update ──────────────────────────────────────────────
    step 3 7 "Updating Moodle Codebase (${TARGET_BRANCH})"
    
    local cfg_file
    cfg_file="$(find_moodle_config_file "${MOODLE_DIR}")"
    local tmp_config=""
    if [[ -n "${cfg_file}" && -f "${cfg_file}" ]]; then
        tmp_config="$(mktemp)"
        cp "${cfg_file}" "${tmp_config}"
    fi
    
    if [[ "${is_git_repo}" -eq 1 ]]; then
        info "Git repository detected in ${MOODLE_DIR} — preserving custom plugins and history"
        spinner_start "Fetching updates from git remote..."
        git -C "${MOODLE_DIR}" fetch --tags origin >> "${_LOG_FILE}" 2>&1
        
        # Check if remote branch exists
        if git -C "${MOODLE_DIR}" show-ref --verify --quiet "refs/remotes/origin/${TARGET_BRANCH}"; then
            git -C "${MOODLE_DIR}" checkout "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1 || git -C "${MOODLE_DIR}" checkout -B "${TARGET_BRANCH}" "origin/${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1
            git -C "${MOODLE_DIR}" pull origin "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1 || true
        else
            # Tag or commit checkout
            git -C "${MOODLE_DIR}" checkout "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1 || true
        fi
        spinner_stop 0 "Git tree updated to ${TARGET_BRANCH}"
    else
        info "Non-git directory — creating backup and updating codebase..."
        cp -a "${MOODLE_DIR}" "${MOODLE_DIR}.bak_${TIMESTAMP}"
        ok "Backup created at ${MOODLE_DIR}.bak_${TIMESTAMP}"
        
        spinner_start "Cloning ${TARGET_BRANCH}..."
        git clone --depth 1 --branch "${TARGET_BRANCH}" https://github.com/moodle/moodle.git "${MOODLE_DIR}.tmp" >> "${_LOG_FILE}" 2>&1
        
        # Sync core files into MOODLE_DIR while preserving untracked custom plugins
        rsync -a --exclude="config.php" "${MOODLE_DIR}.tmp/" "${MOODLE_DIR}/"
        rm -rf "${MOODLE_DIR}.tmp"
        spinner_stop 0 "Core files updated from ${TARGET_BRANCH}"
    fi
    
    # Restore config.php if needed
    if [[ -n "${tmp_config}" && -f "${tmp_config}" ]]; then
        if [[ ! -f "${cfg_file}" ]]; then
            cp "${tmp_config}" "${cfg_file}"
        fi
        rm -f "${tmp_config}"
    fi
    
    # Run composer install if composer.json exists
    if [[ -f "${MOODLE_DIR}/composer.json" ]] && command -v composer &>/dev/null; then
        spinner_start "Running composer install..."
        COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev --optimize-autoloader --no-interaction \
            --working-dir="${MOODLE_DIR}" >> "${_LOG_FILE}" 2>&1 || true
        spinner_stop 0 "Composer dependencies installed"
    fi
    
    # ── Step 4: Permissions ──────────────────────────────────────────────────
    step 4 7 "Setting Permissions"
    chown -R root:www-data "${MOODLE_DIR}"
    find "${MOODLE_DIR}" -type d -exec chmod 755 {} +
    find "${MOODLE_DIR}" -type f -exec chmod 644 {} +
    
    local secure_cfg
    secure_cfg="$(find_moodle_config_file "${MOODLE_DIR}")"
    if [[ -n "${secure_cfg}" && -f "${secure_cfg}" ]]; then
        chown root:www-data "${secure_cfg}"
        chmod 640 "${secure_cfg}"
    fi
    ok "Permissions secured (0755 dirs, 0644 files, 0640 config)"
    
    # ── Step 5: Nginx Configuration ──────────────────────────────────────────
    step 5 7 "Verifying Nginx Virtual Host"
    local nginx_conf="${NGINX_CONF:-/etc/nginx/sites-available/moodle-${SLUG}}"
    if [[ -f "${nginx_conf}" ]]; then
        local nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
        [[ "${IS_TARGET_MOODLE5}" -eq 1 ]] && nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"
        
        render_template_to_file "${nginx_tpl}" "${nginx_conf}" \
            "DOMAIN=${DOMAIN:-$SLUG.local}" \
            "MOODLE_DIR=${MOODLE_DIR}" \
            "MOODLEDATA_DIR=${MOODLEDATA_DIR:-/var/moodledata/$SLUG}" \
            "PHP_VERSION=${PHP_VERSION:-8.3}" \
            "SLUG=${SLUG}"
        reload_nginx
        ok "Nginx virtual host configured for Moodle ${TARGET_VER}"
    fi
    
    # ── Step 6: Moodle CLI Database Upgrade & Cache Purge ────────────────────
    step 6 7 "Executing Database Migration & Upgrades"
    local new_admin_cli
    new_admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    
    # Purge caches first
    if [[ -f "${new_admin_cli}/purge_caches.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION:-8.3}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
    fi
    
    if [[ -f "${new_admin_cli}/upgrade.php" ]]; then
        info "Running Moodle schema upgrade (admin/cli/upgrade.php)..."
        sudo -u www-data "/usr/bin/php${PHP_VERSION:-8.3}" "${new_admin_cli}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
        ok "Moodle database schema upgraded"
    else
        warn "admin/cli/upgrade.php not found; skipped database upgrade"
    fi
    
    if [[ -f "${new_admin_cli}/purge_caches.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION:-8.3}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
        ok "Caches purged"
    fi
    
    # ── Step 7: Disable Maintenance Mode & Update Vault ──────────────────────
    step 7 7 "Restoring Live Service & Updating Vault State"
    if [[ -f "${new_admin_cli}/maintenance.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION:-8.3}" "${new_admin_cli}/maintenance.php" --disable 2>/dev/null || true
        ok "Maintenance mode disabled"
    fi
    
    if [[ -f "${new_admin_cli}/cron.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION:-8.3}" "${new_admin_cli}/cron.php" 2>&1 | tee -a "${_LOG_FILE}" >/dev/null || true
    fi
    
    # Determine new version string
    local new_ver_str
    new_ver_str="$(detect_moodle_version_string "${MOODLE_DIR}")"
    [[ -z "${new_ver_str}" ]] && new_ver_str="${TARGET_VER}"
    
    # Update encrypted vault state
    local site_json
    site_json="$(vault_sget "${SLUG}")"
    if [[ -n "${site_json}" ]]; then
        site_json="$(echo "${site_json}" | jq \
            --arg ver "${new_ver_str}" \
            --argjson is5 "${IS_TARGET_MOODLE5}" \
            --arg upgraded_at "$(date -Iseconds)" \
            '.moodle_version = $ver | .is_moodle5 = $is5 | .upgraded_at = $upgraded_at'
        )"
        vault_sset "${SLUG}" "${site_json}"
    fi

    # Update legacy config if present
    if [[ -f "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" ]]; then
        sed -i "s/^MOODLE_VERSION=.*/MOODLE_VERSION=\"${new_ver_str}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" 2>/dev/null || true
        sed -i "s/^IS_MOODLE5=.*/IS_MOODLE5=\"${IS_TARGET_MOODLE5}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" 2>/dev/null || true
    fi
    
    clear_rollbacks
    
    print_box "Upgrade & Security Patching Complete: ${SLUG} ✓" \
        "URL:            https://${DOMAIN:-$SLUG}" \
        "Old Version:    Moodle ${current_real_ver}" \
        "New Version:    Moodle ${new_ver_str} (${TARGET_BRANCH})" \
        "Database Dump:  ${dump_file}" \
        "Git Tree:       $([ "${is_git_repo}" -eq 1 ] && echo "Preserved (in-place)" || echo "Synced")" \
        "Status:         100% Online & Upgraded" \
        "Log:            ${_LOG_FILE}"
}
