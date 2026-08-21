#!/usr/bin/env bash
# =============================================================================
# lib/vault.sh — MoodleKit Encrypted Binary Vault Bash Interface
# =============================================================================
# Interfaces with lib/vault.py for AES-256 encrypted credential and configuration
# storage. Automatically handles legacy migration and graceful unbootstrapped state.
# =============================================================================

[[ -n "${_MOODLEKIT_VAULT_LOADED:-}" ]] && return 0
_MOODLEKIT_VAULT_LOADED=1

MOODLEKIT_VAULT_PY="${MOODLEKIT_LIB}/vault.py"
MOODLEKIT_VAULT_FILE="${MOODLEKIT_VAULT_PATH:-/etc/moodlekit/vault.bin}"
MOODLEKIT_KEY_FILE="${MOODLEKIT_KEY_PATH:-/etc/moodlekit/.master.key}"

_vault_cli() {
    python3 "${MOODLEKIT_VAULT_PY}" \
        --vault-path "${MOODLEKIT_VAULT_PATH:-/etc/moodlekit/vault.bin}" \
        --key-path "${MOODLEKIT_KEY_PATH:-/etc/moodlekit/.master.key}" \
        "$@"
}

vault_init() {
    # If legacy configuration files exist and vault is new, migrate them automatically
    if [[ -f "/etc/moodlekit/global.conf" || -d "/etc/moodlekit/sites" ]]; then
        if [[ ! -f "${MOODLEKIT_VAULT_FILE}" ]]; then
            _vault_cli migrate >/dev/null 2>&1 || true
        fi
    fi
}

vault_gset() {
    local key="$1"
    local val="$2"
    _vault_cli gset "${key}" "${val}" >/dev/null
}

vault_gset_json() {
    local json_data="$1"
    _vault_cli gset-json "${json_data}" >/dev/null
}

vault_gget() {
    local key="$1"
    _vault_cli gget "${key}" 2>/dev/null || echo ""
}

vault_load_global() {
    vault_init
    local exports
    exports="$(_vault_cli gexport 2>/dev/null || true)"
    if [[ -n "${exports}" ]]; then
        eval "${exports}"
        return 0
    fi
    # Fallback to legacy file if exists
    if [[ -f "/etc/moodlekit/global.conf" ]]; then
        # shellcheck source=/dev/null
        source "/etc/moodlekit/global.conf"
        return 0
    fi
    return 1
}

vault_sset() {
    local slug="$1"
    local json_data="$2"
    _vault_cli sset "${slug}" "${json_data}" >/dev/null
}

vault_sget() {
    local slug="$1"
    _vault_cli sget "${slug}" 2>/dev/null || echo ""
}

vault_sdel() {
    local slug="$1"
    _vault_cli sdel "${slug}" >/dev/null 2>&1 || true
}

vault_slist() {
    vault_init
    local slugs
    slugs="$(_vault_cli slist 2>/dev/null || true)"
    if [[ -n "${slugs}" ]]; then
        echo "${slugs}"
    elif [[ -d "/etc/moodlekit/sites" ]]; then
        find "/etc/moodlekit/sites" -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.conf$||' | sort
    fi
}

vault_load_site() {
    local slug="$1"
    vault_init
    local exports
    exports="$(_vault_cli sexport "${slug}" 2>/dev/null || true)"
    if [[ -n "${exports}" ]]; then
        eval "${exports}"
        return 0
    fi
    # Fallback to legacy site conf file if exists
    if [[ -f "/etc/moodlekit/sites/${slug}.conf" ]]; then
        # shellcheck source=/dev/null
        source "/etc/moodlekit/sites/${slug}.conf"
        return 0
    fi
    return 1
}

vault_site_exists() {
    local slug="$1"
    vault_init
    local json_data
    json_data="$(_vault_cli sget "${slug}" 2>/dev/null || true)"
    [[ -n "${json_data}" ]] && return 0
    [[ -f "/etc/moodlekit/sites/${slug}.conf" ]] && return 0
    return 1
}
