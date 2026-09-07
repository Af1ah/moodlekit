#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t moodlekit_uninstall_XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

# shellcheck source=../lib/interactive.sh
source "${REPO_ROOT}/lib/interactive.sh"
# shellcheck source=../commands/uninstall.sh
source "${REPO_ROOT}/commands/uninstall.sh"

require_root() { :; }
section() { :; }
info() { :; }
ok() { :; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; }
confirm() { return 0; }
confirm_destructive() { return 0; }
systemctl() { printf '%s\n' "$*" >> "${MOODLEKIT_UNINSTALL_TEST_ROOT}/systemctl.log"; }

prepare_fixture() {
    local root="$1"
    export MOODLEKIT_UNINSTALL_TEST_ROOT="${root}"
    export MOODLEKIT_INSTALL_DIR="${root}/opt/moodlekit"
    export MOODLEKIT_BIN_LINK="${root}/usr/local/bin/moodlekit"
    export MOODLEKIT_SYSTEMD_DIR="${root}/etc/systemd/system"
    export MOODLEKIT_STATE_DIR="${root}/etc/moodlekit"
    export MOODLEKIT_OPT_DIR="${root}/opt/moodlekit-data"
    export MOODLEKIT_BACKUP_DIR="${root}/var/backups/moodlekit"
    mkdir -p "${MOODLEKIT_INSTALL_DIR}" "$(dirname "${MOODLEKIT_BIN_LINK}")" \
        "${MOODLEKIT_SYSTEMD_DIR}" "${MOODLEKIT_STATE_DIR}" "${MOODLEKIT_OPT_DIR}" \
        "${MOODLEKIT_BACKUP_DIR}/site-a" "${root}/var/www/moodle/site-a" \
        "${root}/var/moodledata/site-a"
    printf tool > "${MOODLEKIT_INSTALL_DIR}/moodlekit"
    ln -s "${MOODLEKIT_INSTALL_DIR}/moodlekit" "${MOODLEKIT_BIN_LINK}"
    printf vault > "${MOODLEKIT_STATE_DIR}/vault.bin"
    printf cloud > "${MOODLEKIT_OPT_DIR}/config.json"
    printf backup > "${MOODLEKIT_BACKUP_DIR}/site-a/database.sql.gz"
    printf site > "${root}/var/www/moodle/site-a/config.php"
    printf data > "${root}/var/moodledata/site-a/file"
    printf unit > "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.service"
    printf timer > "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.timer"
}

program_root="${TEST_ROOT}/program"
prepare_fixture "${program_root}"
cmd_uninstall program
[[ ! -e "${MOODLEKIT_INSTALL_DIR}" && ! -e "${MOODLEKIT_BIN_LINK}" ]]
[[ -f "${MOODLEKIT_STATE_DIR}/vault.bin" && -f "${MOODLEKIT_OPT_DIR}/config.json" ]]
[[ -f "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.timer" ]]
[[ -f "${program_root}/var/www/moodle/site-a/config.php" ]]

automation_root="${TEST_ROOT}/automation"
prepare_fixture "${automation_root}"
cmd_uninstall automation
[[ ! -e "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.timer" ]]
[[ ! -e "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.service" ]]
[[ -f "${MOODLEKIT_STATE_DIR}/vault.bin" && -f "${MOODLEKIT_OPT_DIR}/config.json" ]]
grep -Fqx 'disable --now moodlekit-backup.timer' "${automation_root}/systemctl.log"

full_root="${TEST_ROOT}/full"
prepare_fixture "${full_root}"
cmd_uninstall full
[[ ! -e "${MOODLEKIT_STATE_DIR}" && ! -e "${MOODLEKIT_OPT_DIR}" ]]
recovery="$(find "${MOODLEKIT_BACKUP_DIR}" -maxdepth 1 -type d -name 'uninstall-recovery-*' -print -quit)"
[[ -f "${recovery}/moodlekit-state/vault.bin" ]]
[[ -f "${recovery}/moodlekit-data/config.json" ]]
[[ -f "${MOODLEKIT_BACKUP_DIR}/site-a/database.sql.gz" ]]
[[ -f "${full_root}/var/www/moodle/site-a/config.php" ]]
[[ -f "${full_root}/var/moodledata/site-a/file" ]]

echo "Safe uninstall tests passed"
