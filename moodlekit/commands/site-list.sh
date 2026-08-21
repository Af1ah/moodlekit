#!/usr/bin/env bash
# =============================================================================
# commands/site-list.sh — List managed Moodle sites from encrypted vault
# =============================================================================

cmd_site_list() {
    load_global_conf 0 || true

    local slugs=()
    while IFS= read -r s; do
        [[ -n "${s}" ]] && slugs+=("${s}")
    done < <(list_site_slugs)

    if [[ ${#slugs[@]} -eq 0 ]]; then
        info "No Moodle sites currently registered in MoodleKit's encrypted vault."
        
        # Check for unmanaged sites
        local unmanaged=()
        while IFS= read -r udir; do
            [[ -n "${udir}" ]] && unmanaged+=("${udir}")
        done < <(find_moodle_installations 2>/dev/null)
        
        if [[ ${#unmanaged[@]} -gt 0 ]]; then
            echo ""
            info "Discovered unmanaged Moodle installations on server:"
            for u in "${unmanaged[@]}"; do
                local u_ver
                u_ver="$(detect_moodle_version_string "${u}")"
                echo -e "  • ${u} (Moodle ${u_ver}) — run 'moodlekit adopt \"${u}\"' to manage"
            done
        fi
        return 0
    fi

    section "MoodleKit — Managed Sites"
    
    printf "%-14s | %-24s | %-8s | %-8s | %-12s | %-10s | %-10s\n" "SLUG" "DOMAIN" "MOODLE" "PHP" "DATABASE" "TYPE" "FPM WORKERS"
    printf "%s\n" "---------------------------------------------------------------------------------------------------------------"

    for slug in "${slugs[@]}"; do
        (
            load_site_conf "${slug}" 0 || true
            
            local fpm_workers="?"
            if [[ -n "${FPM_POOL_CONF:-}" && -f "${FPM_POOL_CONF}" ]]; then
                fpm_workers=$(grep -E '^pm\.max_children' "${FPM_POOL_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
            fi

            printf "%-14s | %-24s | %-8s | %-8s | %-12s | %-10s | %-10s\n" \
                "${slug}" \
                "${DOMAIN:-unknown}" \
                "${MOODLE_VERSION:-unknown}" \
                "${PHP_VERSION:-unknown}" \
                "${DB_TYPE:-unknown}" \
                "${TYPE:-managed}" \
                "${fpm_workers}"
        )
    done
    
    echo ""
    info "Total managed sites: ${#slugs[@]}"
}
