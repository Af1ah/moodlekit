#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d -t moodlekit_safety_state_XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_PY="${REPO_ROOT}/lib/state_index.py"
SAFETY_PY="${REPO_ROOT}/lib/safety.py"
STATE_DB="${TEST_ROOT}/state.db"

# Unattended mode must accept an intentionally empty optional default without
# trying to read stdin (which is EOF in automation/Multipass execution).
export MOODLEKIT_YES=1
# shellcheck source=../lib/interactive.sh
source "${REPO_ROOT}/lib/interactive.sh"
optional_value="not-empty"
input_text optional_value "Optional value" "" '^$' "must be empty"
[[ -z "${optional_value}" ]]

# Exercise the shell wrapper as well as the Python CLI. Supplied JSON used to
# gain an extra closing brace through `${3:-{}}` and fail silently.
export MOODLEKIT_LIB="${REPO_ROOT}/lib"
export MOODLEKIT_STATE_DIR="${TEST_ROOT}"
export MOODLEKIT_STATE_DB="${STATE_DB}"
# shellcheck source=../lib/state.sh
source "${REPO_ROOT}/lib/state.sh"
state_operation_start "site-create" "wrapper-demo" '{"domain":"wrapper.test"}'
[[ -n "${MOODLEKIT_OPERATION_ID}" ]]
state_operation_step "1/2 Validate"
state_operation_finish "completed" "wrapper done"
python3 "${STATE_PY}" --db "${STATE_DB}" operation-latest --slug wrapper-demo | jq -e \
    '.[0].kind == "site-create" and .[0].status == "completed" and .[0].metadata_json == "{\"domain\": \"wrapper.test\"}"' >/dev/null

# A nested command failure must reach the shared ERR handler so registered
# cleanup is not skipped merely because commands are implemented as functions.
rollback_marker="${TEST_ROOT}/nested-rollback-ran"
if ROLLBACK_MARKER="${rollback_marker}" REPO_ROOT="${REPO_ROOT}" bash -c '
    source "${REPO_ROOT}/lib/common.sh"
    inner_failure() { false; }
    outer_operation() {
        register_rollback "touch ${ROLLBACK_MARKER}"
        inner_failure
    }
    outer_operation
' >/dev/null 2>&1; then
    echo "Nested failure unexpectedly succeeded" >&2
    exit 1
fi
[[ -f "${rollback_marker}" ]]

# Permission hardening must preserve executable modes recorded by Git.
permission_repo="${TEST_ROOT}/permission-repo"
mkdir -p "${permission_repo}"
git -C "${permission_repo}" init -q
printf '#!/bin/sh\nexit 0\n' > "${permission_repo}/tracked-tool"
chmod 755 "${permission_repo}/tracked-tool"
git -C "${permission_repo}" add tracked-tool
chmod 644 "${permission_repo}/tracked-tool"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
chown() { :; }
normalize_moodle_code_permissions "${permission_repo}"
[[ "$(stat -c '%a' "${permission_repo}/tracked-tool")" == "755" ]]
[[ -z "$(git -C "${permission_repo}" diff --summary)" ]]

validate_domain "lms.example.com"
validate_domain "sandbox.local"
if validate_domain "https://bad.example.com:8443" >/dev/null 2>&1; then
    echo "URL unexpectedly passed domain validation" >&2
    exit 1
fi
if validate_domain "-bad.example.com" >/dev/null 2>&1; then
    echo "Malformed hostname unexpectedly passed domain validation" >&2
    exit 1
fi

python3 "${STATE_PY}" --db "${STATE_DB}" init
operation_id="$(python3 "${STATE_PY}" --db "${STATE_DB}" operation-start \
    --kind restore --slug demo --metadata-json '{"backup":"/safe/path","token":"OPERATION_SECRET"}')"
python3 "${STATE_PY}" --db "${STATE_DB}" operation-update \
    --id "${operation_id}" --status running --step "2/9 Safety snapshot"
python3 "${STATE_PY}" --db "${STATE_DB}" site-upsert --json \
    '{"slug":"demo","domain":"demo.test","moodle_dir":"/var/www/moodle/demo","db_type":"mysql","db_name":"moodle_demo","db_pass":"NEVER_STORE_THIS","moodle_version":"5.2","php_version":"8.4","is_moodle5":1}'
python3 "${STATE_PY}" --db "${STATE_DB}" operation-update \
    --id "${operation_id}" --status completed --message "done"

python3 "${STATE_PY}" --db "${STATE_DB}" site-list | jq -e \
    '.[0] | .slug == "demo" and .db_name == "moodle_demo" and (has("db_pass") | not)' >/dev/null
python3 "${STATE_PY}" --db "${STATE_DB}" operation-latest --slug demo | jq -e \
    '.[0].status == "completed" and .[0].current_step == "2/9 Safety snapshot" and .[0].finished_at != null' >/dev/null
if grep -aFq 'NEVER_STORE_THIS' "${STATE_DB}"; then
    echo "Secret leaked into non-secret state index" >&2
    exit 1
fi
if grep -aFq 'OPERATION_SECRET' "${STATE_DB}"; then
    echo "Operation secret leaked into non-secret state index" >&2
    exit 1
fi
[[ "$(stat -c '%a' "${STATE_DB}")" == "600" ]]
python3 "${STATE_PY}" --db "${STATE_DB}" site-delete --slug demo
python3 "${STATE_PY}" --db "${STATE_DB}" site-list | jq -e 'length == 0' >/dev/null

BACKUP_DIR="${TEST_ROOT}/backup"
mkdir -p "${BACKUP_DIR}/data/demo"
printf '%s\n' 'CREATE TABLE mdl_config (id INT);' | gzip > "${BACKUP_DIR}/database.sql.gz"
printf '%s\n' 'course data' > "${BACKUP_DIR}/data/demo/file.txt"
tar -czf "${BACKUP_DIR}/moodledata.tar.gz" -C "${BACKUP_DIR}/data" demo
db_sha="$(sha256sum "${BACKUP_DIR}/database.sql.gz" | cut -d' ' -f1)"
data_sha="$(sha256sum "${BACKUP_DIR}/moodledata.tar.gz" | cut -d' ' -f1)"
jq -n --arg db_sha "${db_sha}" --arg data_sha "${data_sha}" \
    '{db_type:"mysql",moodle_version:"5.2",php_version:"8.4",is_moodle5:1,
      checksums:{"database.sql.gz":$db_sha,"moodledata.tar.gz":$data_sha}}' \
    > "${BACKUP_DIR}/manifest.json"
python3 "${SAFETY_PY}" validate-backup "${BACKUP_DIR}" | jq -e \
    '.db_type == "mysql" and (.verified_artifacts | index("database.sql.gz"))' >/dev/null

MISSING_DB_DIR="${TEST_ROOT}/missing-db-backup"
mkdir -p "${MISSING_DB_DIR}"
jq -n '{db_type:"mysql",moodle_version:"5.2",php_version:"8.4",checksums:{}}' \
    > "${MISSING_DB_DIR}/manifest.json"
if python3 "${SAFETY_PY}" validate-backup "${MISSING_DB_DIR}" >/dev/null 2>&1; then
    echo "Backup without a database dump unexpectedly passed validation" >&2
    exit 1
fi

printf '%s\n' 'tampered' >> "${BACKUP_DIR}/database.sql.gz"
if python3 "${SAFETY_PY}" validate-backup "${BACKUP_DIR}" >/dev/null 2>&1; then
    echo "Tampered backup unexpectedly passed validation" >&2
    exit 1
fi

MALICIOUS_TAR="${TEST_ROOT}/malicious.tar.gz"
python3 - "${MALICIOUS_TAR}" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    info = tarfile.TarInfo("../escape.txt")
    payload = b"unsafe"
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
PY
if python3 "${SAFETY_PY}" validate-archive "${MALICIOUS_TAR}" >/dev/null 2>&1; then
    echo "Unsafe archive path unexpectedly passed validation" >&2
    exit 1
fi

# Fresh restore under a different slug must stage and rename the archive root;
# it must never extract over a live directory matching the backup's old slug.
# shellcheck source=../commands/restore.sh
source "${REPO_ROOT}/commands/restore.sh"
rename_fixture="${TEST_ROOT}/rename-fixture"
mkdir -p "${rename_fixture}/archive-source/oldslug" "${rename_fixture}/live/oldslug"
printf 'from-backup\n' > "${rename_fixture}/archive-source/oldslug/file.txt"
printf 'live-source\n' > "${rename_fixture}/live/oldslug/keep.txt"
tar -czf "${rename_fixture}/data.tar.gz" -C "${rename_fixture}/archive-source" oldslug
_extract_archive_to_target "${rename_fixture}/data.tar.gz" "${rename_fixture}/live/newslug"
[[ "$(cat "${rename_fixture}/live/newslug/file.txt")" == "from-backup" ]]
[[ "$(cat "${rename_fixture}/live/oldslug/keep.txt")" == "live-source" ]]

echo "Safety validator and SQLite state-index tests passed"
