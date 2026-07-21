#!/usr/bin/env bash
# =============================================================================
# commands/site-list.sh — List managed Moodle sites
# =============================================================================

cmd_site_list() {
    load_global_conf

    local slugs
    mapfile -t slugs < <(list_site_slugs)

    if [[ ${#slugs[@]} -eq 0 ]]; then
        info "No Moodle sites managed by MoodleKit on this server."
        return 0
    fi

    section "MoodleKit — Managed Sites"
    
    printf "%-15s | %-25s | %-10s | %-8s | %-12s | %-10s\n" "SLUG" "DOMAIN" "MOODLE" "PHP" "DATABASE" "FPM WORKERS"
    printf "%s\n" "------------------------------------------------------------------------------------------------------"

    for slug in "${slugs[@]}"; do
        # We source the site conf in a subshell to avoid polluting variables between iterations
        (
            load_site_conf "${slug}"
            
            # Determine FPM workers from pool conf
            local fpm_workers="?"
            if [[ -f "${FPM_POOL_CONF}" ]]; then
                fpm_workers=$(grep -E '^pm\.max_children' "${FPM_POOL_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
            fi

            printf "%-15s | %-25s | %-10s | %-8s | %-12s | %-10s\n" \
                "${slug}" \
                "${DOMAIN}" \
                "${MOODLE_VERSION}" \
                "${PHP_VERSION}" \
                "${DB_TYPE}" \
                "${fpm_workers}"
        )
    done
    
    echo ""
    info "Total sites: ${#slugs[@]}"
}
