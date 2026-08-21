#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — MoodleKit shared utilities
# =============================================================================
# Logging, colors, error handling, rollback stack, template renderer,
# password generation, lock file management.
# Source this file; do NOT execute directly.
# =============================================================================

# Guard against double-sourcing
[[ -n "${_MOODLEKIT_COMMON_LOADED:-}" ]] && return 0
_MOODLEKIT_COMMON_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & version
# ---------------------------------------------------------------------------
MOODLEKIT_VERSION="${MOODLEKIT_VERSION:-2.0.0}"
MOODLEKIT_STATE_DIR="${MOODLEKIT_STATE_DIR:-/etc/moodlekit}"
MOODLEKIT_SITES_DIR="${MOODLEKIT_SITES_DIR:-${MOODLEKIT_STATE_DIR}/sites}"
MOODLEKIT_LOG_DIR="${MOODLEKIT_LOG_DIR:-/var/log/moodlekit}"
MOODLEKIT_BACKUP_DIR="${MOODLEKIT_BACKUP_DIR:-/var/backups/moodlekit}"
MOODLEKIT_OPT_DIR="${MOODLEKIT_OPT_DIR:-/opt/moodlekit}"

# Determine script root (where moodlekit binary lives)
MOODLEKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOODLEKIT_LIB="${MOODLEKIT_ROOT}/lib"
MOODLEKIT_CMD="${MOODLEKIT_ROOT}/commands"
MOODLEKIT_TPL="${MOODLEKIT_ROOT}/templates"

# shellcheck source=lib/vault.sh
[[ -f "${MOODLEKIT_LIB}/vault.sh" ]] && source "${MOODLEKIT_LIB}/vault.sh"


# ---------------------------------------------------------------------------
# Colors (disabled when NO_COLOR is set or output is not a terminal)
# ---------------------------------------------------------------------------
_setup_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
        C_RESET='\033[0m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[0;33m'
        C_BLUE='\033[0;34m'
        C_MAGENTA='\033[0;35m'
        C_CYAN='\033[0;36m'
        C_WHITE='\033[0;37m'
        C_BOLD_GREEN='\033[1;32m'
        C_BOLD_YELLOW='\033[1;33m'
        C_BOLD_RED='\033[1;31m'
        C_BOLD_CYAN='\033[1;36m'
        C_BOLD_WHITE='\033[1;37m'
    else
        C_RESET='' C_BOLD='' C_DIM=''
        C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
        C_MAGENTA='' C_CYAN='' C_WHITE=''
        C_BOLD_GREEN='' C_BOLD_YELLOW='' C_BOLD_RED=''
        C_BOLD_CYAN='' C_BOLD_WHITE=''
    fi
}
_setup_colors

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Log file — set by init_logging()
_LOG_FILE=""
_VERBOSE="${MOODLEKIT_VERBOSE:-0}"
_DRY_RUN="${MOODLEKIT_DRY_RUN:-0}"

init_logging() {
    local cmd="${1:-moodlekit}"
    mkdir -p "${MOODLEKIT_LOG_DIR}"
    _LOG_FILE="${MOODLEKIT_LOG_DIR}/${cmd}-$(date +%Y%m%d_%H%M%S).log"
    touch "${_LOG_FILE}"
    log_raw "=== MoodleKit v${MOODLEKIT_VERSION} — ${cmd} — $(date) ==="
}

log_raw() {
    [[ -n "${_LOG_FILE}" ]] && echo "$*" >> "${_LOG_FILE}" 2>/dev/null || true
}

log() {
    local msg="$*"
    echo -e "  ${C_DIM}${msg}${C_RESET}" | tee -a "${_LOG_FILE:-/dev/null}" 2>/dev/null || echo -e "  ${C_DIM}${msg}${C_RESET}"
}

info() {
    local msg="$*"
    echo -e "${C_BOLD_CYAN}ℹ${C_RESET}  ${msg}" | tee -a "${_LOG_FILE:-/dev/null}" 2>/dev/null || echo -e "${C_BOLD_CYAN}ℹ${C_RESET}  ${msg}"
}

ok() {
    local msg="$*"
    echo -e "${C_BOLD_GREEN}✓${C_RESET}  ${msg}" | tee -a "${_LOG_FILE:-/dev/null}" 2>/dev/null || echo -e "${C_BOLD_GREEN}✓${C_RESET}  ${msg}"
}

warn() {
    local msg="$*"
    echo -e "${C_BOLD_YELLOW}⚠${C_RESET}  ${msg}" | tee -a "${_LOG_FILE:-/dev/null}" 2>/dev/null || echo -e "${C_BOLD_YELLOW}⚠${C_RESET}  ${msg}"
}

err() {
    local msg="$*"
    echo -e "${C_BOLD_RED}✗${C_RESET}  ${msg}" >&2
    [[ -n "${_LOG_FILE}" ]] && echo "ERROR: ${msg}" >> "${_LOG_FILE}" 2>/dev/null || true
}

section() {
    local title="$*"
    local line
    line="$(printf '─%.0s' {1..60})"
    echo ""
    echo -e "${C_BOLD_WHITE}${line}${C_RESET}"
    echo -e "${C_BOLD_WHITE}  ${title}${C_RESET}"
    echo -e "${C_BOLD_WHITE}${line}${C_RESET}"
    log_raw ""
    log_raw "=== ${title} ==="
}

step() {
    local num="$1"; local total="$2"; local msg="$3"
    echo -e "\n${C_BOLD_CYAN}[${num}/${total}]${C_RESET} ${C_BOLD}${msg}${C_RESET}"
    log_raw "[${num}/${total}] ${msg}"
}

verbose() {
    [[ "${_VERBOSE}" == "1" ]] && log "$*" || true
}

dry_run_note() {
    [[ "${_DRY_RUN}" == "1" ]] && echo -e "  ${C_DIM}[DRY-RUN] would execute: $*${C_RESET}" || true
}

# ---------------------------------------------------------------------------
# Error handling + rollback stack
# ---------------------------------------------------------------------------
_ROLLBACK_STACK=()

# Register a cleanup command to run on failure (LIFO order)
register_rollback() {
    _ROLLBACK_STACK+=("$*")
}

# Execute all registered rollbacks in reverse order
run_rollbacks() {
    if [[ ${#_ROLLBACK_STACK[@]} -gt 0 ]]; then
        warn "Running cleanup/rollback actions..."
        local i
        for (( i=${#_ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
            local cmd="${_ROLLBACK_STACK[$i]}"
            warn "  Rollback: ${cmd}"
            eval "${cmd}" 2>/dev/null || warn "  Rollback failed (continuing): ${cmd}"
        done
    fi
}

# Clear rollback stack (call on success)
clear_rollbacks() {
    _ROLLBACK_STACK=()
}

# ERR trap — logs line number and runs rollbacks
_err_handler() {
    local exit_code=$?
    local line_no="${1:-unknown}"
    err "Command failed at line ${line_no} (exit code: ${exit_code})"
    [[ -n "${_LOG_FILE}" ]] && err "Full log: ${_LOG_FILE}"
    run_rollbacks
    exit "${exit_code}"
}
trap '_err_handler ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "This command must be run as root (or with sudo)."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Lock file (single-instance enforcement)
# ---------------------------------------------------------------------------
_LOCK_FD=""
_LOCK_FILE=""

acquire_lock() {
    local name="${1:-moodlekit}"
    _LOCK_FILE="/run/lock/moodlekit-${name}.lock"
    mkdir -p /run/lock
    exec {_LOCK_FD}>"${_LOCK_FILE}"
    if ! flock -n "${_LOCK_FD}"; then
        err "Another moodlekit ${name} process is already running (${_LOCK_FILE})."
        err "If this is stale, delete ${_LOCK_FILE} and retry."
        exit 1
    fi
    register_rollback "flock -u ${_LOCK_FD} 2>/dev/null || true"
}

release_lock() {
    [[ -n "${_LOCK_FD}" ]] && flock -u "${_LOCK_FD}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------
gen_password() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -d '/+=' | head -c "${length}"
}

gen_password_alnum() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
}

# ---------------------------------------------------------------------------
# Template renderer
# Replaces {{PLACEHOLDER}} tokens in a .tpl file
# Usage: render_template <template_file> [key=value ...]
# Outputs rendered content to stdout
# ---------------------------------------------------------------------------
render_template() {
    local tpl_file="$1"; shift
    local content
    content="$(cat "${tpl_file}")"

    # Apply each key=value substitution
    while [[ $# -gt 0 ]]; do
        local pair="$1"; shift
        local key="${pair%%=*}"
        local val="${pair#*=}"
        # Escape characters for sed
        val="${val//\\/\\\\}"
        val="${val//|/\\|}"
        val="${val//&/\\&}"
        val="${val//$'\n'/\\n}"
        content="$(echo "${content}" | sed "s|{{${key}}}|${val}|g")"
    done

    echo "${content}"
}

# Write rendered template to a file
render_template_to_file() {
    local tpl_file="$1"
    local out_file="$2"
    shift 2
    render_template "${tpl_file}" "$@" > "${out_file}"
}

# ---------------------------------------------------------------------------
# Moodle version/structure detection
# ---------------------------------------------------------------------------
# Returns: "4" or "5"
detect_moodle_major() {
    local moodle_dir="$1"
    local ver_file="${moodle_dir}/version.php"
    [[ -f "${ver_file}" ]] || { err "No version.php found in ${moodle_dir}"; return 1; }
    local release
    release="$(grep -E '^\$release\s*=' "${ver_file}" | head -1 | grep -oE '[0-9]+\.[0-9]')"
    local major="${release%%.*}"
    echo "${major}"
}

# ---------------------------------------------------------------------------
# Convert a "major.minor" version string to the correct Moodle git branch name
# e.g. "4.5" -> "MOODLE_405_STABLE", "5.2" -> "MOODLE_502_STABLE"
# The branch number is: major * 100 + minor
# ---------------------------------------------------------------------------
moodle_version_to_branch() {
    local version="$1"
    local major="${version%%.*}"
    local minor="${version##*.}"
    # Strip any extra segments (e.g. 4.5.1 → minor=5)
    minor="${minor%%.*}"
    local branch_num=$(( major * 100 + minor ))
    echo "MOODLE_${branch_num}_STABLE"
}

# Returns: "traditional" or "public"
detect_moodle_structure() {
    local moodle_dir="$1"
    if [[ -d "${moodle_dir}/public" ]]; then
        echo "public"
    else
        echo "traditional"
    fi
}

# Returns the document root (web-accessible directory)
moodle_webroot() {
    local moodle_dir="$1"
    local structure
    structure="$(detect_moodle_structure "${moodle_dir}")"
    if [[ "${structure}" == "public" ]]; then
        echo "${moodle_dir}/public"
    else
        echo "${moodle_dir}"
    fi
}

# Returns path to admin/cli directory
moodle_admin_cli() {
    local moodle_dir="$1"
    local webroot
    webroot="$(moodle_webroot "${moodle_dir}")"
    echo "${webroot}/admin/cli"
}

# ---------------------------------------------------------------------------
# Global & Site config helpers (Backed by Encrypted Binary Vault)
# ---------------------------------------------------------------------------
load_global_conf() {
    local required="${1:-0}"
    if type vault_load_global &>/dev/null && vault_load_global; then
        return 0
    fi
    local conf="${MOODLEKIT_STATE_DIR}/global.conf"
    if [[ -f "${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${conf}"
        return 0
    fi

    if [[ "${required}" == "1" ]]; then
        err "Global configuration not found in encrypted vault or ${conf}"
        err "Run 'moodlekit bootstrap' first."
        exit 1
    fi
    # Provide safe fallback defaults so status and diagnostic tools never crash
    BASE_DOMAIN="${BASE_DOMAIN:-}"
    PHP_VERSION="${PHP_VERSION:-8.3}"
    DB_TYPE="${DB_TYPE:-postgres}"
    USE_REDIS="${USE_REDIS:-0}"
    USE_MEMCACHED="${USE_MEMCACHED:-0}"
    return 1
}

load_site_conf() {
    local slug="$1"
    local required="${2:-1}"
    if type vault_load_site &>/dev/null && vault_load_site "${slug}"; then
        return 0
    fi
    local conf="${MOODLEKIT_SITES_DIR}/${slug}.conf"
    if [[ -f "${conf}" ]]; then
        # shellcheck source=/dev/null
        source "${conf}"
        return 0
    fi
    if [[ "${required}" == "1" ]]; then
        err "Site config not found for '${slug}' in encrypted vault or ${conf}"
        local avail
        avail="$(list_site_slugs | tr '\n' ' ')"
        [[ -n "${avail}" ]] && err "Available sites: ${avail}"
        exit 1
    fi
    return 1
}

list_site_slugs() {
    if type vault_slist &>/dev/null; then
        vault_slist
    else
        find "${MOODLEKIT_SITES_DIR}" -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.conf$||' | sort
    fi
}

list_removable_slugs() {
    {
        list_site_slugs
        find "/var/www/moodle" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's|.*/||'
    } | sort -u
}

site_exists() {
    local slug="$1"
    if type vault_site_exists &>/dev/null && vault_site_exists "${slug}"; then
        return 0
    fi
    [[ -f "${MOODLEKIT_SITES_DIR}/${slug}.conf" ]]
}

# ---------------------------------------------------------------------------
# Moodle Site Discovery (Auto-detect standalone & unmanaged Moodle sites)
# ---------------------------------------------------------------------------
find_moodle_installations() {
    local search_dirs=("/var/www" "/var/www/html" "/var/www/moodle" "/home" "/opt")
    local found_dirs=()

    for base in "${search_dirs[@]}"; do
        [[ -d "${base}" ]] || continue
        # Find directories with version.php
        while IFS= read -r vfile; do
            local mdir
            mdir="$(dirname "${vfile}")"
            # Check if it looks like Moodle
            if grep -qE "(\$release|\$version)\s*=" "${vfile}" 2>/dev/null; then
                found_dirs+=("${mdir}")
            fi
        done < <(find "${base}" -maxdepth 5 -name "version.php" -type f 2>/dev/null)
    done

    # Print unique directories
    if [[ ${#found_dirs[@]} -gt 0 ]]; then
        printf '%s\n' "${found_dirs[@]}" | sort -u
    fi
}


# ---------------------------------------------------------------------------
# Slug validation
# ---------------------------------------------------------------------------
validate_slug() {
    local slug="$1"
    if [[ ! "${slug}" =~ ^[a-z][a-z0-9-]{2,19}$ ]]; then
        err "Invalid slug '${slug}'."
        err "Slugs must: start with a letter, be 3–20 chars, only contain [a-z0-9-]"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Service management helpers
# ---------------------------------------------------------------------------
reload_nginx() {
    if [[ "${_DRY_RUN}" == "1" ]]; then
        dry_run_note "nginx -t && systemctl reload nginx"
        return 0
    fi
    nginx -t 2>&1 | tee -a "${_LOG_FILE:-/dev/null}"
    systemctl reload nginx
    ok "Nginx reloaded"
}

reload_fpm() {
    local php_ver="${1:-}"
    if [[ -n "${php_ver}" ]]; then
        local svc="php${php_ver}-fpm"
    else
        # Find installed php-fpm service
        local svc
        svc="$(systemctl list-units --type=service --state=running | grep -oE 'php[0-9.]+\-fpm' | head -1)"
    fi
    if [[ "${_DRY_RUN}" == "1" ]]; then
        dry_run_note "systemctl reload ${svc}"
        return 0
    fi
    systemctl reload "${svc}" || systemctl restart "${svc}"
    ok "PHP-FPM reloaded (${svc})"
}

wait_for_fpm_socket() {
    local socket="$1"
    local timeout="${2:-30}"
    local elapsed=0
    while [[ ! -S "${socket}" ]]; do
        sleep 1
        elapsed=$(( elapsed + 1 ))
        if (( elapsed >= timeout )); then
            err "PHP-FPM socket did not appear within ${timeout}s: ${socket}"
            return 1
        fi
    done
    ok "FPM socket ready: ${socket}"
}

# ---------------------------------------------------------------------------
# Disk space check
# ---------------------------------------------------------------------------
check_disk_space() {
    local path="$1"
    local required_gb="${2:-5}"
    local avail_kb
    avail_kb="$(df -k --output=avail "${path}" 2>/dev/null | tail -1)"
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < required_gb )); then
        err "Insufficient disk space at ${path}: ${avail_gb}GB available, ${required_gb}GB required."
        return 1
    fi
    verbose "Disk space OK at ${path}: ${avail_gb}GB available"
}

# ---------------------------------------------------------------------------
# Miscellaneous
# ---------------------------------------------------------------------------
confirm_destructive() {
    local prompt="$1"
    local confirm_word="${2:-yes}"
    if [[ "${_DRY_RUN}" == "1" ]]; then
        dry_run_note "Would prompt: ${prompt}"
        return 0
    fi
    echo -e "${C_BOLD_RED}${prompt}${C_RESET}"
    echo -n "Type '${confirm_word}' to confirm: "
    local input
    read -r input
    if [[ "${input}" != "${confirm_word}" ]]; then
        info "Aborted."
        exit 0
    fi
}

# Print a nice summary box
print_box() {
    local title="$1"; shift
    local width=60
    local line
    line="$(printf '═%.0s' $(seq 1 $width))"
    echo ""
    echo -e "${C_BOLD_CYAN}╔${line}╗${C_RESET}"
    echo -e "${C_BOLD_CYAN}║${C_RESET}  ${C_BOLD}${title}$(printf ' %.0s' $(seq 1 $(( width - ${#title} - 2 ))))${C_RESET}${C_BOLD_CYAN}║${C_RESET}"
    echo -e "${C_BOLD_CYAN}╠${line}╣${C_RESET}"
    while [[ $# -gt 0 ]]; do
        local line_content="$1"; shift
        local pad=$(( width - ${#line_content} - 2 ))
        echo -e "${C_BOLD_CYAN}║${C_RESET}  ${line_content}$(printf ' %.0s' $(seq 1 $pad))${C_BOLD_CYAN}║${C_RESET}"
    done
    echo -e "${C_BOLD_CYAN}╚${line}╝${C_RESET}"
}

# Human-readable byte size
human_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        echo "$(( bytes / 1073741824 ))GB"
    elif (( bytes >= 1048576 )); then
        echo "$(( bytes / 1048576 ))MB"
    elif (( bytes >= 1024 )); then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

# ---------------------------------------------------------------------------
# Timezone Management & Interactive Configuration
# ---------------------------------------------------------------------------
get_system_timezone() {
    local tz=""
    if command -v timedatectl &>/dev/null; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "${tz}" && -f "/etc/timezone" ]]; then
        tz="$(cat /etc/timezone 2>/dev/null | tr -d ' \n\r' || true)"
    fi
    if [[ -z "${tz}" && -L "/etc/localtime" ]]; then
        tz="$(readlink /etc/localtime 2>/dev/null | sed -E 's|.*/zoneinfo/||' || true)"
    fi
    echo "${tz:-UTC}"
}

configure_system_timezone() {
    local force_prompt="${1:-0}"
    local current_tz
    current_tz="$(get_system_timezone)"
    
    local target_tz="${current_tz}"
    
    if is_interactive && { [[ "${force_prompt}" == "1" ]] || [[ "${current_tz}" == "Etc/UTC" || "${current_tz}" == "UTC" || -z "${current_tz}" ]]; }; then
        info "System Timezone Configuration (Current: ${current_tz})"
        local tz_choice=""
        select_one tz_choice "Select system timezone:" \
            "Asia/Kolkata (IST, UTC+05:30) [Recommended]" \
            "UTC (Coordinated Universal Time)" \
            "Asia/Dubai (GST, UTC+04:00)" \
            "Asia/Singapore (SGT, UTC+08:00)" \
            "Asia/Riyadh (AST, UTC+03:00)" \
            "Europe/London (GMT/BST, UTC+00:00)" \
            "America/New_York (EST/EDT, UTC-05:00)" \
            "Keep Current (${current_tz})" \
            "Enter custom timezone string"
            
        case "${tz_choice}" in
            *"Asia/Kolkata"*) target_tz="Asia/Kolkata" ;;
            *"UTC ("*) target_tz="UTC" ;;
            *"Asia/Dubai"*) target_tz="Asia/Dubai" ;;
            *"Asia/Singapore"*) target_tz="Asia/Singapore" ;;
            *"Asia/Riyadh"*) target_tz="Asia/Riyadh" ;;
            *"Europe/London"*) target_tz="Europe/London" ;;
            *"America/New_York"*) target_tz="America/New_York" ;;
            *"Keep Current"*) target_tz="${current_tz}" ;;
            *"Enter custom"*)
                input_text target_tz "Enter IANA timezone (e.g. Europe/Berlin, Asia/Kolkata)" "${current_tz}" '^[A-Za-z0-9_\+\/-]+$' "Valid timezone format required"
                ;;
        esac
    fi
    
    # Apply timezone if changed or requested
    if [[ -n "${target_tz}" ]]; then
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone "${target_tz}" 2>/dev/null || true
        elif [[ -f "/usr/share/zoneinfo/${target_tz}" ]]; then
            ln -sf "/usr/share/zoneinfo/${target_tz}" /etc/localtime
            echo "${target_tz}" > /etc/timezone 2>/dev/null || true
        fi
        
        # Update PHP INI date.timezone across all PHP versions
        for php_ini in /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini; do
            if [[ -f "${php_ini}" ]]; then
                sed -i "s|^;\?date\.timezone\s*=.*|date.timezone = ${target_tz}|" "${php_ini}" 2>/dev/null || true
            fi
        done
        
        vault_gset "timezone" "${target_tz}" 2>/dev/null || true
        ok "System & PHP timezone configured: ${target_tz}"
    fi
    
    echo "${target_tz}"
}

# ---------------------------------------------------------------------------
# TLS / SSL Self-Signed Fallback
# ---------------------------------------------------------------------------
generate_self_signed_fallback() {
    local domain="$1"
    local nginx_conf="$2"
    
    local ssl_dir="/etc/ssl/moodlekit/${domain}"
    mkdir -p "${ssl_dir}"
    
    if [[ ! -f "${ssl_dir}/fullchain.pem" ]]; then
        info "Generating self-signed certificate for ${domain}..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${ssl_dir}/privkey.pem" \
            -out "${ssl_dir}/fullchain.pem" \
            -subj "/CN=${domain}" >/dev/null 2>&1
    fi
    
    # Patch Nginx config to point to self-signed certs instead of Let's Encrypt
    sed -i "s|/etc/letsencrypt/live/${domain}/fullchain.pem|${ssl_dir}/fullchain.pem|g" "${nginx_conf}"
    sed -i "s|/etc/letsencrypt/live/${domain}/privkey.pem|${ssl_dir}/privkey.pem|g" "${nginx_conf}"
    sed -i "s|ssl_trusted_certificate.*||g" "${nginx_conf}"
    
    warn "Self-signed fallback applied. Nginx is using port 443 with self-signed cert."
    warn "If using Cloudflare, ensure SSL/TLS encryption mode is set to 'Full' (not 'Strict')."
}
