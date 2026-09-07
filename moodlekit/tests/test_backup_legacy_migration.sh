#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d -t moodlekit_backup_migration_XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export MOODLEKIT_LEGACY_BACKUP_DIR="${TEST_ROOT}/opt/moodle_backup"
export MOODLEKIT_SYSTEMD_DIR="${TEST_ROOT}/etc/systemd/system"
export MOODLEKIT_BACKUP_DIR="${TEST_ROOT}/var/backups/moodlekit"
export _LOG_FILE="${TEST_ROOT}/migration.log"

mkdir -p "${MOODLEKIT_LEGACY_BACKUP_DIR}" "${MOODLEKIT_SYSTEMD_DIR}"
printf '%s\n' '# legacy config' > "${MOODLEKIT_LEGACY_BACKUP_DIR}/config.json"
printf '%s\n' '[Service]' > "${MOODLEKIT_SYSTEMD_DIR}/moodle-backup.service"
printf '%s\n' '[Timer]' > "${MOODLEKIT_SYSTEMD_DIR}/moodle-backup.timer"

warn() { :; }
ok() { :; }
systemctl() { printf '%s\n' "$*" >> "${TEST_ROOT}/systemctl.log"; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/commands/backup.sh"

_retire_legacy_cloud_backup

archive_dir="$(find "${MOODLEKIT_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'legacy-cloud-backup-*' -print -quit)"
[[ -n "${archive_dir}" ]]
[[ -f "${archive_dir}/moodle_backup/config.json" ]]
[[ -f "${archive_dir}/moodle-backup.service" ]]
[[ -f "${archive_dir}/moodle-backup.timer" ]]
[[ ! -e "${MOODLEKIT_LEGACY_BACKUP_DIR}" ]]
[[ ! -e "${MOODLEKIT_SYSTEMD_DIR}/moodle-backup.service" ]]
[[ ! -e "${MOODLEKIT_SYSTEMD_DIR}/moodle-backup.timer" ]]
grep -Fqx 'disable --now moodle-backup.timer' "${TEST_ROOT}/systemctl.log"
grep -Fqx 'stop moodle-backup.service' "${TEST_ROOT}/systemctl.log"
grep -Fqx 'daemon-reload' "${TEST_ROOT}/systemctl.log"

# A repeated deployment must not create another archive.
_retire_legacy_cloud_backup
[[ "$(find "${MOODLEKIT_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]]

echo "Legacy cloud-backup migration test passed"
