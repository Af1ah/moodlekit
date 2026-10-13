#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/lib/interactive.sh"
source "${REPO_ROOT}/commands/site-create.sh"

# Stop at domain validation so these tests never provision a real site.
require_root() { :; }
load_global_conf() { :; }
validate_slug() { :; }
init_logging() { :; }
acquire_lock() { :; }
section() { :; }
warn() { :; }
C_BOLD="" C_DIM="" C_RESET=""
OPT_MOODLE_VERSION=5.2
MOODLEKIT_YES=0
validate_domain() {
    [[ "$1" == "${EXPECTED_DOMAIN}" ]]
    exit 0
}

# With no base domain, blank input must prompt again instead of using the slug.
(
    unset BASE_DOMAIN OPT_DOMAIN
    EXPECTED_DOMAIN=ssmce.example.org
    cmd_site_create ssmce <<< $'\nssmce.example.org'
)
(
    BASE_DOMAIN=""
    unset OPT_DOMAIN
    EXPECTED_DOMAIN=example.org
    cmd_site_create ssmce <<< 'example.org'
)

# A configured base domain still supplies the usual default.
(
    BASE_DOMAIN=example.org
    unset OPT_DOMAIN
    EXPECTED_DOMAIN=ssmce.example.org
    cmd_site_create ssmce <<< ''
)

# Explicit CLI domains bypass the prompt even when the base domain is unset.
(
    unset BASE_DOMAIN
    OPT_DOMAIN=custom.example.org
    EXPECTED_DOMAIN="${OPT_DOMAIN}"
    cmd_site_create ssmce < /dev/null
)

echo "Site creation domain prompt tests passed"
