#!/usr/bin/env bash
# Safely uninstall MoodleKit without deleting Moodle sites or databases.

cmd_uninstall() {
    require_root
    umask 077

    local requested_mode="${1:-}"
    local mode=""
    case "${requested_mode}" in
        "" ) ;;
        program) mode="program" ;;
        automation) mode="automation" ;;
        full) mode="full" ;;
        *)
            err "Unknown uninstall mode '${requested_mode}'."
            err "Use: moodlekit uninstall [program|automation|full]"
            return 1
            ;;
    esac

    section "MoodleKit — Safe Uninstall"
    info "Moodle sites, databases, moodledata, Nginx vhosts, PHP-FPM pools, site cron files, and backups are never deleted."

    if [[ -z "${mode}" ]]; then
        local choice=""
        select_one choice "Select uninstall scope:" \
            "Remove MoodleKit program only (Recommended — keep automation and state)" \
            "Remove program and MoodleKit cloud-backup automation" \
            "Full tool uninstall — archive then remove MoodleKit state and cloud configuration" \
            "Cancel"
        case "${choice}" in
            *"program only"*) mode="program" ;;
            *"cloud-backup automation"*) mode="automation" ;;
            *"Full tool uninstall"*) mode="full" ;;
            *"Cancel"*) info "Uninstall cancelled."; return 0 ;;
        esac
    fi

    if [[ "${mode}" == "full" ]]; then
        warn "Full mode removes the live encrypted vault after archiving it. Reinstallation will need the archive to recover managed credentials."
        confirm_destructive "Archive and remove MoodleKit program, automation, state, and cloud configuration?" "uninstall-full"
    else
        confirm "Proceed with MoodleKit uninstall mode '${mode}'?" "n" || {
            info "Uninstall cancelled."
            return 0
        }
    fi

    local install_dir="${MOODLEKIT_INSTALL_DIR:-/opt/moodlekit}"
    local bin_link="${MOODLEKIT_BIN_LINK:-/usr/local/bin/moodlekit}"
    local systemd_dir="${MOODLEKIT_SYSTEMD_DIR:-/etc/systemd/system}"

    if [[ -n "${MOODLEKIT_UNINSTALL_TEST_ROOT:-}" ]]; then
        local test_root
        test_root="$(readlink -m "${MOODLEKIT_UNINSTALL_TEST_ROOT}")"
        for path in "${install_dir}" "${bin_link}" "${systemd_dir}" \
            "${MOODLEKIT_STATE_DIR}" "${MOODLEKIT_OPT_DIR}" "${MOODLEKIT_BACKUP_DIR}"; do
            [[ "$(readlink -m "${path}")" == "${test_root}"/* ]] || {
                err "Refusing uninstall test path outside ${test_root}: ${path}"
                return 1
            }
        done
    else
        [[ "${install_dir}" == "/opt/moodlekit" && \
           "${bin_link}" == "/usr/local/bin/moodlekit" && \
           "${systemd_dir}" == "/etc/systemd/system" && \
           "${MOODLEKIT_STATE_DIR}" == "/etc/moodlekit" && \
           "${MOODLEKIT_OPT_DIR}" == "/opt/moodlekit-data" && \
           "${MOODLEKIT_BACKUP_DIR}" == "/var/backups/moodlekit" ]] || {
            err "Refusing uninstall because MoodleKit paths are not the expected installation paths."
            return 1
        }
    fi

    if [[ "${mode}" == "automation" || "${mode}" == "full" ]]; then
        systemctl disable --now moodlekit-backup.timer >/dev/null 2>&1 || true
        systemctl stop moodlekit-backup.service >/dev/null 2>&1 || true
        rm -f "${systemd_dir}/moodlekit-backup.timer" "${systemd_dir}/moodlekit-backup.service"
        systemctl daemon-reload
        systemctl reset-failed moodlekit-backup.timer moodlekit-backup.service >/dev/null 2>&1 || true
        ok "MoodleKit cloud-backup systemd units removed"
    fi

    local recovery_archive=""
    if [[ "${mode}" == "full" ]]; then
        recovery_archive="${MOODLEKIT_BACKUP_DIR}/uninstall-recovery-$(date +%Y%m%d_%H%M%S)"
        install -d -m 700 "${recovery_archive}"
        if [[ -d "${MOODLEKIT_STATE_DIR}" ]]; then
            mv "${MOODLEKIT_STATE_DIR}" "${recovery_archive}/moodlekit-state"
        fi
        if [[ -d "${MOODLEKIT_OPT_DIR}" && "${MOODLEKIT_OPT_DIR}" != "${install_dir}" ]]; then
            mv "${MOODLEKIT_OPT_DIR}" "${recovery_archive}/moodlekit-data"
        fi
        chmod -R go-rwx "${recovery_archive}"
        ok "MoodleKit state archived at ${recovery_archive}"
    fi

    if [[ -L "${bin_link}" ]]; then
        local resolved_link
        resolved_link="$(readlink -f "${bin_link}" 2>/dev/null || true)"
        if [[ "${resolved_link}" == "${install_dir}/moodlekit" ]]; then
            rm -f "${bin_link}"
        else
            warn "Preserved ${bin_link}: it does not point to ${install_dir}/moodlekit."
        fi
    elif [[ -e "${bin_link}" ]]; then
        warn "Preserved ${bin_link}: it is not the MoodleKit installer symlink."
    fi

    if [[ -d "${install_dir}" ]]; then
        rm -rf "${install_dir}"
        ok "MoodleKit program removed from ${install_dir}"
    else
        warn "MoodleKit program directory was already absent: ${install_dir}"
    fi

    echo ""
    info "Preserved Moodle runtime resources:"
    info "  /var/www Moodle code, moodledata, databases, Nginx, PHP-FPM, and site cron"
    info "  Local backups under ${MOODLEKIT_BACKUP_DIR}"
    [[ -z "${recovery_archive}" ]] || info "  Recovery archive: ${recovery_archive}"
    ok "MoodleKit uninstall completed safely"
}
