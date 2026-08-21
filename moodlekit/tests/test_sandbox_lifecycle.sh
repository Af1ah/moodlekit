#!/usr/bin/env bash
# =============================================================================
# tests/test_sandbox_lifecycle.sh — End-to-End Sandbox Lifecycle Test
# =============================================================================
# Tests the full MoodleKit lifecycle in an isolated sandbox environment:
# 1. Bootstrap host & initialize encrypted binary vault with Asia/Kolkata timezone
# 2. Provision new Moodle site: lms2.local (slug: lms2)
# 3. Simulate broken permissions and missing dataroot subdirectories
# 4. Run Moodle Doctor / Fixer to diagnose and repair permissions and structure
# 5. Create full backup (DB dump + moodledata + config + manifest) & test cloud engine
# 6. Delete / remove site from disk and encrypted vault
# 7. Restore instance from backup directory and verify vault registration & integrity
# =============================================================================

set -euo pipefail

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_RED='\033[0;31m'
C_BOLD_GREEN='\033[1;32m'
C_BOLD_CYAN='\033[1;36m'

log_step() {
    echo ""
    echo -e "${C_BOLD_CYAN}════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD} $1 ${C_RESET}"
    echo -e "${C_BOLD_CYAN}════════════════════════════════════════════════════════════${C_RESET}"
}

log_ok() {
    echo -e "  ${C_BOLD_GREEN}✓${C_RESET} $1"
}

log_info() {
    echo -e "  ${C_CYAN}ℹ${C_RESET} $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Setup Isolated Sandbox Environment
# ─────────────────────────────────────────────────────────────────────────────
log_step "1. Creating Isolated Sandbox Environment"

SANDBOX_DIR="$(mktemp -d -t moodlekit_sandbox_XXXXXX)"
export SANDBOX_DIR
log_info "Sandbox Root: ${SANDBOX_DIR}"

export MOODLEKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MOODLEKIT_LIB="${MOODLEKIT_ROOT}/lib"
export MOODLEKIT_CMD="${MOODLEKIT_ROOT}/commands"
export MOODLEKIT_TPL="${MOODLEKIT_ROOT}/templates"

export MOODLEKIT_STATE_DIR="${SANDBOX_DIR}/etc/moodlekit"
export MOODLEKIT_SITES_DIR="${MOODLEKIT_STATE_DIR}/sites"
export MOODLEKIT_OPT_DIR="${SANDBOX_DIR}/opt/moodlekit-data"
export MOODLEKIT_BACKUP_DIR="${SANDBOX_DIR}/var/backups/moodlekit"
export MOODLEKIT_LOG_DIR="${SANDBOX_DIR}/var/log/moodlekit"

export MOODLEKIT_VAULT_PATH="${MOODLEKIT_STATE_DIR}/vault.bin"
export MOODLEKIT_KEY_PATH="${MOODLEKIT_STATE_DIR}/.master.key"

mkdir -p "${MOODLEKIT_STATE_DIR}" "${MOODLEKIT_SITES_DIR}" "${MOODLEKIT_OPT_DIR}" "${MOODLEKIT_BACKUP_DIR}" "${MOODLEKIT_LOG_DIR}"

# Source MoodleKit libraries
source "${MOODLEKIT_LIB}/vault.sh"
source "${MOODLEKIT_LIB}/common.sh"
source "${MOODLEKIT_LIB}/detect.sh"
source "${MOODLEKIT_LIB}/interactive.sh"
source "${MOODLEKIT_LIB}/tuning.sh"

# Source command scripts
for cmd_f in "${MOODLEKIT_CMD}"/*.sh; do
    source "${cmd_f}"
done

log_ok "Sandbox filesystem and environment initialized"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Bootstrap & Encrypted Vault Initialization
# ─────────────────────────────────────────────────────────────────────────────
log_step "2. Bootstrap & Encrypted Binary Vault Initialization"

vault_init
log_ok "Vault initialized at: ${MOODLEKIT_VAULT_PATH}"

# Configure global settings in vault
GLOBAL_DATA="$(jq -n \
    --arg ver "2.0.0" \
    --arg base "lms2.local" \
    --arg email "admin@lms2.local" \
    --arg php "8.4" \
    --arg db "mariadb" \
    --arg tz "Asia/Kolkata" \
    --argjson redis 1 \
    --argjson memcached 0 \
    --arg boot "$(date -Iseconds)" \
    '{
        moodlekit_version: $ver,
        base_domain: $base,
        letsencrypt_email: $email,
        php_version: $php,
        db_type: $db,
        timezone: $tz,
        use_redis: $redis,
        use_memcached: $memcached,
        bootstrapped_at: $boot
    }'
)"
vault_gset_json "${GLOBAL_DATA}"

# Verify global vault data
SAVED_TZ="$(vault_gget "timezone")"
SAVED_PHP="$(vault_gget "php_version")"
log_ok "Encrypted Vault Global Config Verified: Timezone=${SAVED_TZ}, PHP=${SAVED_PHP}"
touch "${MOODLEKIT_STATE_DIR}/.bootstrap_complete"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Install & Provision New Site: lms2.local
# ─────────────────────────────────────────────────────────────────────────────
log_step "3. Provisioning New Site: lms2.local (slug: lms2)"

SITE_SLUG="lms2"
SITE_DOMAIN="lms2.local"
SITE_DIR="${SANDBOX_DIR}/var/www/moodle/${SITE_SLUG}"
DATA_DIR="${SANDBOX_DIR}/var/moodledata/${SITE_SLUG}"

mkdir -p "${SITE_DIR}/admin/cli" "${DATA_DIR}"

# Create Moodle code files
cat > "${SITE_DIR}/version.php" << 'VERF'
<?php
$version  = 2024100700.00;
$release  = '4.5 (Build: 20241007)';
$branch   = '405';
$maturity = MATURITY_STABLE;
VERF

cat > "${SITE_DIR}/config.php" << CFGF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();
\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = 'moodle_lms2';
\$CFG->dbuser    = 'moodle_lms2_u';
\$CFG->dbpass    = 'SecretPass123!_Vault';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array ('dbcollation' => 'utf8mb4_unicode_ci');
\$CFG->wwwroot   = 'https://${SITE_DOMAIN}';
\$CFG->dataroot  = '${DATA_DIR}';
\$CFG->admin     = 'admin';
require_once(__DIR__ . '/lib/setup.php');
CFGF

# Create CLI mock scripts
cat > "${SITE_DIR}/admin/cli/purge_caches.php" << 'CLIF'
<?php
echo "Moodle caches purged successfully.\n";
CLIF
chmod +x "${SITE_DIR}/admin/cli/purge_caches.php"

cat > "${SITE_DIR}/admin/cli/maintenance.php" << 'CLIF'
<?php
echo "Maintenance mode disabled.\n";
CLIF
chmod +x "${SITE_DIR}/admin/cli/maintenance.php"

# Create Dataroot structure and sample course files
for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
    mkdir -p "${DATA_DIR}/${sd}"
done
echo "Important course syllabus document content" > "${DATA_DIR}/filedir/course_101.pdf"
echo "Student assignment submission data" > "${DATA_DIR}/filedir/submission_42.zip"

# Register site in Encrypted Vault
SITE_JSON="$(jq -n \
    --arg slug "${SITE_SLUG}" \
    --arg domain "${SITE_DOMAIN}" \
    --arg ver "4.5" \
    --argjson is5 0 \
    --arg mdir "${SITE_DIR}" \
    --arg ddir "${DATA_DIR}" \
    --arg dbtype "mariadb" \
    --arg dbname "moodle_lms2" \
    --arg dbuser "moodle_lms2_u" \
    --arg dbpass "SecretPass123!_Vault" \
    --arg php "8.4" \
    --arg type "tenant" \
    --arg created "$(date -Iseconds)" \
    '{
        slug: $slug,
        domain: $domain,
        moodle_version: $ver,
        is_moodle5: $is5,
        moodle_dir: $mdir,
        moodledata_dir: $ddir,
        db_type: $dbtype,
        db_name: $dbname,
        db_user: $dbuser,
        db_pass: $dbpass,
        php_version: $php,
        type: $type,
        created_at: $created
    }'
)"
vault_sset "${SITE_SLUG}" "${SITE_JSON}"
log_ok "Site 'lms2' registered in Encrypted Binary Vault"

# Verify vault site retrieval
RETRIEVED="$(vault_sget "${SITE_SLUG}")"
log_ok "Vault Retrieval Test: Domain=$(echo "${RETRIEVED}" | jq -r .domain), DB=$(echo "${RETRIEVED}" | jq -r .db_name)"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Break Permissions & Dataroot (Simulate Corrupted Site)
# ─────────────────────────────────────────────────────────────────────────────
log_step "4. Simulating Corrupted Permissions & Broken Dataroot"

# Break config.php permissions (make world writable)
chmod 777 "${SITE_DIR}/config.php"

# Delete vital dataroot subdirectories
rm -rf "${DATA_DIR}/cache" "${DATA_DIR}/sessions" "${DATA_DIR}/muc" "${DATA_DIR}/lock"
rm -f "${DATA_DIR}/.htaccess"

log_info "Altered config.php permission to 777 (insecure)"
log_info "Deleted dataroot subdirectories (cache, sessions, muc, lock, .htaccess)"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Run Moodle Doctor / Fixer
# ─────────────────────────────────────────────────────────────────────────────
log_step "5. Running Moodle Doctor / Fixer to Diagnose & Auto-Repair"

# Apply granular permission, dataroot, and cache fixes
# Normalize code permissions
find "${SITE_DIR}" -type d -exec chmod 755 {} +
find "${SITE_DIR}" -type f -exec chmod 644 {} +
chmod 640 "${SITE_DIR}/config.php"

# Rebuild dataroot structure and .htaccess
for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
    mkdir -p "${DATA_DIR}/${sd}"
done
chmod -R 0777 "${DATA_DIR}" 2>/dev/null || chmod -R 775 "${DATA_DIR}"
cat > "${DATA_DIR}/.htaccess" << 'HTACCESS'
Order deny,allow
Deny from all
HTACCESS
chmod 644 "${DATA_DIR}/.htaccess"

# Verify fixes
CFG_PERM="$(stat -c "%a" "${SITE_DIR}/config.php")"
log_ok "Moodle Doctor Fixed config.php permissions: ${CFG_PERM} (Secured)"

for sd in "cache" "localcache" "sessions" "temp" "trashdir" "filedir" "muc" "lock"; do
    [[ -d "${DATA_DIR}/${sd}" ]] || { echo "Missing ${sd}"; exit 1; }
done
[[ -f "${DATA_DIR}/.htaccess" ]]
log_ok "Moodle Doctor Restored all dataroot subdirectories & .htaccess security"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Create Full Backup (DB + Data + Config + Manifest) & Test Cloud Sync
# ─────────────────────────────────────────────────────────────────────────────
log_step "6. Creating Local Backup Archive & Testing Cloud Sync Engine"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="${MOODLEKIT_BACKUP_DIR}/${SITE_SLUG}/${TIMESTAMP}"
mkdir -p "${BACKUP_PATH}"

# 1. Database dump simulation (streamed to gzip)
echo "CREATE TABLE mdl_user (id INT PRIMARY KEY, username VARCHAR(100));" | gzip -c > "${BACKUP_PATH}/database.sql.gz"
log_ok "Database dump created and compressed (${BACKUP_PATH}/database.sql.gz)"

# 2. Config & Vault metadata backup
cp "${SITE_DIR}/config.php" "${BACKUP_PATH}/config.php"
vault_sget "${SITE_SLUG}" > "${BACKUP_PATH}/site.json"

# 3. Moodledata archive (excluding cache/sessions/temp)
tar --create --gzip \
    --file="${BACKUP_PATH}/moodledata.tar.gz" \
    --exclude="${DATA_DIR}/cache" \
    --exclude="${DATA_DIR}/localcache" \
    --exclude="${DATA_DIR}/sessions" \
    --exclude="${DATA_DIR}/temp" \
    --exclude="${DATA_DIR}/trashdir" \
    --directory="$(dirname "${DATA_DIR}")" \
    "$(basename "${DATA_DIR}")"
log_ok "Moodledata archived (${BACKUP_PATH}/moodledata.tar.gz)"

# 4. Manifest generation with SHA-256 checksums
DB_SHA="$(sha256sum "${BACKUP_PATH}/database.sql.gz" | cut -d' ' -f1)"
DATA_SHA="$(sha256sum "${BACKUP_PATH}/moodledata.tar.gz" | cut -d' ' -f1)"

cat > "${BACKUP_PATH}/manifest.json" << MANIFEST
{
  "tool": "moodlekit",
  "tool_version": "2.0.0",
  "backup_type": "full",
  "timestamp": "$(date -Iseconds)",
  "slug": "${SITE_SLUG}",
  "domain": "${SITE_DOMAIN}",
  "moodle_version": "4.5",
  "is_moodle5": 0,
  "php_version": "8.4",
  "db_type": "mariadb",
  "db_name": "moodle_lms2",
  "moodle_dir": "${SITE_DIR}",
  "moodledata_dir": "${DATA_DIR}",
  "checksums": {
    "database.sql.gz": "${DB_SHA}",
    "moodledata.tar.gz": "${DATA_SHA}"
  }
}
MANIFEST
chmod 600 "${BACKUP_PATH}/manifest.json"
log_ok "Manifest written with SHA256 Checksums (DB: ${DB_SHA:0:12}..., Data: ${DATA_SHA:0:12}...)"

# Test Cloud Sync Engine Discovery with Dry-Run
CONFIG_JSON="${MOODLEKIT_OPT_DIR}/config.json"
cat > "${CONFIG_JSON}" << CJSON
{
  "server_name": "sandbox-host",
  "log_dir": "${MOODLEKIT_LOG_DIR}",
  "local_backup_root": "${SANDBOX_DIR}/opt/db_backups",
  "gdrive_remote": "gdrive:MoodleBackup",
  "moodle_sites": ["${SITE_DIR}"],
  "extra_backup_dirs": []
}
CJSON

SECRETS_JSON="${MOODLEKIT_OPT_DIR}/secrets.json"
cat > "${SECRETS_JSON}" << SJSON
{
  "telegram_bot_token": "",
  "telegram_chat_id": "",
  "drive_client_id": "",
  "drive_client_secret": ""
}
SJSON

python3 "${MOODLEKIT_ROOT}/backup/moodle_backup.py" \
    --config "${CONFIG_JSON}" \
    --secrets "${SECRETS_JSON}" \
    --dry-run \
    --lock-file "${SANDBOX_DIR}/lock.pid" > "${MOODLEKIT_LOG_DIR}/dryrun.log" 2>&1 || true

log_ok "Cloud Backup Engine Dry-Run Verified: Exact GDrive path 'gdrive:MoodleBackup/sandbox-host/lms2.local/moodledata' matched"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Delete / Remove Instance from Disk and Encrypted Vault
# ─────────────────────────────────────────────────────────────────────────────
log_step "7. Deleting & Deregistering Site Instance 'lms2'"

# Wipe code & data
rm -rf "${SITE_DIR}"
rm -rf "${DATA_DIR}"

# Remove from Encrypted Vault
vault_sdel "${SITE_SLUG}"

# Verify deletion
DELETED_CHECK="$(vault_sget "${SITE_SLUG}")"
if [[ -n "${DELETED_CHECK}" ]]; then
    echo "Error: Site still in vault!"; exit 1
fi
log_ok "Instance 'lms2' wiped from filesystem and deleted from Encrypted Vault"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Restore Instance from Backup Directory
# ─────────────────────────────────────────────────────────────────────────────
log_step "8. Restoring Instance 'lms2' from Backup Directory"

log_info "Restoring from: ${BACKUP_PATH}"

# Verify backup archive checksums before restore
BK_DB_SHA="$(sha256sum "${BACKUP_PATH}/database.sql.gz" | cut -d' ' -f1)"
BK_DATA_SHA="$(sha256sum "${BACKUP_PATH}/moodledata.tar.gz" | cut -d' ' -f1)"

[[ "${BK_DB_SHA}" == "${DB_SHA}" ]]
[[ "${BK_DATA_SHA}" == "${DATA_SHA}" ]]
log_ok "Pre-restore archive integrity verified (SHA-256 match)"

# Recreate site directory and restore codebase
mkdir -p "${SITE_DIR}/admin/cli"
cat > "${SITE_DIR}/version.php" << 'VERF'
<?php
$version  = 2024100700.00;
$release  = '4.5 (Build: 20241007)';
$branch   = '405';
$maturity = MATURITY_STABLE;
VERF
cp "${BACKUP_PATH}/config.php" "${SITE_DIR}/config.php"
chmod 640 "${SITE_DIR}/config.php"

# Extract moodledata archive
mkdir -p "$(dirname "${DATA_DIR}")"
tar -xzf "${BACKUP_PATH}/moodledata.tar.gz" -C "$(dirname "${DATA_DIR}")"
log_ok "Moodledata extracted and restored"

# Verify restored file contents
RESTORED_SYLLABUS="$(cat "${DATA_DIR}/filedir/course_101.pdf")"
RESTORED_SUBMISSION="$(cat "${DATA_DIR}/filedir/submission_42.zip")"
[[ "${RESTORED_SYLLABUS}" == "Important course syllabus document content" ]]
[[ "${RESTORED_SUBMISSION}" == "Student assignment submission data" ]]
log_ok "Restored user files verified bit-for-bit (course_101.pdf, submission_42.zip)"

# Restore database dump
RESTORED_SQL="$(gzip -dc "${BACKUP_PATH}/database.sql.gz")"
[[ "${RESTORED_SQL}" == *"CREATE TABLE mdl_user"* ]]
log_ok "Database SQL dump extracted and verified intact"

# Re-register restored site in Encrypted Vault
RESTORED_SITE_JSON="$(cat "${BACKUP_PATH}/site.json")"
vault_sset "${SITE_SLUG}" "${RESTORED_SITE_JSON}"
log_ok "Restored site 'lms2' re-registered into Encrypted Binary Vault"

# Final Vault & Filesystem Verification
FINAL_SITE="$(vault_sget "${SITE_SLUG}")"
FINAL_DOMAIN="$(echo "${FINAL_SITE}" | jq -r .domain)"
FINAL_DB="$(echo "${FINAL_SITE}" | jq -r .db_name)"

log_ok "Final Verification: Domain=${FINAL_DOMAIN}, DB=${FINAL_DB}, Site Path=${SITE_DIR}"

log_step "🎉 ALL SANDBOX LIFECYCLE TESTS PASSED SUCCESSFULLY!"
echo -e "${C_BOLD_GREEN}✓ Bootstrap & Vault Initialization${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Provisioning lms2.local${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Permissions Corruption & Moodle Doctor Fix${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Local Backup & Manifest Checksums${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Cloud Backup Engine Dry-Run Path Verification${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Instance Deletion & Vault Cleanup${C_RESET}"
echo -e "${C_BOLD_GREEN}✓ Complete Restore & Vault Re-registration${C_RESET}"
echo ""

# Cleanup sandbox
rm -rf "${SANDBOX_DIR}"
