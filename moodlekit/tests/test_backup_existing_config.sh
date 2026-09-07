#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d -t moodlekit_backup_existing_XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export MOODLEKIT_SYSTEMD_DIR="${TEST_ROOT}/etc/systemd/system"
mkdir -p "${MOODLEKIT_SYSTEMD_DIR}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/interactive.sh
source "${REPO_ROOT}/lib/interactive.sh"

# Non-interactive selection must preserve all configured defaults, not reset to
# only the first discovered site.
is_interactive() { return 1; }
candidate_sites=("/var/www/one" "/var/www/two" "/var/www/three")
configured_sites=("/var/www/one" "/var/www/three")
selected_sites=()
select_many_preselected selected_sites configured_sites "Select sites" "${candidate_sites[@]}"
[[ "${selected_sites[*]}" == "/var/www/one /var/www/three" ]]

# Existing timer state must be read back and reused by edit/repair flows.
cat > "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.timer" << 'TIMERF'
[Timer]
OnCalendar=*-*-* 03:30:00
TIMERF

# shellcheck source=../commands/backup.sh
source "${REPO_ROOT}/commands/backup.sh"
[[ "$(_cloud_backup_schedule)" == "03:30" ]]

# Re-running deploy non-interactively repairs the executable/unit files while
# leaving the saved JSON and timer schedule unchanged.
export MOODLEKIT_ROOT="${REPO_ROOT}"
export MOODLEKIT_TPL="${REPO_ROOT}/templates"
export MOODLEKIT_OPT_DIR="${TEST_ROOT}/opt/moodlekit-data"
export MOODLEKIT_BACKUP_DIR="${TEST_ROOT}/var/backups/moodlekit"
export MOODLEKIT_LEGACY_BACKUP_DIR="${TEST_ROOT}/opt/moodle_backup"
export MOODLEKIT_YES=1
export _LOG_FILE="${TEST_ROOT}/deploy.log"
mkdir -p "${MOODLEKIT_OPT_DIR}/backup" "${MOODLEKIT_BACKUP_DIR}"
cat > "${MOODLEKIT_OPT_DIR}/backup/config.json" << 'CONFIGJSON'
{
  "gdrive_remote": "gdrive:ExistingRemote",
  "moodle_sites": ["/var/www/one", "/var/www/three"]
}
CONFIGJSON
config_before="$(sha256sum "${MOODLEKIT_OPT_DIR}/backup/config.json")"

require_root() { :; }
load_global_conf() { :; }
init_logging() { :; }
section() { :; }
print_box() { :; }
ok() { :; }
warn() { :; }
get_system_timezone() { printf '%s' 'Asia/Kolkata'; }
systemctl() { printf '%s\n' "$*" >> "${TEST_ROOT}/systemctl.log"; }

cmd_backup_deploy

[[ "$(sha256sum "${MOODLEKIT_OPT_DIR}/backup/config.json")" == "${config_before}" ]]
[[ -x "${MOODLEKIT_OPT_DIR}/backup/moodle_backup.py" ]]
[[ -f "${MOODLEKIT_SYSTEMD_DIR}/moodlekit-backup.service" ]]
[[ "$(_cloud_backup_schedule)" == "03:30" ]]
grep -Fqx 'enable --now moodlekit-backup.timer' "${TEST_ROOT}/systemctl.log"

echo "Existing cloud-backup configuration test passed"
