#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/commands/bootstrap.sh"
info() { :; }
ok() { :; }
err() { :; }
REDIS_INSTALLED=yes
ACTIVE=1
START_OK=1
CALLS=()
systemctl() {
    CALLS+=("$*")
    case "$1" in
        is-active) [[ "${ACTIVE}" == 1 ]] ;;
        start) [[ "${START_OK}" == 1 ]] ;;
        *) return 1 ;;
    esac
}
# Any attempt to install, edit configuration, or restart must fail the test.
apt-get() { return 1; }
sed() { return 1; }
_install_redis 8.4
[[ "${#CALLS[@]}" == 1 ]]
[[ "${CALLS[0]}" == 'is-active --quiet redis-server' ]]

ACTIVE=0
CALLS=()
_install_redis 8.4
[[ "${#CALLS[@]}" == 2 ]]
[[ "${CALLS[1]}" == 'start redis-server' ]]

START_OK=0
if _install_redis 8.4; then
    echo "Redis startup failure was ignored" >&2
    exit 1
fi
echo "Bootstrap Redis service preservation tests passed"
