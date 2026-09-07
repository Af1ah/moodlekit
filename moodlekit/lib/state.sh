#!/usr/bin/env bash
# Non-secret SQLite state index. The encrypted vault remains authoritative.

[[ -n "${_MOODLEKIT_STATE_INDEX_LOADED:-}" ]] && return 0
_MOODLEKIT_STATE_INDEX_LOADED=1

MOODLEKIT_STATE_DB="${MOODLEKIT_STATE_DB:-${MOODLEKIT_STATE_DIR:-/etc/moodlekit}/state.db}"
MOODLEKIT_STATE_PY="${MOODLEKIT_STATE_PY:-${MOODLEKIT_LIB}/state_index.py}"
MOODLEKIT_OPERATION_ID=""

_state_cli() {
    python3 "${MOODLEKIT_STATE_PY}" --db "${MOODLEKIT_STATE_DB}" "$@"
}

_state_warn() {
    local message="$1"
    if type warn &>/dev/null; then
        warn "State index: ${message}"
    else
        printf 'Warning: state index: %s\n' "${message}" >&2
    fi
}

state_init() {
    _state_cli init >/dev/null 2>&1 || true
}

state_operation_start() {
    local kind="$1" slug="$2" metadata_json="${3:-}"
    local output=""
    [[ -n "${metadata_json}" ]] || metadata_json='{}'
    if ! output="$(_state_cli operation-start \
        --kind "${kind}" --slug "${slug}" --metadata-json "${metadata_json}" 2>&1)"; then
        _state_warn "could not start '${kind}' journal for '${slug}': ${output}"
        MOODLEKIT_OPERATION_ID=""
    else
        MOODLEKIT_OPERATION_ID="${output}"
    fi
    export MOODLEKIT_OPERATION_ID
}

state_operation_step() {
    local step_name="$1" status="${2:-running}" message="${3:-}"
    [[ -n "${MOODLEKIT_OPERATION_ID:-}" ]] || return 0
    local output=""
    if ! output="$(_state_cli operation-update --id "${MOODLEKIT_OPERATION_ID}" \
        --status "${status}" --step "${step_name}" --message "${message}" 2>&1)"; then
        _state_warn "could not update operation ${MOODLEKIT_OPERATION_ID}: ${output}"
    fi
}

state_operation_finish() {
    local status="$1" message="${2:-}"
    [[ -n "${MOODLEKIT_OPERATION_ID:-}" ]] || return 0
    local output=""
    if ! output="$(_state_cli operation-update --id "${MOODLEKIT_OPERATION_ID}" \
        --status "${status}" --message "${message}" 2>&1)"; then
        _state_warn "could not finish operation ${MOODLEKIT_OPERATION_ID}: ${output}"
    fi
    MOODLEKIT_OPERATION_ID=""
    export MOODLEKIT_OPERATION_ID
}

state_site_upsert() {
    local site_json="$1"
    local output=""
    if ! output="$(_state_cli site-upsert --json "${site_json}" 2>&1)"; then
        _state_warn "could not update site cache: ${output}"
    fi
}

state_site_delete() {
    local slug="$1"
    local output=""
    if ! output="$(_state_cli site-delete --slug "${slug}" 2>&1)"; then
        _state_warn "could not remove '${slug}' from site cache: ${output}"
    fi
}

state_site_slugs() {
    [[ -f "${MOODLEKIT_STATE_DB}" ]] || return 0
    _state_cli site-list 2>/dev/null | jq -r '.[].slug' 2>/dev/null || true
}
