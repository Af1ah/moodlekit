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
    # Pre-upgrade snapshots contain a full database and config.php.
    umask 077
    load_global_conf

    local SLUG="${1:-}"
    if [[ -z "${SLUG}" ]]; then
        if ! _pick_site_slug SLUG "Select site to upgrade:"; then
            return 1
        fi
    fi

    site_exists "${SLUG}" || { err "Site '${SLUG}' not found in MoodleKit encrypted vault."; exit 1; }
    load_site_conf "${SLUG}" 0
    validate_site_runtime "${SLUG}"

    init_logging "site-upgrade-${SLUG}"
    
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

    validate_php_moodle_compat "${PHP_VERSION}" "${TARGET_VER}"
    check_disk_space "${MOODLE_DIR}" 3

    local admin_cli
    admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    [[ -f "${admin_cli}/maintenance.php" ]] || { err "Maintenance CLI not found: ${admin_cli}/maintenance.php"; return 1; }
    [[ -f "${admin_cli}/upgrade.php" ]] || { err "Upgrade CLI not found: ${admin_cli}/upgrade.php"; return 1; }

    if [[ "${is_git_repo}" -eq 1 ]] && [[ -n "$(git -C "${MOODLE_DIR}" status --porcelain 2>/dev/null)" ]]; then
        err "The Moodle Git working tree has uncommitted or untracked changes."
        err "Upgrade stopped before maintenance mode. Commit, archive, or remove those changes, then retry."
        return 1
    fi

    if [[ "${IS_SECURITY_PATCH_ONLY}" -ne 1 ]]; then
        local lowest_version
        lowest_version="$(printf '%s\n%s\n' "${current_real_ver}" "${TARGET_VER}" | sort -V | head -1)"
        if [[ "${lowest_version}" == "${TARGET_VER}" && "${TARGET_VER}" != "${current_real_ver}" ]]; then
            err "Refusing downgrade from Moodle ${current_real_ver} to ${TARGET_VER}."
            err "Use a tested backup restore workflow for downgrades; Moodle schema downgrades are unsupported."
            return 1
        fi
    fi
    
    if ! confirm "Proceed with upgrade & database migration?" "y"; then
        info "Upgrade cancelled; no changes were made."
        return 0
    fi
    acquire_lock "site-${SLUG}"
    state_operation_start "site-upgrade" "${SLUG}" "$(jq -nc --arg from "${current_real_ver}" --arg to "${TARGET_VER}" --arg branch "${TARGET_BRANCH}" '{from:$from,to:$to,branch:$branch}')"

    # ── Step 1: Enable Maintenance Mode ──────────────────────────────────────
    step 1 8 "Enabling and verifying maintenance mode"
    enable_moodle_maintenance "${admin_cli}" "${PHP_VERSION}"
    
    # ── Step 2: Database Backup ──────────────────────────────────────────────
    step 2 8 "Creating verified pre-upgrade safety snapshot"
    local TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    local BACKUP_PATH="${MOODLEKIT_BACKUP_DIR}/${SLUG}/upgrade_${TIMESTAMP}"
    mkdir -p "${BACKUP_PATH}"
    local dump_file="${BACKUP_PATH}/database.sql.gz"
    
    dump_site_database "${dump_file}"
    local original_config
    original_config="$(find_moodle_config_file "${MOODLE_DIR}")"
    [[ -z "${original_config}" ]] || cp -a "${original_config}" "${BACKUP_PATH}/config.php"
    if [[ -n "${NGINX_CONF:-}" && -f "${NGINX_CONF}" ]]; then
        cp -a "${NGINX_CONF}" "${BACKUP_PATH}/nginx.conf"
    fi
    if [[ "${is_git_repo}" -eq 1 ]]; then
        git -C "${MOODLE_DIR}" rev-parse HEAD > "${BACKUP_PATH}/git-head.txt"
        git -C "${MOODLE_DIR}" status --porcelain=v1 > "${BACKUP_PATH}/git-status.txt"
    fi
    chmod 600 "${BACKUP_PATH}"/* 2>/dev/null || true
    UPGRADE_SAFETY_PATH="${BACKUP_PATH}"
    UPGRADE_SAFETY_ADMIN_CLI="${admin_cli}"
    UPGRADE_SAFETY_IS_GIT="${is_git_repo}"
    UPGRADE_CODE_BACKUP="${MOODLE_DIR}.bak_${TIMESTAMP}"
    register_rollback "_rollback_site_upgrade"
    ok "Safety snapshot verified: ${BACKUP_PATH}"
    
    # ── Step 3 & 4: Code Update ──────────────────────────────────────────────
    step 3 8 "Updating Moodle Codebase (${TARGET_BRANCH})"
    
    local cfg_file
    cfg_file="$(find_moodle_config_file "${MOODLE_DIR}")"
    local tmp_config=""
    if [[ -n "${cfg_file}" && -f "${cfg_file}" ]]; then
        tmp_config="$(mktemp)"
        cp "${cfg_file}" "${tmp_config}"
    fi
    
    if [[ "${is_git_repo}" -eq 1 ]]; then
        info "Git repository detected in ${MOODLE_DIR} — preserving custom plugins and history"
        spinner_start "Fetching selected Git target from origin..."
        # Fetch only the requested branch or tag. `--tags` on Moodle's shallow
        # repository expands into years of history and millions of objects.
        if ! git -C "${MOODLE_DIR}" fetch --prune origin "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1; then
            spinner_stop 1 "Git fetch failed"
            err "Could not fetch '${TARGET_BRANCH}' from origin. The working tree was not changed."
            return 1
        fi
        
        # Check if remote branch exists
        if git -C "${MOODLE_DIR}" show-ref --verify --quiet "refs/remotes/origin/${TARGET_BRANCH}"; then
            if git -C "${MOODLE_DIR}" show-ref --verify --quiet "refs/heads/${TARGET_BRANCH}"; then
                git -C "${MOODLE_DIR}" checkout "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1
            else
                git -C "${MOODLE_DIR}" checkout --track -b "${TARGET_BRANCH}" "origin/${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1
            fi
            if ! git -C "${MOODLE_DIR}" merge --ff-only "origin/${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1; then
                spinner_stop 1 "Git update is not a safe fast-forward"
                err "Local branch diverges from origin/${TARGET_BRANCH}; refusing to overwrite local commits."
                return 1
            fi
        else
            if ! git -C "${MOODLE_DIR}" rev-parse --verify --quiet "${TARGET_BRANCH}^{commit}" >/dev/null; then
                spinner_stop 1 "Target branch or tag not found"
                err "Git target '${TARGET_BRANCH}' was not found locally or on origin."
                return 1
            fi
            git -C "${MOODLE_DIR}" checkout "${TARGET_BRANCH}" >> "${_LOG_FILE}" 2>&1
        fi
        spinner_stop 0 "Git tree updated to ${TARGET_BRANCH}"
    else
        info "Non-git directory — creating backup and updating codebase..."
        cp -a "${MOODLE_DIR}" "${MOODLE_DIR}.bak_${TIMESTAMP}"
        ok "Backup created at ${MOODLE_DIR}.bak_${TIMESTAMP}"
        
        if [[ -e "${MOODLE_DIR}.tmp" ]]; then
            err "Temporary upgrade directory already exists: ${MOODLE_DIR}.tmp"
            err "Inspect and remove it before retrying; MoodleKit will not overwrite it."
            return 1
        fi
        spinner_start "Cloning ${TARGET_BRANCH}..."
        if ! git clone --depth 1 --branch "${TARGET_BRANCH}" https://github.com/moodle/moodle.git "${MOODLE_DIR}.tmp" >> "${_LOG_FILE}" 2>&1; then
            spinner_stop 1 "Moodle clone failed"
            return 1
        fi
        
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
    
    # Remove development node_modules directories from production deployment
    rm -rf "${MOODLE_DIR}/node_modules" "${MOODLE_DIR}/public/node_modules"
    find "${MOODLE_DIR}" -maxdepth 4 -type d -name "node_modules" -exec rm -rf {} + 2>/dev/null || true

    # Run composer install if composer.json exists (strictly --no-dev)
    if [[ -f "${MOODLE_DIR}/composer.json" ]]; then
        command -v composer &>/dev/null || {
            err "composer.json exists but Composer is not installed."
            err "Install Composer and retry; dependencies were not silently skipped."
            return 1
        }
        spinner_start "Running composer install (--no-dev)..."
        if ! COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev --optimize-autoloader --no-interaction \
            --working-dir="${MOODLE_DIR}" >> "${_LOG_FILE}" 2>&1; then
            spinner_stop 1 "Composer dependency installation failed"
            return 1
        fi
        spinner_stop 0 "Composer production dependencies installed"
    fi
    
    # ── Step 4: Permissions ──────────────────────────────────────────────────
    step 4 8 "Setting Permissions"
    normalize_moodle_code_permissions "${MOODLE_DIR}"
    
    local secure_cfg
    secure_cfg="$(find_moodle_config_file "${MOODLE_DIR}")"
    if [[ -n "${secure_cfg}" && -f "${secure_cfg}" ]]; then
        chown root:www-data "${secure_cfg}"
        chmod 640 "${secure_cfg}"
    fi
    ok "Permissions secured (tracked executable modes preserved, config 0640)"
    
    # ── Step 5: Nginx Configuration ──────────────────────────────────────────
    step 5 8 "Verifying Nginx Virtual Host"
    local active_php="${PHP_VERSION:-}"
    [[ -z "${active_php}" ]] && active_php="$(get_installed_php_version)"
    local fpm_sock
    fpm_sock="$(detect_fpm_socket "${SLUG}" "${active_php}")"
    
    local nginx_conf="${NGINX_CONF:-/etc/nginx/sites-available/moodle-${SLUG}}"
    if [[ -f "${nginx_conf}" && "${IS_SECURITY_PATCH_ONLY}" -eq 1 ]]; then
        info "Security patch does not change the web layout; preserving the existing TLS-aware vhost."
        reload_nginx
        ok "Existing Nginx virtual host preserved (Socket: ${fpm_sock})"
    elif [[ -f "${nginx_conf}" ]]; then
        local nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle4.conf.tpl"
        [[ "${IS_TARGET_MOODLE5}" -eq 1 ]] && nginx_tpl="${MOODLEKIT_TPL}/nginx-moodle5.conf.tpl"
        
        render_template_to_file "${nginx_tpl}" "${nginx_conf}" \
            "DOMAIN=${DOMAIN:-$SLUG.local}" \
            "MOODLE_DIR=${MOODLE_DIR}" \
            "MOODLEDATA_DIR=${MOODLEDATA_DIR:-/var/moodledata/$SLUG}" \
            "PHP_VERSION=${active_php}" \
            "FPM_SOCK=${fpm_sock}" \
            "SLUG=${SLUG}"
        if [[ "${DOMAIN:-}" == *.local || "${DOMAIN:-}" == *.test || "${DOMAIN:-}" != *.* ]]; then
            generate_self_signed_fallback "${DOMAIN}" "${nginx_conf}"
        elif [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
            reload_nginx
        else
            err "TLS certificate files are missing for ${DOMAIN}; refusing to activate the regenerated vhost."
            return 1
        fi
        ok "Nginx virtual host configured for Moodle ${TARGET_VER} (Socket: ${fpm_sock})"
    else
        err "Managed Nginx configuration is missing: ${nginx_conf}"
        return 1
    fi
    
    # ── Step 6: Moodle CLI Database Upgrade & Cache Purge ────────────────────
    step 6 8 "Executing Database Migration & Upgrades"
    local new_admin_cli
    new_admin_cli="$(find_moodle_admin_cli "${MOODLE_DIR}")"
    
    # Purge caches first
    if [[ -f "${new_admin_cli}/purge_caches.php" ]]; then
        sudo -u www-data "/usr/bin/php${active_php}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
    fi
    
    [[ -f "${new_admin_cli}/upgrade.php" ]] || { err "Upgrade CLI missing after code update: ${new_admin_cli}/upgrade.php"; return 1; }
    info "Running Moodle schema upgrade (admin/cli/upgrade.php)..."
    MOODLEKIT_KEEP_MAINTENANCE_ON_FAILURE=1
    sudo -u www-data "/usr/bin/php${active_php}" "${new_admin_cli}/upgrade.php" --non-interactive 2>&1 | tee -a "${_LOG_FILE}"
    MOODLEKIT_KEEP_MAINTENANCE_ON_FAILURE=0
    ok "Moodle database schema upgraded"
    
    if [[ -f "${new_admin_cli}/purge_caches.php" ]]; then
        sudo -u www-data "/usr/bin/php${active_php}" "${new_admin_cli}/purge_caches.php" 2>/dev/null || true
        ok "Caches purged"
    fi
    
    # ── Step 7: Cron and task verification ──────────────────────────────────
    step 7 8 "Configure and verify cron for the upgraded layout"
    _configure_task_processing "${new_admin_cli}"
    _configure_cron "${SLUG}" "${MOODLE_DIR}" "${IS_TARGET_MOODLE5}"

    # ── Step 8: Disable Maintenance Mode & Update Vault ──────────────────────
    step 8 8 "Restoring live service and updating indexed state"
    disable_moodle_maintenance "${new_admin_cli}" "${active_php}"
    ok "Maintenance mode disabled"

    if [[ -f "${new_admin_cli}/cron.php" ]]; then
        # Cron refuses to run in CLI maintenance mode, so probe it only after
        # the site is live. Keep-alive is disabled and runtime is bounded.
        if timeout --signal=TERM 60s sudo -u www-data "/usr/bin/php${active_php}" \
            "${new_admin_cli}/cron.php" --keep-alive=0 >> "${_LOG_FILE}" 2>&1; then
            ok "Moodle cron probe completed"
        else
            local cron_status=$?
            if [[ "${cron_status}" -eq 124 ]]; then
                warn "Cron probe exceeded 60 seconds and was stopped; the installed cron schedule remains active."
            else
                warn "Cron probe returned exit code ${cron_status}; inspect ${_LOG_FILE}. The installed schedule remains active."
            fi
        fi
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
        state_site_upsert "${site_json}"
    fi

    # Update legacy config if present
    if [[ -f "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" ]]; then
        sed -i "s/^MOODLE_VERSION=.*/MOODLE_VERSION=\"${new_ver_str}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" 2>/dev/null || true
        sed -i "s/^IS_MOODLE5=.*/IS_MOODLE5=\"${IS_TARGET_MOODLE5}\"/" "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" 2>/dev/null || true
    fi
    
    release_lock
    clear_rollbacks
    state_operation_finish "completed" "Upgrade completed to ${new_ver_str} (${TARGET_BRANCH})"
    
    print_box "Upgrade & Security Patching Complete: ${SLUG} ✓" \
        "URL:            https://${DOMAIN:-$SLUG}" \
        "Old Version:    Moodle ${current_real_ver}" \
        "New Version:    Moodle ${new_ver_str} (${TARGET_BRANCH})" \
        "Database Dump:  ${dump_file}" \
        "Git Tree:       $([ "${is_git_repo}" -eq 1 ] && echo "Preserved (in-place)" || echo "Synced")" \
        "Status:         100% Online & Upgraded" \
        "Log:            ${_LOG_FILE}"
}

# Restore the verified pre-upgrade state after any failure that occurs once the
# safety snapshot has been created. Maintenance cleanup runs after this because
# rollback actions are executed in reverse registration order.
_rollback_site_upgrade() {
    [[ -n "${UPGRADE_SAFETY_PATH:-}" && -d "${UPGRADE_SAFETY_PATH}" ]] || return 0
    warn "Restoring pre-upgrade database, code, config, and Nginx state..."

    if [[ -s "${UPGRADE_SAFETY_PATH}/database.sql.gz" ]]; then
        _replace_database_from_dump "${UPGRADE_SAFETY_PATH}/database.sql.gz"
    fi

    if [[ "${UPGRADE_SAFETY_IS_GIT:-0}" == "1" && -s "${UPGRADE_SAFETY_PATH}/git-head.txt" ]]; then
        local original_head
        original_head="$(tr -d '[:space:]' < "${UPGRADE_SAFETY_PATH}/git-head.txt")"
        git -C "${MOODLE_DIR}" reset --hard "${original_head}" >> "${_LOG_FILE}" 2>&1
        if [[ -f "${MOODLE_DIR}/composer.json" ]] && command -v composer &>/dev/null; then
            COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader \
                --no-interaction --working-dir="${MOODLE_DIR}" >> "${_LOG_FILE}" 2>&1
        fi
    elif [[ -n "${UPGRADE_CODE_BACKUP:-}" && -d "${UPGRADE_CODE_BACKUP}" ]]; then
        rsync -a --delete "${UPGRADE_CODE_BACKUP}/" "${MOODLE_DIR}/"
    fi

    local config_file
    config_file="$(find_moodle_config_file "${MOODLE_DIR}")"
    [[ -z "${config_file}" || ! -f "${UPGRADE_SAFETY_PATH}/config.php" ]] \
        || cp -a "${UPGRADE_SAFETY_PATH}/config.php" "${config_file}"
    if [[ -n "${NGINX_CONF:-}" && -f "${UPGRADE_SAFETY_PATH}/nginx.conf" ]]; then
        cp -a "${UPGRADE_SAFETY_PATH}/nginx.conf" "${NGINX_CONF}"
        chmod 644 "${NGINX_CONF}"
        nginx -t >> "${_LOG_FILE}" 2>&1 && systemctl reload nginx
    fi
    normalize_moodle_code_permissions "${MOODLE_DIR}"
    [[ -z "${config_file}" || ! -f "${config_file}" ]] || chmod 640 "${config_file}"
    warn "Pre-upgrade state restored from ${UPGRADE_SAFETY_PATH}"
}
