#!/usr/bin/env bash
# =============================================================================
# commands/tune.sh — Re-tune server performance
# =============================================================================

cmd_tune() {
    require_root
    load_global_conf
    
    local MODE="${1:-balanced}"
    
    if [[ ! "${MODE}" =~ ^(conservative|balanced|aggressive)$ ]]; then
        err "Invalid tuning mode. Use: conservative, balanced, or aggressive"
        exit 1
    fi
    
    init_logging "tune"
    
    section "MoodleKit — Server Tuning (${MODE})"
    
    detect_hardware
    
    local num_sites
    num_sites="$(list_site_slugs | wc -l)"
    if (( num_sites == 0 )); then
        num_sites=1 # Tune as if for 1 site even if none exist yet
    fi
    
    calculate_tuning "${MODE}" "${num_sites}" "${DB_TYPE}"
    
    # Print tuning report first
    print_tuning_report "${num_sites}" "${DB_TYPE}"
    echo ""
    
    if ! confirm "Apply these tuning settings to the server?" "y"; then
        info "Tuning aborted."
        exit 0
    fi
    
    # Apply tuning
    apply_php_tuning "${PHP_VERSION}"
    
    if [[ "${DB_TYPE}" == "postgres" ]]; then
        apply_pg_tuning 17
    else
        apply_mysql_tuning "${DB_TYPE}"
    fi
    
    if [[ "${USE_REDIS:-0}" == "1" ]]; then
        apply_redis_tuning
    fi
    
    if (( num_sites > 0 )); then
        rebalance_fpm_pools "${DB_TYPE}"
    fi
    
    ok "Server successfully re-tuned for ${MODE} mode"
}
