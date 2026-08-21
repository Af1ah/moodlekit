#!/usr/bin/env bash
# =============================================================================
# commands/backup.sh — Local backup + cloud backup deployment
# =============================================================================

# ---------------------------------------------------------------------------
# Local backup for a single site
# ---------------------------------------------------------------------------
cmd_backup_site() {
    local SLUG="${1:-}"
    local DB_ONLY="${OPT_DB_ONLY:-0}"
    local OUTPUT_DIR="${OPT_OUTPUT:-${MOODLEKIT_BACKUP_DIR}}"

    [[ -z "${SLUG}" ]] && { err "Usage: moodlekit backup <slug>"; exit 1; }
    site_exists "${SLUG}" || { err "Site '${SLUG}' not found"; exit 1; }
    load_site_conf "${SLUG}"

    require_root
    init_logging "backup-${SLUG}"

    local TIMESTAMP
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    local BACKUP_PATH="${OUTPUT_DIR}/${SLUG}/${TIMESTAMP}"
    mkdir -p "${BACKUP_PATH}"

    section "MoodleKit — Backup: ${SLUG}"
    info "Output: ${BACKUP_PATH}"
    echo ""

    local steps=4
    [[ "${DB_ONLY}" == "1" ]] && steps=2

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1 — Database dump
    # ─────────────────────────────────────────────────────────────────────────
    step 1 "${steps}" "Database dump"
    local dump_file="${BACKUP_PATH}/database.sql.gz"
    case "${DB_TYPE}" in
        postgres) db_pg_dump    "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mariadb)  db_maria_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
        mysql)    db_mysql_dump "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${dump_file}" ;;
    esac

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2 — Config + state files
    # ─────────────────────────────────────────────────────────────────────────
    step 2 "${steps}" "Config and state files"
    [[ -f "${MOODLE_DIR}/config.php" ]] && cp "${MOODLE_DIR}/config.php" "${BACKUP_PATH}/config.php" 2>/dev/null || true
    vault_sget "${SLUG}" > "${BACKUP_PATH}/site.json" 2>/dev/null || true
    [[ -f "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" ]] && cp "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" "${BACKUP_PATH}/site.conf" 2>/dev/null || true
    [[ -n "${NGINX_CONF:-}" && -f "${NGINX_CONF}" ]] && cp "${NGINX_CONF}" "${BACKUP_PATH}/nginx.conf" || true
    [[ -n "${FPM_POOL_CONF:-}" && -f "${FPM_POOL_CONF}" ]] && cp "${FPM_POOL_CONF}" "${BACKUP_PATH}/fpm-pool.conf" || true
    ok "Config files copied"

    if [[ "${DB_ONLY}" == "1" ]]; then
        _write_manifest "${BACKUP_PATH}" "${SLUG}" "database"
        ok "DB-only backup complete: ${BACKUP_PATH}"
        return 0
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3 — moodledata archive
    # ─────────────────────────────────────────────────────────────────────────
    step 3 "${steps}" "moodledata archive"
    spinner_start "Archiving moodledata (excluding cache/sessions/trash)..."
    tar --create --gzip \
        --file="${BACKUP_PATH}/moodledata.tar.gz" \
        --exclude="${MOODLEDATA_DIR}/cache" \
        --exclude="${MOODLEDATA_DIR}/localcache" \
        --exclude="${MOODLEDATA_DIR}/sessions" \
        --exclude="${MOODLEDATA_DIR}/trashdir" \
        --exclude="${MOODLEDATA_DIR}/temp" \
        --directory="$(dirname "${MOODLEDATA_DIR}")" \
        "$(basename "${MOODLEDATA_DIR}")" 2>&1 | tee -a "${_LOG_FILE}"
    spinner_stop 0 "moodledata archived"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4 — Optional code archive
    # ─────────────────────────────────────────────────────────────────────────
    step 4 "${steps}" "Moodle code snapshot"
    if confirm "Include Moodle code in backup? (large, ~500MB+)" "n"; then
        spinner_start "Archiving Moodle code..."
        tar --create --gzip \
            --file="${BACKUP_PATH}/code.tar.gz" \
            --exclude="${MOODLE_DIR}/.git" \
            --exclude="${MOODLE_DIR}/node_modules" \
            --directory="$(dirname "${MOODLE_DIR}")" \
            "$(basename "${MOODLE_DIR}")" 2>&1 | tee -a "${_LOG_FILE}"
        spinner_stop 0 "Code archived"
    else
        info "Code snapshot skipped"
    fi

    # Write manifest
    _write_manifest "${BACKUP_PATH}" "${SLUG}" "full"

    # Summary
    local total_size
    total_size="$(du -sh "${BACKUP_PATH}" | cut -f1)"
    print_box "Backup Complete: ${SLUG}" \
        "Location: ${BACKUP_PATH}" \
        "Size:     ${total_size}" \
        "Time:     ${TIMESTAMP}"
}

# ---------------------------------------------------------------------------
# Write backup manifest.json
# ---------------------------------------------------------------------------
_write_manifest() {
    local backup_path="$1"
    local slug="$2"
    local backup_type="$3"

    # Checksums
    local db_sha=""
    [[ -f "${backup_path}/database.sql.gz" ]] && \
        db_sha="$(sha256sum "${backup_path}/database.sql.gz" | cut -d' ' -f1)"
    local data_sha=""
    [[ -f "${backup_path}/moodledata.tar.gz" ]] && \
        data_sha="$(sha256sum "${backup_path}/moodledata.tar.gz" | cut -d' ' -f1)"

    cat > "${backup_path}/manifest.json" << MANIFEST
{
  "tool": "moodlekit",
  "tool_version": "${MOODLEKIT_VERSION}",
  "backup_type": "${backup_type}",
  "timestamp": "$(date -Iseconds)",
  "slug": "${slug}",
  "domain": "${DOMAIN}",
  "moodle_version": "${MOODLE_VERSION}",
  "is_moodle5": ${IS_MOODLE5:-0},
  "php_version": "${PHP_VERSION}",
  "db_type": "${DB_TYPE}",
  "db_name": "${DB_NAME}",
  "moodle_dir": "${MOODLE_DIR}",
  "moodledata_dir": "${MOODLEDATA_DIR}",
  "checksums": {
    "database.sql.gz": "${db_sha}",
    "moodledata.tar.gz": "${data_sha}"
  }
}
MANIFEST
    chmod 600 "${backup_path}/manifest.json"
    ok "Manifest written"
}

# ---------------------------------------------------------------------------
# Backup all sites
# ---------------------------------------------------------------------------
cmd_backup_all() {
    load_global_conf
    local slugs
    mapfile -t slugs < <(list_site_slugs)

    if [[ ${#slugs[@]} -eq 0 ]]; then
        warn "No sites found to back up."
        return 0
    fi

    section "MoodleKit — Backup All Sites (${#slugs[@]})"
    for slug in "${slugs[@]}"; do
        echo ""
        info "Backing up: ${slug}"
        OPT_DB_ONLY=0 cmd_backup_site "${slug}"
    done
    ok "All sites backed up"
}

# ---------------------------------------------------------------------------
# Deploy Python cloud backup + systemd timer
# ---------------------------------------------------------------------------
cmd_backup_deploy() {
    require_root
    load_global_conf 0 || true
    init_logging "backup-deploy"

    section "MoodleKit — Deploy Cloud Backup"

    local OPT_DIR="${MOODLEKIT_OPT_DIR}/backup"
    mkdir -p "${OPT_DIR}"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1 — Timezone & Schedule Selection
    # ─────────────────────────────────────────────────────────────────────────
    step 1 6 "Timezone & schedule configuration"
    local server_tz
    server_tz="$(configure_system_timezone 0)"
    
    local backup_time="02:00"
    if is_interactive; then
        local time_choice=""
        select_one time_choice "Select daily backup schedule time (Current timezone: ${server_tz}):" \
            "02:00 AM (02:00) [Recommended - Lowest server traffic]" \
            "01:00 AM (01:00)" \
            "03:00 AM (03:00)" \
            "04:00 AM (04:00)" \
            "11:00 PM (23:00)" \
            "12:00 AM (00:00 - Midnight)" \
            "Custom Time (enter HH:MM in 24h format)"

        case "${time_choice}" in
            *"02:00 AM"*) backup_time="02:00" ;;
            *"01:00 AM"*) backup_time="01:00" ;;
            *"03:00 AM"*) backup_time="03:00" ;;
            *"04:00 AM"*) backup_time="04:00" ;;
            *"11:00 PM"*) backup_time="23:00" ;;
            *"12:00 AM"*) backup_time="00:00" ;;
            *"Custom Time"*)
                input_text backup_time "Enter time in 24h format HH:MM (e.g. 02:30)" "02:00" '^([01][0-9]|2[0-3]):[0-5][0-9]$' "Must be valid 24h time in HH:MM format"
                ;;
        esac
    fi
    ok "Backup schedule set to daily at ${backup_time} (${server_tz})"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2 — Copy Python backup script
    # ─────────────────────────────────────────────────────────────────────────
    step 2 6 "Deploy backup engine"
    local src_py="${MOODLEKIT_ROOT}/backup/moodle_backup.py"
    if [[ ! -f "${src_py}" ]]; then
        err "Backup script not found: ${src_py}"
        exit 1
    fi
    if [[ "${src_py}" != "${OPT_DIR}/moodle_backup.py" ]]; then
        cp "${src_py}" "${OPT_DIR}/moodle_backup.py"
    fi
    chmod 750 "${OPT_DIR}/moodle_backup.py"
    ok "Backup engine deployed to ${OPT_DIR}/moodle_backup.py"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3 — Create config.json matching exact reference architecture
    # ─────────────────────────────────────────────────────────────────────────
    step 3 6 "Create configuration & credentials"
    if [[ ! -f "${OPT_DIR}/config.json" ]]; then
        # Build moodle_sites list from vault & scanned sites
        local sites_json='['
        local first=1
        while IFS= read -r sdir; do
            [[ -z "${sdir}" ]] && continue
            [[ "${first}" -eq 0 ]] && sites_json+=','
            sites_json+="\"${sdir}\""
            first=0
        done < <(find_moodle_installations 2>/dev/null)
        sites_json+=']'

        cat > "${OPT_DIR}/config.json" << CONFIGJSON
{
  "server_name": "$(hostname -f)",
  "log_dir": "/var/log/moodlekit",
  "local_backup_root": "/opt/db_backups",
  "gdrive_remote": "gdrive:MoodleBackup",
  "moodle_sites": ${sites_json},
  "extra_backup_dirs": [
    "/etc/nginx/sites-available",
    "/etc/moodlekit"
  ],
  "rclone": {
    "transfers": 8,
    "checkers": 12,
    "tpslimit": 8,
    "drive_chunk_size": "32M",
    "bwlimit": "0",
    "extra_flags": []
  },
  "stall_timeout_seconds": 420,
  "poll_interval_seconds": 5,
  "max_retries": 3,
  "retry_backoff_seconds": 30,
  "keep_last_n_db_dumps": 3,
  "telegram_edit_interval_seconds": 15
}
CONFIGJSON
        chmod 600 "${OPT_DIR}/config.json"
        ok "config.json created (/opt/db_backups -> gdrive:MoodleBackup)"
    else
        ok "config.json already exists — preserving existing settings"
    fi

    # Telegram Notifications Setup
    local tg_token=""
    local tg_chat=""
    if [[ "${MOODLEKIT_YES:-0}" != "1" ]]; then
        info "Optional: Configure Telegram live backup notifications"
        input_text tg_token "Telegram Bot Token [Press Enter to skip]" "" '.*' ""
        if [[ -n "${tg_token}" ]]; then
            input_text tg_chat "Telegram Chat ID" "" '.*' "Chat ID required"
            vault_gset "telegram_bot_token" "${tg_token}"
            vault_gset "telegram_chat_id" "${tg_chat}"
            ok "Telegram credentials stored in encrypted vault"
        fi
    fi

    if [[ ! -f "${OPT_DIR}/secrets.json" ]]; then
        cat > "${OPT_DIR}/secrets.json" << SECRETJSON
{
  "telegram_bot_token": "${tg_token:-YOUR_BOT_TOKEN_HERE}",
  "telegram_chat_id": "${tg_chat:-YOUR_CHAT_ID_HERE}",
  "drive_client_id": "",
  "drive_client_secret": ""
}
SECRETJSON
        chmod 600 "${OPT_DIR}/secrets.json"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4 — Install systemd service + customized timer
    # ─────────────────────────────────────────────────────────────────────────
    step 4 6 "Install systemd service + timer"
    cp "${MOODLEKIT_TPL}/systemd-backup.service" \
       /etc/systemd/system/moodlekit-backup.service

    cat > /etc/systemd/system/moodlekit-backup.timer << TIMERF
[Unit]
Description=Run MoodleKit cloud backup daily at ${backup_time} (${server_tz})

[Timer]
OnCalendar=*-*-* ${backup_time}:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
TIMERF

    systemctl daemon-reload
    systemctl enable --now moodlekit-backup.timer
    ok "Timer active: Daily at ${backup_time} (${server_tz}) + up to 5min jitter"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5 — Install rclone
    # ─────────────────────────────────────────────────────────────────────────
    step 5 6 "Verify rclone installation"
    if ! command -v rclone &>/dev/null; then
        spinner_start "Installing latest rclone..."
        curl -s https://rclone.org/install.sh | sudo bash &>> "${_LOG_FILE}" || true
        spinner_stop 0 "rclone installed"
    else
        ok "rclone found: $(rclone --version 2>/dev/null | head -1)"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 6 — Configure Google Drive Headless
    # ─────────────────────────────────────────────────────────────────────────
    step 6 6 "Configure Google Drive remote ('gdrive')"
    local rclone_conf="/root/.config/rclone/rclone.conf"
    if [[ -f "${rclone_conf}" ]] && grep -q '\[gdrive\]' "${rclone_conf}"; then
        ok "Google Drive remote '[gdrive]' already exists in ${rclone_conf}"
    else
        info "Configuring Google Drive remote..."
        local drive_client_id=""
        input_text drive_client_id "Google Drive Client ID [Press enter to use default]" "" '.*' ""
        
        local drive_client_secret=""
        if [[ -n "${drive_client_id}" ]]; then
            input_text drive_client_secret "Google Drive Client Secret" "" '.*' "Required if Client ID provided"
            vault_gset "drive_client_id" "${drive_client_id}"
            vault_gset "drive_client_secret" "${drive_client_secret}"
            jq ".drive_client_id = \"${drive_client_id}\" | .drive_client_secret = \"${drive_client_secret}\"" "${OPT_DIR}/secrets.json" > "${OPT_DIR}/secrets.tmp.json" 2>/dev/null || true
            [[ -f "${OPT_DIR}/secrets.tmp.json" ]] && mv "${OPT_DIR}/secrets.tmp.json" "${OPT_DIR}/secrets.json" || true
        fi

        echo ""
        info "Headless Authorization Step:"
        info "1. Open a terminal on your personal computer (with a web browser)."
        info "2. Run this command on your computer:"
        if [[ -n "${drive_client_id}" && -n "${drive_client_secret}" ]]; then
            echo -e "${C_BOLD_YELLOW}rclone authorize \"drive\" \"${drive_client_id}\" \"${drive_client_secret}\"${C_RESET}"
        else
            echo -e "${C_BOLD_YELLOW}rclone authorize \"drive\"${C_RESET}"
        fi
        info "3. Log in to Google, grant permissions, and copy the full token JSON output string."
        echo ""

        local drive_token=""
        input_text drive_token "Paste the entire token string here" "" '^\{.*\}$' "Token must be a valid JSON string starting with {"

        mkdir -p "/root/.config/rclone"
        cat > "${rclone_conf}" << RCLONECONF
[gdrive]
type = drive
client_id = ${drive_client_id}
client_secret = ${drive_client_secret}
scope = drive
token = ${drive_token}
RCLONECONF
        chmod 600 "${rclone_conf}"
        ok "Google Drive remote configured securely as 'gdrive'."
    fi

    print_box "Cloud Backup Deployed Successfully ✓" \
        "Schedule:     Daily at ${backup_time} (${server_tz})" \
        "Remote:       gdrive:MoodleBackup/{hostname}/{domain}/" \
        "Local Dumps:  /opt/db_backups/{hostname}/{domain}/" \
        "Script:       ${OPT_DIR}/moodle_backup.py" \
        "Config:       ${OPT_DIR}/config.json" \
        "Timer:        systemctl list-timers moodlekit-backup*"
}
