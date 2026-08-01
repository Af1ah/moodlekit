#!/usr/bin/env bash
# =============================================================================
# lib/detect.sh — MoodleKit system detection & pre-existing tool checks
# =============================================================================
# Detects Ubuntu version, hardware specs, installed tools (with version flags),
# and Moodle installation structure.
# =============================================================================

[[ -n "${_MOODLEKIT_DETECT_LOADED:-}" ]] && return 0
_MOODLEKIT_DETECT_LOADED=1

# ---------------------------------------------------------------------------
# OS Detection
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "Cannot detect OS: /etc/os-release not found."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"

    case "${OS_VERSION}" in
        22.04) OS_SUPPORTED=1 ;;
        24.04) OS_SUPPORTED=1 ;;
        *)
            warn "Ubuntu ${OS_VERSION} is not officially tested. Supported: 22.04, 24.04."
            OS_SUPPORTED=0
            ;;
    esac

    verbose "OS: ${OS_NAME} ${OS_VERSION} (${OS_CODENAME})"
}

# ---------------------------------------------------------------------------
# Hardware Detection
# ---------------------------------------------------------------------------
detect_hardware() {
    # Total RAM in MB
    RAM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    RAM_TOTAL_GB=$(( RAM_TOTAL_MB / 1024 ))
    # Usable RAM for services (subtract 1GB OS reserve)
    RAM_USABLE_GB=$(( RAM_TOTAL_GB > 2 ? RAM_TOTAL_GB - 1 : 1 ))

    # CPU cores
    CPU_CORES=$(nproc --all 2>/dev/null || echo 1)

    # Primary disk type (SSD vs HDD)
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's|/dev/||')
    local rotational_file="/sys/block/${root_dev}/queue/rotational"
    if [[ -f "${rotational_file}" ]]; then
        local rot
        rot=$(cat "${rotational_file}" 2>/dev/null || echo "1")
        DISK_TYPE=$([[ "${rot}" == "0" ]] && echo "ssd" || echo "hdd")
    else
        DISK_TYPE="unknown"
    fi

    verbose "Hardware: ${RAM_TOTAL_GB}GB RAM, ${CPU_CORES} CPU cores, disk=${DISK_TYPE}"
}

# ---------------------------------------------------------------------------
# Pre-existing tool detection
# Checks every tool with version flags; sets INSTALLED_* variables
# ---------------------------------------------------------------------------
detect_installed() {
    info "Scanning for pre-installed software..."
    INSTALLED_TOOLS=()

    # ── PHP ──
    PHP_INSTALLED=""
    PHP_INSTALLED_VERSION=""
    # Check each version we support
    for ver in 8.4 8.3 8.1; do
        if command -v "php${ver}" &>/dev/null 2>&1; then
            PHP_INSTALLED="${ver}"
            PHP_INSTALLED_VERSION="$(php${ver} -v 2>/dev/null | head -1 | awk '{print $2}')"
            INSTALLED_TOOLS+=("PHP ${PHP_INSTALLED_VERSION}")
            break
        fi
    done
    # Fallback: generic php command
    if [[ -z "${PHP_INSTALLED}" ]] && command -v php &>/dev/null 2>&1; then
        PHP_INSTALLED_VERSION="$(php -v 2>/dev/null | head -1 | awk '{print $2}')"
        PHP_INSTALLED="${PHP_INSTALLED_VERSION%%.*}"
        INSTALLED_TOOLS+=("PHP ${PHP_INSTALLED_VERSION}")
    fi

    # ── PostgreSQL ──
    POSTGRES_INSTALLED=""
    POSTGRES_INSTALLED_VERSION=""
    if command -v psql &>/dev/null 2>&1; then
        POSTGRES_INSTALLED_VERSION="$(psql --version 2>/dev/null | awk '{print $3}')"
        POSTGRES_INSTALLED="${POSTGRES_INSTALLED_VERSION%%.*}"
        INSTALLED_TOOLS+=("PostgreSQL ${POSTGRES_INSTALLED_VERSION}")
    fi

    # ── MariaDB ──
    MARIADB_INSTALLED=""
    MARIADB_INSTALLED_VERSION=""
    if command -v mariadb &>/dev/null 2>&1; then
        MARIADB_INSTALLED_VERSION="$(mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        MARIADB_INSTALLED="${MARIADB_INSTALLED_VERSION%%.*}"
        INSTALLED_TOOLS+=("MariaDB ${MARIADB_INSTALLED_VERSION}")
    fi

    # ── MySQL ──
    MYSQL_INSTALLED=""
    MYSQL_INSTALLED_VERSION=""
    if command -v mysql &>/dev/null 2>&1 && [[ -z "${MARIADB_INSTALLED}" ]]; then
        MYSQL_INSTALLED_VERSION="$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        MYSQL_INSTALLED="${MYSQL_INSTALLED_VERSION%%.*}"
        INSTALLED_TOOLS+=("MySQL ${MYSQL_INSTALLED_VERSION}")
    fi

    # ── Nginx ──
    NGINX_INSTALLED=""
    NGINX_INSTALLED_VERSION=""
    if command -v nginx &>/dev/null 2>&1; then
        NGINX_INSTALLED_VERSION="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        NGINX_INSTALLED="yes"
        INSTALLED_TOOLS+=("Nginx ${NGINX_INSTALLED_VERSION}")
    fi

    # ── Apache ──
    APACHE_INSTALLED=""
    if command -v apache2 &>/dev/null 2>&1; then
        APACHE_INSTALLED_VERSION="$(apache2 -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        APACHE_INSTALLED="yes"
        INSTALLED_TOOLS+=("Apache ${APACHE_INSTALLED_VERSION}")
    fi

    # ── Redis ──
    REDIS_INSTALLED=""
    REDIS_INSTALLED_VERSION=""
    if command -v redis-server &>/dev/null 2>&1; then
        REDIS_INSTALLED_VERSION="$(redis-server --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        REDIS_INSTALLED="yes"
        INSTALLED_TOOLS+=("Redis ${REDIS_INSTALLED_VERSION}")
    fi

    # ── Memcached ──
    MEMCACHED_INSTALLED=""
    if command -v memcached &>/dev/null 2>&1; then
        MEMCACHED_INSTALLED_VERSION="$(memcached --version 2>/dev/null | awk '{print $2}')"
        MEMCACHED_INSTALLED="yes"
        INSTALLED_TOOLS+=("Memcached ${MEMCACHED_INSTALLED_VERSION}")
    fi

    # ── Certbot ──
    CERTBOT_INSTALLED=""
    CERTBOT_INSTALLED_VERSION=""
    if command -v certbot &>/dev/null 2>&1; then
        CERTBOT_INSTALLED_VERSION="$(certbot --version 2>&1 | awk '{print $2}')"
        CERTBOT_INSTALLED="yes"
        INSTALLED_TOOLS+=("Certbot ${CERTBOT_INSTALLED_VERSION}")
    fi

    # ── Composer ──
    COMPOSER_INSTALLED=""
    if command -v composer &>/dev/null 2>&1; then
        COMPOSER_INSTALLED_VERSION="$(composer --version 2>/dev/null | awk '{print $3}')"
        COMPOSER_INSTALLED="yes"
        INSTALLED_TOOLS+=("Composer ${COMPOSER_INSTALLED_VERSION}")
    fi

    # ── Git ──
    GIT_INSTALLED=""
    if command -v git &>/dev/null 2>&1; then
        GIT_INSTALLED_VERSION="$(git --version 2>/dev/null | awk '{print $3}')"
        GIT_INSTALLED="yes"
        INSTALLED_TOOLS+=("Git ${GIT_INSTALLED_VERSION}")
    fi

    # ── rclone ──
    RCLONE_INSTALLED=""
    if command -v rclone &>/dev/null 2>&1; then
        RCLONE_INSTALLED_VERSION="$(rclone --version 2>/dev/null | head -1 | awk '{print $2}')"
        RCLONE_INSTALLED="yes"
        INSTALLED_TOOLS+=("rclone ${RCLONE_INSTALLED_VERSION}")
    fi

    # ── UFW ──
    UFW_INSTALLED=""
    if command -v ufw &>/dev/null 2>&1; then
        UFW_INSTALLED="yes"
        INSTALLED_TOOLS+=("UFW (firewall)")
    fi

    # ── fail2ban ──
    FAIL2BAN_INSTALLED=""
    if command -v fail2ban-server &>/dev/null 2>&1; then
        FAIL2BAN_INSTALLED="yes"
        INSTALLED_TOOLS+=("fail2ban")
    fi

    # Report
    if [[ ${#INSTALLED_TOOLS[@]} -gt 0 ]]; then
        info "Already installed on this server:"
        for t in "${INSTALLED_TOOLS[@]}"; do
            ok "  ✓ ${t}"
        done
    else
        info "No relevant tools detected — fresh server."
    fi
}

# ---------------------------------------------------------------------------
# PHP extension check
# ---------------------------------------------------------------------------
check_php_extensions() {
    local php_bin="$1"
    local required_exts=("curl" "gd" "intl" "mbstring" "xml" "zip" "soap"
                         "opcache" "pgsql" "pdo_pgsql" "mysqli" "pdo_mysql"
                         "redis" "sodium" "bcmath" "exif")
    local missing=()

    for ext in "${required_exts[@]}"; do
        if ! "${php_bin}" -m 2>/dev/null | grep -qi "^${ext}$"; then
            missing+=("${ext}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing PHP extensions: ${missing[*]}"
        return 1
    fi
    ok "All required PHP extensions present"
    return 0
}

# ---------------------------------------------------------------------------
# Validate PHP version is compatible with requested Moodle version
# ---------------------------------------------------------------------------
validate_php_moodle_compat() {
    local php_ver="$1"    # e.g. "8.3"
    local moodle_ver="$2" # e.g. "5.2" or "4.5"

    local major="${moodle_ver%%.*}"
    case "${major}" in
        4)
            case "${php_ver}" in
                8.1|8.2|8.3) return 0 ;;
                *)
                    err "Moodle 4.x requires PHP 8.1, 8.2, or 8.3. Got: ${php_ver}"
                    return 1
                    ;;
            esac
            ;;
        5)
            case "${php_ver}" in
                8.3|8.4) return 0 ;;
                *)
                    err "Moodle 5.x requires PHP 8.3 or 8.4. Got: ${php_ver}"
                    return 1
                    ;;
            esac
            ;;
        *)
            err "Unknown Moodle major version: ${moodle_ver}"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Validate slug conflict
# ---------------------------------------------------------------------------
check_slug_conflicts() {
    local slug="$1"
    local moodle_web_dir="/var/www/moodle/${slug}"
    local moodle_data_dir="/var/moodledata/${slug}"
    local nginx_conf="/etc/nginx/sites-available/moodle-${slug}"
    local site_conf="${MOODLEKIT_SITES_DIR}/${slug}.conf"

    local conflicts=()
    [[ -d "${moodle_web_dir}" ]]   && conflicts+=("Moodle directory: ${moodle_web_dir}")
    [[ -d "${moodle_data_dir}" ]]  && conflicts+=("Data directory: ${moodle_data_dir}")
    [[ -f "${nginx_conf}" ]]       && conflicts+=("Nginx config: ${nginx_conf}")
    [[ -f "${site_conf}" ]]        && conflicts+=("Site state: ${site_conf}")

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        err "Slug '${slug}' already has resources on this server:"
        for c in "${conflicts[@]}"; do
            err "  - ${c}"
        done
        echo ""
        
        local conflict_action=""
        select_one conflict_action "How would you like to handle these existing resources?" \
            "Clean up automatically (Delete them and start fresh)" \
            "Keep them and resume provisioning (Skip existing steps)" \
            "Abort"

        case "${conflict_action}" in
            *Clean*)
                info "Running automated cleanup for '${slug}'..."
                if ! moodlekit site remove "${slug}" "--force"; then
                    echo ""
                    err "Automated cleanup was aborted or failed. Please run 'moodlekit site remove ${slug}' manually."
                    return 1
                fi
                echo ""
                info "Cleanup complete. Resuming site creation..."
                return 0
                ;;
            *Keep*)
                info "Resuming provisioning using existing resources..."
                return 0
                ;;
            *Abort*)
                err "Use 'moodlekit site remove ${slug}' to clean up manually, or choose a different slug."
                return 1
                ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Check minimum disk space
# ---------------------------------------------------------------------------
check_system_requirements() {
    check_disk_space "/var" 10    # At least 10GB free for /var
    check_disk_space "/etc" 1     # At least 1GB free for /etc

    if (( RAM_TOTAL_GB < 2 )); then
        warn "Only ${RAM_TOTAL_GB}GB RAM detected. Minimum recommended is 2GB."
        warn "Performance may be severely degraded."
    fi
}

# ---------------------------------------------------------------------------
# DNS check — verify domain resolves to this server
# ---------------------------------------------------------------------------
dns_check() {
    local domain="$1"
    local skip="${2:-0}"

    [[ "${skip}" == "1" ]] && { info "DNS check skipped (--skip-dns)"; return 0; }

    # Auto-skip for local development domains
    if [[ "${domain}" == *.local || "${domain}" == *.test || "${domain}" == "localhost" || "${domain}" != *.* ]]; then
        info "Local/development domain detected (${domain}) — skipping DNS validation."
        return 0
    fi

    local server_ip
    server_ip="$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 10 https://ifconfig.me 2>/dev/null \
        || echo "")"

    if [[ -z "${server_ip}" ]]; then
        warn "Could not determine public IP — skipping DNS check."
        return 0
    fi

    local resolved_ip
    resolved_ip="$(dig +short "${domain}" A 2>/dev/null | head -1 || echo "")"

    if [[ -z "${resolved_ip}" ]]; then
        warn "Domain '${domain}' does not resolve via public DNS."
        warn "Expected an A record pointing to: ${server_ip}"
        if ! confirm "Proceed anyway? (e.g. using local /etc/hosts file)" "n"; then
            err "DNS check failed. Aborting."
            exit 1
        fi
        return 0
    fi

    if [[ "${resolved_ip}" != "${server_ip}" ]]; then
        warn "Domain '${domain}' resolves to ${resolved_ip}, but server IP is ${server_ip}."
        if ! confirm "Proceed anyway? (e.g. behind Cloudflare / Proxy / NAT)" "n"; then
            err "DNS check failed. Aborting."
            exit 1
        fi
        return 0
    fi

    ok "DNS check passed: ${domain} → ${resolved_ip}"
}
