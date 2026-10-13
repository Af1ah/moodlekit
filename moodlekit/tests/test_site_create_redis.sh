#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/commands/site-create.sh"
info() { :; }
warn() { :; }
PHP_VERSION=8.4
redis-cli() { echo "${REDIS_REPLY}"; }
timeout() { shift; "$@"; }
/usr/bin/php8.4() { echo "${PHP_MODULES}"; }

REDIS_REPLY=PONG
PHP_MODULES=redis
unset USE_REDIS
_site_create_detect_redis
[[ "${USE_REDIS}" == 1 ]]

USE_REDIS=auto
REDIS_REPLY=NOAUTH
_site_create_detect_redis
[[ "${USE_REDIS}" == 0 ]]

unset USE_REDIS
REDIS_REPLY=PONG
PHP_MODULES=Core
_site_create_detect_redis
[[ "${USE_REDIS}" == 0 ]]

USE_REDIS=0
PHP_MODULES=redis
_site_create_detect_redis
[[ "${USE_REDIS}" == 0 ]]

USE_REDIS=1
REDIS_REPLY=NOAUTH
_site_create_detect_redis
[[ "${USE_REDIS}" == 1 ]]

echo "Site creation Redis detection tests passed"
