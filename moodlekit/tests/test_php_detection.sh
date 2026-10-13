#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/lib/detect.sh"

command() {
    if [[ "$1" == -v ]]; then
        [[ "$2" == "${TEST_PHP_COMMAND}" ]]
    else
        builtin command "$@"
    fi
}
timeout() {
    [[ "$2" == "${TEST_PHP_COMMAND}" ]]
    printf 'PHP %s (cli)\n' "${TEST_PHP_VERSION}"
}

for TEST_PHP_COMMAND in php php8.3; do
    TEST_PHP_VERSION=8.3.12
    INSTALLED_TOOLS=()
    detect_installed_php
    [[ "${PHP_INSTALLED}" == 8.3 ]]
    [[ "${PHP_INSTALLED_VERSION}" == 8.3.12 ]]
    [[ "${INSTALLED_TOOLS[0]}" == 'PHP 8.3.12' ]]
done

TEST_PHP_COMMAND=missing
INSTALLED_TOOLS=()
detect_installed_php
[[ -z "${PHP_INSTALLED}" ]]
echo "PHP detection tests passed"
