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
    cp "${MOODLE_DIR}/config.php" "${BACKUP_PATH}/config.php" 2>/dev/null || true
    cp "${MOODLEKIT_SITES_DIR}/${SLUG}.conf" "${BACKUP_PATH}/site.conf" 2>/dev/null || true
    [[ -f "${NGINX_CONF}" ]] && cp "${NGINX_CONF}" "${BACKUP_PATH}/nginx.conf" || true
    [[ -f "${FPM_POOL_CONF}" ]] && cp "${FPM_POOL_CONF}" "${BACKUP_PATH}/fpm-pool.conf" || true
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
    load_global_conf
    init_logging "backup-deploy"

    section "MoodleKit — Deploy Cloud Backup"

    local OPT_DIR="${MOODLEKIT_OPT_DIR}/backup"
    mkdir -p "${OPT_DIR}"

    # ─────────────────────────────────────────────────────────────────────────
    # Copy Python backup script
    # ─────────────────────────────────────────────────────────────────────────
    step 1 5 "Deploy backup script"
    local src_py="${MOODLEKIT_ROOT}/backup/moodle_backup.py"
    if [[ ! -f "${src_py}" ]]; then
        err "Backup script not found: ${src_py}"
        exit 1
    fi
    if [[ "${src_py}" != "${OPT_DIR}/moodle_backup.py" ]]; then
        cp "${src_py}" "${OPT_DIR}/moodle_backup.py"
    fi
    chmod 750 "${OPT_DIR}/moodle_backup.py"
    ok "Backup script deployed to ${OPT_DIR}/moodle_backup.py"

    # ─────────────────────────────────────────────────────────────────────────
    # Create config.json from example (if not exists)
    # ─────────────────────────────────────────────────────────────────────────
    step 2 5 "Create config files"
    if [[ ! -f "${OPT_DIR}/config.json" ]]; then
        # Build moodle_sites list from current sites
        local sites_json='['
        local first=1
        while IFS= read -r slug; do
            [[ -z "${slug}" ]] && continue
            load_site_conf "${slug}"
            [[ "${first}" -eq 0 ]] && sites_json+=','
            sites_json+="\"${MOODLE_DIR}\""
            first=0
        done < <(list_site_slugs)
        sites_json+=']'

        cat > "${OPT_DIR}/config.json" << CONFIGJSON
{
  "server_name": "$(hostname -f)",
  "log_dir": "/var/log/moodlekit",
  "local_backup_root": "${MOODLEKIT_BACKUP_DIR}",
  "gdrive_remote": "gdrive:moodlekit-backups",
  "moodle_sites": ${sites_json},
  "extra_backup_dirs": [
    {"name": "nginx-conf", "path": "/etc/nginx/sites-available"},
    {"name": "moodlekit-conf", "path": "/etc/moodlekit"}
  ],
  "rclone": {
    "transfers": 4,
    "checkers": 8,
    "tpslimit": 10,
    "drive_chunk_size": "128M",
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
        ok "config.json created"
    else
        ok "config.json already exists — not overwriting"
    fi

    if [[ ! -f "${OPT_DIR}/secrets.json" ]]; then
        cat > "${OPT_DIR}/secrets.json" << 'SECRETJSON'
{
  "telegram_bot_token": "YOUR_BOT_TOKEN_HERE",
  "telegram_chat_id": "YOUR_CHAT_ID_HERE",
  "drive_client_id": "",
  "drive_client_secret": ""
}
SECRETJSON
        chmod 600 "${OPT_DIR}/secrets.json"
        warn "Fill in secrets: ${OPT_DIR}/secrets.json"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Install systemd service + timer
    # ─────────────────────────────────────────────────────────────────────────
    step 3 5 "Install systemd service + timer"
    cp "${MOODLEKIT_TPL}/systemd-backup.service" \
       /etc/systemd/system/moodlekit-backup.service
    cp "${MOODLEKIT_TPL}/systemd-backup.timer" \
       /etc/systemd/system/moodlekit-backup.timer

    systemctl daemon-reload
    ok "systemd units installed"

    # ─────────────────────────────────────────────────────────────────────────
    # Enable and start timer
    # ─────────────────────────────────────────────────────────────────────────
    step 4 5 "Enable backup timer"
    systemctl enable --now moodlekit-backup.timer
    ok "Timer enabled — daily at 02:00 + up to 5min random jitter"

    # ─────────────────────────────────────────────────────────────────────────
    # Install rclone
    # ─────────────────────────────────────────────────────────────────────────
    step 5 6 "Install rclone"
    if ! command -v rclone &>/dev/null; then
        spinner_start "Installing latest rclone..."
        curl -s https://rclone.org/install.sh | sudo bash &>> "${_LOG_FILE}" || true
        spinner_stop 0 "rclone installed"
    else
        ok "rclone found: $(rclone --version | head -1)"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Configure Google Drive Headless
    # ─────────────────────────────────────────────────────────────────────────
    step 6 6 "Configure Google Drive (Headless)"
    info "We will now configure Google Drive."
    info "You will need your Google API Client ID and Client Secret."
    
    local drive_client_id=""
    input_text drive_client_id "Google Drive Client ID" "" '.*' "Required"
    
    local drive_client_secret=""
    input_text drive_client_secret "Google Drive Client Secret" "" '.*' "Required"

    # Save to secrets.json
    jq ".drive_client_id = \"${drive_client_id}\" | .drive_client_secret = \"${drive_client_secret}\"" "${OPT_DIR}/secrets.json" > "${OPT_DIR}/secrets.tmp.json"
    mv "${OPT_DIR}/secrets.tmp.json" "${OPT_DIR}/secrets.json"

    echo ""
    info "Because this server has no web browser, you must authorize on your personal computer."
    info "1. Download rclone on your personal computer (https://rclone.org/downloads/)"
    info "2. Open a terminal/command prompt on your personal computer and run THIS EXACT COMMAND:"
    echo -e "${C_BOLD_YELLOW}rclone authorize \"drive\" \"${drive_client_id}\" \"${drive_client_secret}\"${C_RESET}"
    info "3. It will open your web browser. Log in and grant full permissions."
    info "4. It will output a long 'token' string that looks like: {\"access_token\":\"...\"...}"
    echo ""

    local drive_token=""
    input_text drive_token "Paste the entire token string here" "" '^\{.*\}$' "Token must be a valid JSON string starting with {"

    # Create rclone config manually
    local rclone_conf_dir
    rclone_conf_dir="/root/.config/rclone"
    mkdir -p "${rclone_conf_dir}"
    
    cat > "${rclone_conf_dir}/rclone.conf" << RCLONECONF
[gdrive]
type = drive
client_id = ${drive_client_id}
client_secret = ${drive_client_secret}
scope = drive
token = ${drive_token}
RCLONECONF
    chmod 600 "${rclone_conf_dir}/rclone.conf"
    
    ok "Google Drive configured securely as 'gdrive'."

    print_box "Cloud Backup Deployed ✓" \
        "Script:  ${OPT_DIR}/moodle_backup.py" \
        "Config:  ${OPT_DIR}/config.json" \
        "Secrets: ${OPT_DIR}/secrets.json" \
        "" \
        "Next steps:" \
        "  1. Edit secrets.json to set your Telegram tokens" \
        "  2. Test manually: python3 ${OPT_DIR}/moodle_backup.py --config ${OPT_DIR}/config.json --secrets ${OPT_DIR}/secrets.json" \
        "  3. Check timer: systemctl list-timers moodlekit-backup*"
}
