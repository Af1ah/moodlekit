#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t moodlekit_doctor_db_XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

# shellcheck source=../commands/fix.sh
source "${REPO_ROOT}/commands/fix.sh"

_LOG_FILE="${TEST_ROOT}/doctor.log"
DB_TYPE=mariadb
DB_NAME=moodle_test
step() { :; }
spinner_start() { :; }
spinner_stop() { :; }
err() { :; }

mysqlcheck() {
    printf '%s\n' "$*" >> "${TEST_ROOT}/mysqlcheck.calls"
}

_fix_database test
mapfile -t calls < "${TEST_ROOT}/mysqlcheck.calls"
[[ "${#calls[@]}" -eq 2 ]]
[[ "${calls[0]}" == "-u root --auto-repair moodle_test" ]]
[[ "${calls[1]}" == "-u root --optimize moodle_test" ]]

mysqlcheck() {
    [[ "$*" != *"--optimize"* ]]
}
if _fix_database test; then
    echo "MariaDB Doctor unexpectedly ignored an optimization failure" >&2
    exit 1
fi

echo "Doctor MariaDB command tests passed"
