#!/usr/bin/env bash
# =============================================================================
# commands/site-remove.sh — Full tenant teardown
# =============================================================================

cmd_site_remove() {
    require_root
    load_global_conf

    local SLUG="${1:-}"
    [[ -z "${SLUG}" ]] && { err "Usage: moodlekit site remove <slug> [--force]"; exit 1; }

    local FORCE=0
    [[ "${2:-}" == "--force" ]] && FORCE=1

    local is_partial=0
    if ! site_exists "${SLUG}"; then
        if [[ -d "/var/www/moodle/${SLUG}" || -d "/var/moodledata/${SLUG}" ]]; then
            warn "Site '${SLUG}' is not fully registered, but orphaned directories were found."
            if [[ "${FORCE}" -eq 0 ]] && ! confirm "Force clean up these orphaned resources for '${SLUG}'?" "n"; then
                exit 1
            fi
            is_partial=1
        else
            err "Site '${SLUG}' not found. Use 'moodlekit site list' to see all sites."
            exit 1
        fi
    fi

    if [[ "${is_partial}" -eq 0 ]]; then
        load_site_conf "${SLUG}"
    else
        # Provide default variables so the teardown script can attempt to clean up
        DOMAIN="${SLUG}.${BASE_DOMAIN}"
        DB_NAME="moodle_${SLUG}"
        DB_USER="moodle_${SLUG}"
        MOODLE_DIR="/var/www/moodle/${SLUG}"
        MOODLEDATA_DIR="/var/moodledata/${SLUG}"
        PHP_VERSION="${PHP_VERSION:-8.3}"
    fi

    init_logging "site-remove-${SLUG}"

    section "MoodleKit — Remove Site: ${SLUG}"
    warn "This will PERMANENTLY delete:"
    warn "  • Database: ${DB_NAME}"
    warn "  • Moodle files: ${MOODLE_DIR}"
    warn "  • Moodle data: ${MOODLEDATA_DIR}"
    warn "  • FPM pool, Nginx config, cron job"
    echo ""

    if [[ "${FORCE}" -eq 0 ]]; then
        # Offer backup first
        if confirm "Create a backup before removing?" "y"; then
            cmd_backup_site "${SLUG}"
        fi

        # Confirm with slug
        confirm_destructive \
            "Type '${SLUG}' to confirm permanent deletion:" \
            "${SLUG}"
    else
        info "Running in --force mode: skipping confirmations."
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 1 — Maintenance mode
    # ─────────────────────────────────────────────────────────────────────────
    step 1 9 "Enable maintenance mode"
    local admin_cli="${MOODLE_DIR}/$([ "${IS_MOODLE5:-0}" -eq 1 ] && echo "public/")admin/cli"
    if [[ -f "${admin_cli}/maintenance.php" ]]; then
        sudo -u www-data "/usr/bin/php${PHP_VERSION}" \
            "${admin_cli}/maintenance.php" --enable 2>/dev/null || true
        ok "Maintenance mode enabled"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 2 — Remove cron
    # ─────────────────────────────────────────────────────────────────────────
    step 2 9 "Remove cron job"
    rm -f "/etc/cron.d/moodlekit-${SLUG}"
    ok "Cron job removed"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3 — Remove Nginx
    # ─────────────────────────────────────────────────────────────────────────
    step 3 9 "Remove Nginx config"
    rm -f "${NGINX_CONF:-/etc/nginx/sites-available/moodle-${SLUG}}"
    rm -f "${NGINX_CONF:-/etc/nginx/sites-available/moodle-${SLUG}}.http-only"
    rm -f "/etc/nginx/sites-enabled/moodle-${SLUG}"
    reload_nginx
    ok "Nginx config removed"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4 — Remove FPM pool
    # ─────────────────────────────────────────────────────────────────────────
    step 4 9 "Remove PHP-FPM pool"
    rm -f "${FPM_POOL_CONF:-/etc/php/${PHP_VERSION}/fpm/pool.d/moodle_${SLUG}.conf}"
    reload_fpm "${PHP_VERSION}"
    ok "FPM pool removed"

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5 — Drop database
    # ─────────────────────────────────────────────────────────────────────────
    step 5 9 "Drop database"
    case "${DB_TYPE}" in
        postgres) db_pg_drop "${DB_NAME}" "${DB_USER}" ;;
        mariadb)  db_maria_drop "${DB_NAME}" "${DB_USER}" ;;
        mysql)    db_mysql_drop "${DB_NAME}" "${DB_USER}" ;;
    esac

    # ─────────────────────────────────────────────────────────────────────────
    # Step 6 — Remove moodledata
    # ─────────────────────────────────────────────────────────────────────────
    step 6 9 "Remove moodledata"
    if [[ -d "${MOODLEDATA_DIR}" ]]; then
        rm -rf "${MOODLEDATA_DIR}"
        ok "Moodledata removed: ${MOODLEDATA_DIR}"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 7 — Remove Moodle code
    # ─────────────────────────────────────────────────────────────────────────
    step 7 9 "Remove Moodle code"
    if [[ -d "${MOODLE_DIR}" ]]; then
        rm -rf "${MOODLE_DIR}"
        ok "Moodle code removed: ${MOODLE_DIR}"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 8 — Remove TLS cert
    # ─────────────────────────────────────────────────────────────────────────
    step 8 9 "Remove TLS certificate"
    if command -v certbot &>/dev/null; then
        certbot delete --cert-name "${DOMAIN}" --non-interactive 2>/dev/null \
            && ok "TLS cert deleted" || warn "TLS cert not found (skipping)"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Step 9 — Remove state + rebalance FPM
    # ─────────────────────────────────────────────────────────────────────────
    step 9 9 "Remove state + rebalance FPM pools"
    vault_sdel "${SLUG}"
    rm -f "${MOODLEKIT_SITES_DIR}/${SLUG}.conf"
    rm -f "/tmp/moodlekit-${SLUG}.lock"

    # Rebalance remaining sites' FPM workers with freed RAM
    local remaining
    remaining="$(list_site_slugs | wc -l)"
    if (( remaining > 0 )); then
        rebalance_fpm_pools "${DB_TYPE:-mariadb}"
    fi

    ok "Site '${SLUG}' fully removed from encrypted vault and server"
    clear_rollbacks
}
