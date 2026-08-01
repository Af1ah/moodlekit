#!/usr/bin/env bash
# =============================================================================
# lib/db/mariadb.sh — MoodleKit MariaDB 10.11+ operations
# =============================================================================

[[ -n "${_MOODLEKIT_DB_MARIA_LOADED:-}" ]] && return 0
_MOODLEKIT_DB_MARIA_LOADED=1

DB_PORT_DEFAULT_MARIA=3306

# ---------------------------------------------------------------------------
# Install MariaDB 10.11+ from official repo
# ---------------------------------------------------------------------------
db_maria_install() {
    local maria_ver="${1:-10.11}"

    if command -v mariadb &>/dev/null; then
        local existing_ver
        existing_ver="$(mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if dpkg --compare-versions "${existing_ver}" "lt" "${maria_ver}"; then
            warn "MariaDB ${existing_ver} is installed, but version ${maria_ver} or higher is required."
            warn "Please upgrade MariaDB manually or select a different database engine."
            exit 1
        fi
        ok "MariaDB ${existing_ver} already installed (>= ${maria_ver}) — skipping"
        return 0
    fi

    info "Installing MariaDB ${maria_ver}..."

    # Add MariaDB repo
    if [[ ! -f /etc/apt/sources.list.d/mariadb.list ]]; then
        curl -fsSL "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" \
            | bash -s -- --mariadb-server-version="${maria_ver}" --skip-maxscale
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mariadb-server mariadb-client

    systemctl enable --now mariadb

    # Secure installation (non-interactive)
    mysql -u root << 'SECURESQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SECURESQL

    ok "MariaDB ${maria_ver} installed and secured"
}

# ---------------------------------------------------------------------------
# Check if DB/user exists
# ---------------------------------------------------------------------------
db_maria_db_exists() {
    local dbname="$1"
    mysql -u root -e "SHOW DATABASES LIKE '${dbname}';" 2>/dev/null | grep -q "${dbname}"
}

db_maria_user_exists() {
    local db_user="$1"
    mysql -u root -e "SELECT User FROM mysql.user WHERE User='${db_user}';" 2>/dev/null | grep -q "${db_user}"
}

# ---------------------------------------------------------------------------
# Create database and user
# ---------------------------------------------------------------------------
db_maria_create() {
    local slug="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="${5:-localhost}"

    info "Creating MariaDB database and user for '${slug}'..."

    if db_maria_user_exists "${db_user}"; then
        warn "User '${db_user}' already exists — skipping user creation"
    else
        mysql -u root << MARIASQL
CREATE USER '${db_user}'@'${db_host}' IDENTIFIED BY '${db_pass}';
MARIASQL
        ok "User '${db_user}' created"
    fi

    if db_maria_db_exists "${db_name}"; then
        warn "Database '${db_name}' already exists — skipping DB creation"
    else
        mysql -u root << MARIASQL
CREATE DATABASE \`${db_name}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${db_host}';
FLUSH PRIVILEGES;
MARIASQL
        ok "Database '${db_name}' created (utf8mb4)"
    fi
}

# ---------------------------------------------------------------------------
# Drop database and user
# ---------------------------------------------------------------------------
db_maria_drop() {
    local db_name="$1"
    local db_user="$2"
    local db_host="${3:-localhost}"

    if db_maria_db_exists "${db_name}"; then
        mysql -u root -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>&1
        ok "Database '${db_name}' dropped"
    else
        warn "Database '${db_name}' not found — skipping"
    fi

    if db_maria_user_exists "${db_user}"; then
        mysql -u root -e "DROP USER IF EXISTS '${db_user}'@'${db_host}';" 2>&1
        ok "User '${db_user}' dropped"
    fi
}

# ---------------------------------------------------------------------------
# Dump database to .sql.gz
# ---------------------------------------------------------------------------
db_maria_dump() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local output_file="$4"

    info "Dumping MariaDB database '${db_name}'..."

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
        --routines \
        --triggers \
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
# Restore database from .sql.gz
# ---------------------------------------------------------------------------
db_maria_restore() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local dump_file="$4"

    [[ -f "${dump_file}" ]] || { err "Dump file not found: ${dump_file}"; return 1; }
    info "Restoring MariaDB database '${db_name}'..."

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

    if [[ "${restore_exit}" -ne 0 ]]; then
        err "Database restore failed (exit code ${restore_exit})"
        return 1
    fi

    ok "Database '${db_name}' restored"
}

# ---------------------------------------------------------------------------
# Update user password
# ---------------------------------------------------------------------------
db_maria_update_password() {
    local db_user="$1"
    local new_pass="$2"
    local db_host="${3:-localhost}"
    mysql -u root -e \
        "ALTER USER '${db_user}'@'${db_host}' IDENTIFIED BY '${new_pass}'; FLUSH PRIVILEGES;" 2>&1
    ok "Password updated for user '${db_user}'"
}
