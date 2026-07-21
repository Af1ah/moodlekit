#!/usr/bin/env bash
# =============================================================================
# MoodleKit Installer
# =============================================================================

set -euo pipefail

# Require root
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: Installer must be run as root."
    exit 1
fi

DEST_DIR="/opt/moodlekit"
BIN_LINK="/usr/local/bin/moodlekit"

echo "Installing MoodleKit to ${DEST_DIR}..."

# Copy files
mkdir -p "${DEST_DIR}"
cp -r lib commands templates backup moodlekit "${DEST_DIR}/"

# Set permissions
chmod +x "${DEST_DIR}/moodlekit"
find "${DEST_DIR}/commands" -type f -name "*.sh" -exec chmod +x {} \;
find "${DEST_DIR}/lib" -type f -name "*.sh" -exec chmod +x {} \;
chmod +x "${DEST_DIR}/backup/moodle_backup.py"

# Create symlink
ln -sf "${DEST_DIR}/moodlekit" "${BIN_LINK}"

echo "MoodleKit installed successfully."
echo "Run 'moodlekit --help' to get started."
