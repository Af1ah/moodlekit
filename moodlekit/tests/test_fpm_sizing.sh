#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
err() { :; }
# shellcheck source=../lib/tuning.sh
source "${REPO_ROOT}/lib/tuning.sh"

RAM_TOTAL_MB=8192
RAM_TOTAL_GB=8
MOODLEKIT_FPM_WORKER_MB=128
calculate_tuning balanced 1 postgres
[[ "${TUNE_FPM_WORKER_CAP}" -eq 10 ]]
[[ "${TUNE_FPM_MAX_CHILDREN}" -eq 10 ]]
[[ "${TUNE_FPM_START_SERVERS}" -le "${TUNE_FPM_MAX_CHILDREN}" ]]
if set_fpm_pool_workers 11; then
    echo "8GB sizing unexpectedly accepted more than 10 FPM workers" >&2
    exit 1
fi
set_fpm_pool_workers 8
[[ "${TUNE_FPM_MAX_CHILDREN}" -eq 8 ]]

unset MOODLEKIT_FPM_WORKER_MB
ps() {
    printf '%s\n' \
        'php-fpm8.4 102400 php-fpm: pool site-a' \
        'php-fpm8.4 204800 php-fpm: pool site-a' \
        'php-fpm8.4 307200 php-fpm: pool site-b' \
        'bash 999999 diagnostic command mentioning php-fpm: pool fake'
}
calculate_tuning balanced 2 mariadb
[[ "${TUNE_FPM_OBSERVED_RSS_MB}" -eq 300 ]]
[[ "${TUNE_FPM_WORKER_MEMORY_MB}" -eq 450 ]]
[[ "${TUNE_FPM_MAX_CHILDREN}" -le 10 ]]

echo "FPM measured-memory and 8GB cap tests passed"
