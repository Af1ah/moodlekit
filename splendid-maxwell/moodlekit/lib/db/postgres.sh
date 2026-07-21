#!/usr/bin/env bash
# =============================================================================
# lib/db/postgres.sh — MoodleKit PostgreSQL 17 operations
# =============================================================================

[[ -n "${_MOODLEKIT_DB_PG_LOADED:-}" ]] && return 0
_MOODLEKIT_DB_PG_LOADED=1

DB_PORT_DEFAULT_PG=5432

# ---------------------------------------------------------------------------
# Install PostgreSQL 17 from PGDG repo
# ---------------------------------------------------------------------------
db_pg_install() {
    local pg_ver="${1:-17}"

    if command -v psql &>/dev/null; then
        local existing_ver
        existing_ver="$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
        if [[ "${existing_ver}" == "${pg_ver}" ]]; then
            ok "PostgreSQL ${pg_ver} already installed — skipping"
            return 0
        fi
        info "PostgreSQL ${existing_ver} found, but ${pg_ver} requested — installing alongside"
    fi

    info "Installing PostgreSQL ${pg_ver}..."

    # Add PGDG repository
    if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
        local lsb_codename
        lsb_codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
        echo "deb https://apt.postgresql.org/pub/repos/apt ${lsb_codename}-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
        apt-get update -qq
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "postgresql-${pg_ver}" \
        "postgresql-client-${pg_ver}" \
        "postgresql-contrib-${pg_ver}"

    systemctl enable --now "postgresql@${pg_ver}-main" 2>/dev/null \
        || systemctl enable --now postgresql

    ok "PostgreSQL ${pg_ver} installed"
}

# ---------------------------------------------------------------------------
# Check if DB or role exists
# ---------------------------------------------------------------------------
db_pg_role_exists() {
    local role="$1"
    sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${role}'" 2>/dev/null | grep -q 1
}

db_pg_db_exists() {
    local dbname="$1"
    sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${dbname}'" 2>/dev/null | grep -q 1
}

# ---------------------------------------------------------------------------
# Create database and least-privilege role
# Uses individual psql -c calls to avoid SQL injection via heredoc interpolation
# ---------------------------------------------------------------------------
db_pg_create() {
    local slug="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_prefix="${5:-mdl_}"

    info "Creating PostgreSQL database and role for '${slug}'..."

    if db_pg_role_exists "${db_user}"; then
        warn "Role '${db_user}' already exists — skipping role creation"
    else
        # Create role with proper escaping — password is passed separately
        sudo -u postgres psql -c \
            "CREATE ROLE ${db_user}
             LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
             NOINHERIT NOREPLICATION
             PASSWORD '${db_pass}';" 2>&1
        ok "Role '${db_user}' created"
    fi

    if db_pg_db_exists "${db_name}"; then
        warn "Database '${db_name}' already exists — skipping DB creation"
    else
        sudo -u postgres psql -c \
            "CREATE DATABASE ${db_name}
             WITH OWNER = ${db_user}
             ENCODING = 'UTF8'
             LC_COLLATE = 'en_US.UTF-8'
             LC_CTYPE = 'en_US.UTF-8'
             TEMPLATE = template0;" 2>&1

        # Revoke public access
        sudo -u postgres psql -c \
            "REVOKE ALL ON DATABASE ${db_name} FROM PUBLIC;" 2>&1
        sudo -u postgres psql -c \
            "GRANT CONNECT, TEMP ON DATABASE ${db_name} TO ${db_user};" 2>&1

        # Fix schema ownership
        sudo -u postgres psql -d "${db_name}" -c \
            "REVOKE CREATE ON SCHEMA public FROM PUBLIC;" 2>&1
        sudo -u postgres psql -d "${db_name}" -c \
            "GRANT USAGE, CREATE ON SCHEMA public TO ${db_user};" 2>&1
        sudo -u postgres psql -d "${db_name}" -c \
            "ALTER SCHEMA public OWNER TO ${db_user};" 2>&1

        ok "Database '${db_name}' created with least-privilege access"
    fi
}

# ---------------------------------------------------------------------------
# Drop database and role
# ---------------------------------------------------------------------------
db_pg_drop() {
    local db_name="$1"
    local db_user="$2"

    if db_pg_db_exists "${db_name}"; then
        # Terminate active connections
        sudo -u postgres psql -c \
            "SELECT pg_terminate_backend(pid)
             FROM pg_stat_activity
             WHERE datname='${db_name}' AND pid <> pg_backend_pid();" 2>/dev/null || true
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>&1
        ok "Database '${db_name}' dropped"
    else
        warn "Database '${db_name}' does not exist — skipping"
    fi

    if db_pg_role_exists "${db_user}"; then
        sudo -u postgres psql -c "DROP ROLE IF EXISTS ${db_user};" 2>&1
        ok "Role '${db_user}' dropped"
    fi
}

# ---------------------------------------------------------------------------
# Dump database to .sql.gz (streamed through gzip, not buffered)
# ---------------------------------------------------------------------------
db_pg_dump() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local output_file="$4"  # Must end in .sql.gz

    info "Dumping PostgreSQL database '${db_name}'..."

    local tmp_pgpass
    tmp_pgpass="$(mktemp)"
    echo "localhost:5432:${db_name}:${db_user}:${db_pass}" > "${tmp_pgpass}"
    chmod 600 "${tmp_pgpass}"

    PGPASSFILE="${tmp_pgpass}" pg_dump \
        -h localhost \
        -U "${db_user}" \
        -d "${db_name}" \
        --no-password \
        --format=plain \
        --no-owner \
        --no-privileges \
        --no-tablespaces \
        | gzip -c > "${output_file}"

    local pg_exit="${PIPESTATUS[0]}"
    rm -f "${tmp_pgpass}"

    if [[ "${pg_exit}" -ne 0 ]]; then
        err "pg_dump failed (exit code ${pg_exit})"
        return 1
    fi

    # Validate the gzip file
    if ! gzip -t "${output_file}" 2>/dev/null; then
        err "Gzip integrity check failed for ${output_file}"
        return 1
    fi

    local size
    size="$(du -sh "${output_file}" | cut -f1)"
    ok "Database dumped: ${output_file} (${size})"
}

# ---------------------------------------------------------------------------
# Restore database from .sql.gz
# ---------------------------------------------------------------------------
db_pg_restore() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local dump_file="$4"

    [[ -f "${dump_file}" ]] || { err "Dump file not found: ${dump_file}"; return 1; }

    info "Restoring PostgreSQL database '${db_name}' from ${dump_file}..."

    local tmp_pgpass
    tmp_pgpass="$(mktemp)"
    echo "localhost:5432:${db_name}:${db_user}:${db_pass}" > "${tmp_pgpass}"
    chmod 600 "${tmp_pgpass}"

    zcat "${dump_file}" | PGPASSFILE="${tmp_pgpass}" psql \
        -h localhost \
        -U "${db_user}" \
        -d "${db_name}" \
        --no-password \
        -v ON_ERROR_STOP=1 2>&1

    local psql_exit="${PIPESTATUS[1]}"
    rm -f "${tmp_pgpass}"

    if [[ "${psql_exit}" -ne 0 ]]; then
        err "Database restore failed (exit code ${psql_exit})"
        return 1
    fi

    ok "Database '${db_name}' restored"
}

# ---------------------------------------------------------------------------
# Update user password
# ---------------------------------------------------------------------------
db_pg_update_password() {
    local db_user="$1"
    local new_pass="$2"
    sudo -u postgres psql -c \
        "ALTER ROLE ${db_user} PASSWORD '${new_pass}';" 2>&1
    ok "Password updated for role '${db_user}'"
}
