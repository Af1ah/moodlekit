#!/usr/bin/env bash
# =============================================================================
# MoodleKit — Isolated Background Cron Daemon Entrypoint
# =============================================================================
# Isolates heavy background task loads (backups, grading, forum emails, etc.)
# from interactive web user requests.
# =============================================================================
set -eo pipefail

echo "==> [MoodleKit Cron] Initializing dedicated background worker daemon..."

MOODLE_DIR="${MOODLE_DIR:-/var/www/html}"
CRON_INTERVAL="${CRON_INTERVAL:-60}"
CRON_SCRIPT="${MOODLE_DIR}/admin/cli/cron.php"

# Trap signals for graceful shutdown
running=1
shutdown() {
    echo "==> [MoodleKit Cron] Graceful shutdown requested. Finishing current task..."
    running=0
}
trap shutdown SIGTERM SIGINT

# Optional wait for database
if [ -n "${DB_HOST:-}" ]; then
    DB_PORT="${DB_PORT:-3306}"
    echo "==> [MoodleKit Cron] Waiting for database (${DB_HOST}:${DB_PORT})..."
    while ! (echo > /dev/tcp/"${DB_HOST}"/"${DB_PORT}") 2>/dev/null; do
        sleep 2
    done
fi

echo "==> [MoodleKit Cron] Daemon running. Executing cron every ${CRON_INTERVAL} seconds."

while [ $running -eq 1 ]; do
    if [ -f "${CRON_SCRIPT}" ]; then
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[${timestamp}] Running Moodle cron: ${CRON_SCRIPT}"
        # Run as www-data user to preserve permissions
        gosu www-data php "${CRON_SCRIPT}" || {
            echo "[${timestamp}] Cron exited with status $?"
        }
    else
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] Cron script not found at ${CRON_SCRIPT}. Retrying in ${CRON_INTERVAL}s..."
    fi

    # Sleep in small increments to be responsive to termination signals
    slept=0
    while [ $slept -lt "$CRON_INTERVAL" ] && [ $running -eq 1 ]; do
        sleep 1
        slept=$((slept + 1))
    done
done

echo "==> [MoodleKit Cron] Cron daemon exited cleanly."
