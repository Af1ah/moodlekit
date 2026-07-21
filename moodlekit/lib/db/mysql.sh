#!/usr/bin/env bash
# =============================================================================
# lib/db/mysql.sh — MoodleKit MySQL 8.4 operations
# Same interface as mariadb.sh with MySQL-specific differences
# =============================================================================

[[ -n "${_MOODLEKIT_DB_MYSQL_LOADED:-}" ]] && return 0
_MOODLEKIT_DB_MYSQL_LOADED=1

DB_PORT_DEFAULT_MYSQL=3306

# ---------------------------------------------------------------------------
# Install MySQL 8.4 from official repo
# ---------------------------------------------------------------------------
db_mysql_install() {
    local mysql_ver="${1:-8.4}"

    if command -v mysql &>/dev/null && ! command -v mariadb &>/dev/null; then
        local existing_ver
        existing_ver="$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        ok "MySQL ${existing_ver} already installed — skipping"
        return 0
    fi

    info "Installing MySQL ${mysql_ver}..."

    # Add MySQL APT repo
    local tmp_deb
    tmp_deb="$(mktemp --suffix=.deb)"
    curl -fsSL "https://dev.mysql.com/get/mysql-apt-config_0.8.32-1_all.deb" -o "${tmp_deb}"
    DEBIAN_FRONTEND=noninteractive dpkg -i "${tmp_deb}" || true
    rm -f "${tmp_deb}"
    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
    systemctl enable --now mysql

    ok "MySQL ${mysql_ver} installed"
}

# ---------------------------------------------------------------------------
# Check if DB/user exists
# ---------------------------------------------------------------------------
db_mysql_db_exists() {
    local dbname="$1"
    mysql -u root -e "SHOW DATABASES LIKE '${dbname}';" 2>/dev/null | grep -q "${dbname}"
}

db_mysql_user_exists() {
    local db_user="$1"
    mysql -u root -e "SELECT User FROM mysql.user WHERE User='${db_user}';" 2>/dev/null | grep -q "${db_user}"
}

# ---------------------------------------------------------------------------
# Create database and user
# MySQL 8.x uses caching_sha2_password by default; change to native for compat
# ---------------------------------------------------------------------------
db_mysql_create() {
    local slug="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="${5:-localhost}"

    info "Creating MySQL database and user for '${slug}'..."

    if db_mysql_user_exists "${db_user}"; then
        warn "User '${db_user}' already exists — skipping"
    else
        mysql -u root << MYSQLSQL
CREATE USER '${db_user}'@'${db_host}'
    IDENTIFIED WITH mysql_native_password
    BY '${db_pass}';
MYSQLSQL
        ok "User '${db_user}' created"
    fi

    if db_mysql_db_exists "${db_name}"; then
        warn "Database '${db_name}' already exists — skipping"
    else
        mysql -u root << MYSQLSQL
CREATE DATABASE \`${db_name}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${db_host}';
FLUSH PRIVILEGES;
MYSQLSQL
        ok "Database '${db_name}' created"
    fi
}

# ---------------------------------------------------------------------------
# Drop database and user
# ---------------------------------------------------------------------------
db_mysql_drop() {
    local db_name="$1"
    local db_user="$2"
    local db_host="${3:-localhost}"

    if db_mysql_db_exists "${db_name}"; then
        mysql -u root -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>&1
        ok "Database '${db_name}' dropped"
    fi

    if db_mysql_user_exists "${db_user}"; then
        mysql -u root -e "DROP USER IF EXISTS '${db_user}'@'${db_host}';" 2>&1
        ok "User '${db_user}' dropped"
    fi
}

# ---------------------------------------------------------------------------
# Dump (same as MariaDB — mysqldump is compatible)
# ---------------------------------------------------------------------------
db_mysql_dump() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local output_file="$4"

    info "Dumping MySQL database '${db_name}'..."

    local tmp_mycnf
    tmp_mycnf="$(mktemp)"
    cat > "${tmp_mycnf}" << MYCNF
[client]
user=${db_user}
password=${db_pass}
host=localhost
MYCNF
    chmod 600 "${tmp_mycnf}"

    mysqldump \
        --defaults-extra-file="${tmp_mycnf}" \
        --single-transaction \
        --quick \
        --no-tablespaces \
        --column-statistics=0 \
        "${db_name}" \
        | gzip -c > "${output_file}"

    local dump_exit="${PIPESTATUS[0]}"
    rm -f "${tmp_mycnf}"

    if [[ "${dump_exit}" -ne 0 ]]; then
        err "mysqldump failed (exit code ${dump_exit})"
        return 1
    fi

    gzip -t "${output_file}" 2>/dev/null || { err "Gzip integrity check failed"; return 1; }

    local size
    size="$(du -sh "${output_file}" | cut -f1)"
    ok "Database dumped: ${output_file} (${size})"
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
db_mysql_restore() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local dump_file="$4"

    [[ -f "${dump_file}" ]] || { err "Dump file not found: ${dump_file}"; return 1; }
    info "Restoring MySQL database '${db_name}'..."

    local tmp_mycnf
    tmp_mycnf="$(mktemp)"
    cat > "${tmp_mycnf}" << MYCNF
[client]
user=${db_user}
password=${db_pass}
host=localhost
MYCNF
    chmod 600 "${tmp_mycnf}"

    zcat "${dump_file}" | mysql --defaults-extra-file="${tmp_mycnf}" "${db_name}"
    local restore_exit="${PIPESTATUS[1]}"
    rm -f "${tmp_mycnf}"

    [[ "${restore_exit}" -ne 0 ]] && { err "Restore failed (exit code ${restore_exit})"; return 1; }
    ok "Database '${db_name}' restored"
}
