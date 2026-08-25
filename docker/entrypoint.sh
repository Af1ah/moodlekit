#!/usr/bin/env bash
# =============================================================================
# MoodleKit — Application Container Entrypoint
# =============================================================================
set -eo pipefail

echo "==> [MoodleKit] Initializing Moodle container runtime..."

# Adjust PUID / PGID dynamically if specified
PUID="${PUID:-33}"
PGID="${PGID:-33}"

if [ "$PGID" != "33" ]; then
    groupmod -o -g "$PGID" www-data 2>/dev/null || true
fi
if [ "$PUID" != "33" ]; then
    usermod -o -u "$PUID" -g "$PGID" www-data 2>/dev/null || true
fi

# Configure Git safe directory globally
git config --system --add safe.directory '*' 2>/dev/null || true

# Configure internal loopback DNS for Moodle self-health checks
if [ -n "${DOMAIN:-}" ]; then
    CADDY_IP=$(getent hosts caddy | awk '{ print $1 }' | head -n 1 || true)
    if [ -n "${CADDY_IP}" ]; then
        if ! grep -q "${DOMAIN}" /etc/hosts 2>/dev/null; then
            echo "${CADDY_IP} ${DOMAIN}" >> /etc/hosts 2>/dev/null || true
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Dataroot Security & File Permissions
# Standard: Directories are 2775 (setgid, traversable), Files are 0664 (NON-EXECUTABLE)
# Dataroot is located strictly outside webroot at /var/moodledata
# -----------------------------------------------------------------------------
MOODLEDATA_DIR="${MOODLEDATA_DIR:-/var/moodledata}"
mkdir -p "${MOODLEDATA_DIR}"
chown -R www-data:www-data "${MOODLEDATA_DIR}"
# Capital 'X' ensures execute/traverse is set on DIRECTORIES ONLY, not files:
chmod -R u+rwX,g+rwX,o-wX "${MOODLEDATA_DIR}"
find "${MOODLEDATA_DIR}" -type d -exec chmod 2775 {} + 2>/dev/null || true
find "${MOODLEDATA_DIR}" -type f -exec chmod 0664 {} + 2>/dev/null || true

# Ensure log, run, and composer home directories
mkdir -p /var/log/php /run/php /var/www/.composer /tmp/composer
chown -R www-data:www-data /var/log/php /run/php /var/www/.composer /tmp/composer
chmod 700 /var/www/.composer /tmp/composer

# -----------------------------------------------------------------------------
# Codebase & Plugin Directory Permissions
# Core files are read-only; plugin subtrees have controlled write access for Web Installer
# -----------------------------------------------------------------------------
PLUGIN_DIRS=(
    "admin/tool"
    "auth"
    "availability/condition"
    "blocks"
    "cache/stores"
    "course/format"
    "enrol"
    "filter"
    "grade/export"
    "grade/import"
    "grade/report"
    "local"
    "message/output"
    "mod"
    "plagiarism"
    "question/behaviour"
    "question/format"
    "question/type"
    "report"
    "repository"
    "theme"
    "vendor"
)

MOODLE_DIR="${MOODLE_DIR:-/var/www/html}"
if [ -d "${MOODLE_DIR}" ]; then
    mkdir -p "${MOODLE_DIR}/vendor"
    for pdir in "${PLUGIN_DIRS[@]}"; do
        for base in "${MOODLE_DIR}" "${MOODLE_DIR}/public"; do
            target="${base}/${pdir}"
            if [ -d "${target}" ]; then
                chown -R www-data:www-data "${target}" 2>/dev/null || true
                chmod -R u+rwX,g+rwX,o-wX "${target}" 2>/dev/null || true
                find "${target}" -type d -exec chmod 2775 {} + 2>/dev/null || true
                find "${target}" -type f -exec chmod 0664 {} + 2>/dev/null || true
            fi
        done
    done

    # Ensure config.php (if it exists) is protected and non-writable by web process
    if [ -f "${MOODLE_DIR}/config.php" ]; then
        chown www-data:www-data "${MOODLE_DIR}/config.php" 2>/dev/null || true
        chmod 644 "${MOODLE_DIR}/config.php" 2>/dev/null || true
    fi

    # Authoritative Classmap Composer Autoloader
    if [ -f "${MOODLE_DIR}/composer.json" ] && [ ! -f "${MOODLE_DIR}/vendor/autoload.php" ]; then
        echo "==> [MoodleKit] Compiling authoritative classmap autoloader (composer install --no-dev --classmap-authoritative)..."
        gosu www-data composer install --no-dev --classmap-authoritative --no-interaction --working-dir="${MOODLE_DIR}" || true
    fi
fi

# Optional database readiness wait
if [ -n "${DB_HOST:-}" ]; then
    DB_PORT="${DB_PORT:-3306}"
    DB_TYPE="${DB_TYPE:-mariadb}"
    MAX_TRIES=60
    COUNT=0
    echo "==> [MoodleKit] Checking database connection (${DB_HOST}:${DB_PORT})..."
    while ! nc -z -v -w 1 "${DB_HOST}" "${DB_PORT}" 2>/dev/null; do
        if (echo > /dev/tcp/"${DB_HOST}"/"${DB_PORT}") 2>/dev/null; then
            break
        fi
        COUNT=$((COUNT + 1))
        if [ $COUNT -ge $MAX_TRIES ]; then
            echo "==> [MoodleKit] ERROR: Database at ${DB_HOST}:${DB_PORT} not reachable after ${MAX_TRIES} attempts."
            break
        fi
        echo "==> [MoodleKit] Waiting for database (${COUNT}/${MAX_TRIES})..."
        sleep 2
    done
    echo "==> [MoodleKit] Database is accessible!"
fi

echo "==> [MoodleKit] Permissions and environment configured. Starting: $@"
exec "$@"
