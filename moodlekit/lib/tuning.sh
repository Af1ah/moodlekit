#!/usr/bin/env bash
# =============================================================================
# lib/tuning.sh — MoodleKit RAM-aware auto-tuning engine
# =============================================================================
# Dynamically calculates PHP-FPM workers, DB buffer sizes, OPcache, Redis
# memory based on detected hardware. Never exceeds 80% of total RAM.
# =============================================================================

[[ -n "${_MOODLEKIT_TUNING_LOADED:-}" ]] && return 0
_MOODLEKIT_TUNING_LOADED=1

# ---------------------------------------------------------------------------
# Constants (all in MB unless stated)
# ---------------------------------------------------------------------------
readonly TUNING_OS_RESERVE_MB=1024          # 1GB reserved for OS
readonly TUNING_OPCACHE_MB=256              # OPcache (fixed)
readonly TUNING_JIT_BUFFER_MB=128           # JIT buffer (fixed)
readonly TUNING_WORKER_MEMORY_MB=384        # Avg PHP-FPM worker memory for Moodle
readonly TUNING_SAFETY_FACTOR="0.80"        # Max 80% of total RAM
readonly TUNING_CONSERVATIVE_FACTOR="0.60"  # Conservative mode

# ---------------------------------------------------------------------------
# Calculate all tuning values from hardware specs
# Call after detect_hardware() has set RAM_TOTAL_MB etc.
# ---------------------------------------------------------------------------
calculate_tuning() {
    local mode="${1:-balanced}"    # balanced | conservative | aggressive
    local num_sites="${2:-1}"      # Number of Moodle sites on this server
    local db_type="${3:-postgres}" # postgres | mariadb | mysql

    local safety_factor="${TUNING_SAFETY_FACTOR}"
    [[ "${mode}" == "conservative" ]] && safety_factor="${TUNING_CONSERVATIVE_FACTOR}"
    [[ "${mode}" == "aggressive" ]]   && safety_factor="0.88"

    local total_mb="${RAM_TOTAL_MB:-2048}"

    # Max usable MB
    local usable_mb
    usable_mb=$(echo "${total_mb} ${safety_factor}" | awk '{printf "%d", $1 * $2}')

    # OS reserve
    local remaining_mb=$(( usable_mb - TUNING_OS_RESERVE_MB ))

    # ---------------------------------------------------------------------------
    # Database allocation (30% of usable for postgres, 50% for MariaDB/MySQL
    # since they don't have shared_buffers equivalent at a system level)
    # ---------------------------------------------------------------------------
    local db_alloc_mb
    case "${db_type}" in
        postgres)
            db_alloc_mb=$(( remaining_mb * 30 / 100 ))
            TUNE_PG_SHARED_BUFFERS_MB=$(( remaining_mb * 20 / 100 ))
            TUNE_PG_EFFECTIVE_CACHE_MB=$(( remaining_mb * 50 / 100 ))
            # work_mem: RAM / 1000, min 4MB, max 64MB
            TUNE_PG_WORK_MEM_MB=$(( remaining_mb / 1000 ))
            (( TUNE_PG_WORK_MEM_MB < 4 ))  && TUNE_PG_WORK_MEM_MB=4
            (( TUNE_PG_WORK_MEM_MB > 64 )) && TUNE_PG_WORK_MEM_MB=64
            TUNE_PG_MAINTENANCE_WORK_MEM_MB=$(( TUNE_PG_SHARED_BUFFERS_MB / 8 ))
            (( TUNE_PG_MAINTENANCE_WORK_MEM_MB < 64 ))  && TUNE_PG_MAINTENANCE_WORK_MEM_MB=64
            (( TUNE_PG_MAINTENANCE_WORK_MEM_MB > 2048 )) && TUNE_PG_MAINTENANCE_WORK_MEM_MB=2048
            TUNE_PG_WAL_BUFFERS_MB=16
            ;;
        mariadb|mysql)
            db_alloc_mb=$(( remaining_mb * 45 / 100 ))
            # InnoDB buffer pool: 45% of RAM for shared server
            TUNE_INNODB_BUFFER_POOL_MB="${db_alloc_mb}"
            # InnoDB log file size: 25% of buffer pool, max 2GB
            TUNE_INNODB_LOG_FILE_MB=$(( TUNE_INNODB_BUFFER_POOL_MB / 4 ))
            (( TUNE_INNODB_LOG_FILE_MB > 2048 )) && TUNE_INNODB_LOG_FILE_MB=2048
            ;;
    esac
    remaining_mb=$(( remaining_mb - db_alloc_mb ))

    # ---------------------------------------------------------------------------
    # OPcache + JIT
    # ---------------------------------------------------------------------------
    remaining_mb=$(( remaining_mb - TUNING_OPCACHE_MB - TUNING_JIT_BUFFER_MB ))

    # ---------------------------------------------------------------------------
    # Redis (6% of total, min 256MB, max 4096MB)
    # ---------------------------------------------------------------------------
    TUNE_REDIS_MAX_MB=$(echo "${total_mb}" | awk '{printf "%d", $1 * 0.06}')
    (( TUNE_REDIS_MAX_MB < 256 ))  && TUNE_REDIS_MAX_MB=256
    (( TUNE_REDIS_MAX_MB > 4096 )) && TUNE_REDIS_MAX_MB=4096
    remaining_mb=$(( remaining_mb - TUNE_REDIS_MAX_MB ))

    # Memcached (if present): 256MB fixed
    TUNE_MEMCACHED_MB=256
    # (Don't deduct unless memcached selected — bootstrap handles this)

    # ---------------------------------------------------------------------------
    # PHP-FPM total workers
    # ---------------------------------------------------------------------------
    (( remaining_mb < 384 )) && remaining_mb=384
    local total_workers=$(( remaining_mb / TUNING_WORKER_MEMORY_MB ))
    (( total_workers < 2 )) && total_workers=2

    # Per-site workers
    local sites="${num_sites}"
    (( sites < 1 )) && sites=1
    local per_site_workers=$(( total_workers / sites ))
    (( per_site_workers < 2 )) && per_site_workers=2

    TUNE_FPM_MAX_CHILDREN="${per_site_workers}"
    TUNE_FPM_START_SERVERS=$(( per_site_workers / 3 ))
    (( TUNE_FPM_START_SERVERS < 1 )) && TUNE_FPM_START_SERVERS=1
    TUNE_FPM_MIN_SPARE=$(( per_site_workers / 4 ))
    (( TUNE_FPM_MIN_SPARE < 1 )) && TUNE_FPM_MIN_SPARE=1
    TUNE_FPM_MAX_SPARE=$(( per_site_workers * 2 / 3 ))
    (( TUNE_FPM_MAX_SPARE < TUNE_FPM_START_SERVERS )) && TUNE_FPM_MAX_SPARE="${TUNE_FPM_START_SERVERS}"

    # ---------------------------------------------------------------------------
    # PostgreSQL max_connections: total_workers * 1.5 + 20 headroom
    # ---------------------------------------------------------------------------
    TUNE_PG_MAX_CONNECTIONS=$(( total_workers * 15 / 10 + 20 ))
    (( TUNE_PG_MAX_CONNECTIONS < 50 ))  && TUNE_PG_MAX_CONNECTIONS=50
    (( TUNE_PG_MAX_CONNECTIONS > 500 )) && TUNE_PG_MAX_CONNECTIONS=500

    # InnoDB: max_connections same formula
    TUNE_MYSQL_MAX_CONNECTIONS="${TUNE_PG_MAX_CONNECTIONS}"

    # ---------------------------------------------------------------------------
    # PHP ini settings
    # ---------------------------------------------------------------------------
    TUNE_PHP_MEMORY_LIMIT_MB=384
    TUNE_PHP_UPLOAD_MB=256
    TUNE_PHP_POST_MB=256
    TUNE_PHP_MAX_INPUT_VARS=5000
    TUNE_PHP_MAX_EXEC_TIME=300
    TUNE_PHP_MAX_INPUT_TIME=600

    # Export summary string
    TUNING_SUMMARY="$(cat <<EOF
RAM:              ${total_mb}MB total, ~${usable_mb}MB usable (${mode} mode)
DB allocation:    ${db_alloc_mb}MB
OPcache:          ${TUNING_OPCACHE_MB}MB
JIT buffer:       ${TUNING_JIT_BUFFER_MB}MB
Redis maxmemory:  ${TUNE_REDIS_MAX_MB}MB
FPM total workers: ${total_workers} (${num_sites} sites × max ${per_site_workers}/site)
PHP memory_limit: ${TUNE_PHP_MEMORY_LIMIT_MB}MB
EOF
)"
}

# ---------------------------------------------------------------------------
# Apply PostgreSQL tuning — writes to conf.d file
# ---------------------------------------------------------------------------
apply_pg_tuning() {
    local pg_version="${1:-17}"
    local conf_dir="/etc/postgresql/${pg_version}/main/conf.d"
    local conf_file="${conf_dir}/moodlekit-tuning.conf"

    mkdir -p "${conf_dir}"

    cat > "${conf_file}" << PGCONF
# =============================================================================
# MoodleKit auto-generated PostgreSQL tuning — $(date)
# RAM: ${RAM_TOTAL_MB}MB | Mode: balanced
# DO NOT EDIT — regenerate with: moodlekit tune
# =============================================================================

# Memory
shared_buffers                 = ${TUNE_PG_SHARED_BUFFERS_MB}MB
effective_cache_size           = ${TUNE_PG_EFFECTIVE_CACHE_MB}MB
work_mem                       = ${TUNE_PG_WORK_MEM_MB}MB
maintenance_work_mem           = ${TUNE_PG_MAINTENANCE_WORK_MEM_MB}MB
wal_buffers                    = ${TUNE_PG_WAL_BUFFERS_MB}MB

# Connections
max_connections                = ${TUNE_PG_MAX_CONNECTIONS}

# WAL & checkpoints
checkpoint_completion_target   = 0.9
max_wal_size                   = 2GB
min_wal_size                   = 80MB

# Query planner
random_page_cost               = 1.1
effective_io_concurrency       = 200

# Logging (log slow queries over 1s)
log_min_duration_statement     = 1000
log_checkpoints                = on
log_connections                = off
log_disconnections             = off
log_lock_waits                 = on
log_temp_files                 = 0

# Timezone
timezone                       = 'UTC'
PGCONF

    ok "PostgreSQL tuning written to ${conf_file}"
    systemctl restart "postgresql" 2>/dev/null || systemctl restart "postgresql@${pg_version}-main" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Apply MariaDB / MySQL tuning
# ---------------------------------------------------------------------------
apply_mysql_tuning() {
    local db_type="${1:-mariadb}"
    local conf_file="/etc/mysql/conf.d/moodlekit-tuning.cnf"

    cat > "${conf_file}" << MYCONF
# =============================================================================
# MoodleKit auto-generated ${db_type} tuning — $(date)
# RAM: ${RAM_TOTAL_MB}MB
# =============================================================================

[mysqld]
# InnoDB
innodb_buffer_pool_size        = ${TUNE_INNODB_BUFFER_POOL_MB}M
innodb_buffer_pool_instances   = $(( TUNE_INNODB_BUFFER_POOL_MB / 1024 > 1 ? TUNE_INNODB_BUFFER_POOL_MB / 1024 : 1 ))
innodb_log_file_size           = ${TUNE_INNODB_LOG_FILE_MB}M
innodb_flush_method            = O_DIRECT
innodb_file_per_table          = 1
innodb_flush_log_at_trx_commit = 2
innodb_io_capacity             = 1000
innodb_io_capacity_max         = 2000

# Connections
max_connections                = ${TUNE_MYSQL_MAX_CONNECTIONS}
max_allowed_packet             = 256M
table_open_cache               = 4000
table_definition_cache         = 2000
open_files_limit               = 65535

# Queries
query_cache_type               = 0
query_cache_size               = 0
tmp_table_size                 = 64M
max_heap_table_size            = 64M

# Logging
slow_query_log                 = 1
slow_query_log_file            = /var/log/mysql/slow.log
long_query_time                = 1

# Character set
character_set_server           = utf8mb4
collation_server               = utf8mb4_unicode_ci
MYCONF

    ok "MariaDB/MySQL tuning written to ${conf_file}"
    systemctl restart "${db_type}" 2>/dev/null || systemctl restart "mysql" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Apply PHP-FPM ini tuning (applies to both FPM and CLI)
# ---------------------------------------------------------------------------
apply_php_tuning() {
    local php_ver="$1"
    local fpm_ini="/etc/php/${php_ver}/fpm/php.ini"
    local cli_ini="/etc/php/${php_ver}/cli/php.ini"

    _tune_ini() {
        local ini_file="$1"
        [[ -f "${ini_file}" ]] || return 0

        sed -i "s|^memory_limit\s*=.*|memory_limit = ${TUNE_PHP_MEMORY_LIMIT_MB}M|" "${ini_file}"
        sed -i "s|^upload_max_filesize\s*=.*|upload_max_filesize = ${TUNE_PHP_UPLOAD_MB}M|" "${ini_file}"
        sed -i "s|^post_max_size\s*=.*|post_max_size = ${TUNE_PHP_POST_MB}M|" "${ini_file}"
        sed -i "s|^max_execution_time\s*=.*|max_execution_time = ${TUNE_PHP_MAX_EXEC_TIME}|" "${ini_file}"
        sed -i "s|^max_input_time\s*=.*|max_input_time = ${TUNE_PHP_MAX_INPUT_TIME}|" "${ini_file}"
        sed -i "s|^;max_input_vars\s*=.*|max_input_vars = ${TUNE_PHP_MAX_INPUT_VARS}|" "${ini_file}"
        sed -i "s|^max_input_vars\s*=.*|max_input_vars = ${TUNE_PHP_MAX_INPUT_VARS}|" "${ini_file}"
        # Add if not present
        grep -q '^max_input_vars' "${ini_file}" || echo "max_input_vars = ${TUNE_PHP_MAX_INPUT_VARS}" >> "${ini_file}"
    }

    # OPcache settings
    _tune_opcache() {
        local ini_file="$1"
        local opcache_ini
        opcache_ini="$(find "/etc/php/${php_ver}" -name 'opcache.ini' | head -1)"
        [[ -z "${opcache_ini}" ]] && opcache_ini="${ini_file}"

        cat >> "${opcache_ini}" << OPCACHECONF

; MoodleKit OPcache tuning — $(date)
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${TUNING_OPCACHE_MB}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.validate_timestamps=1
opcache.jit_buffer_size=${TUNING_JIT_BUFFER_MB}M
opcache.jit=1255
OPCACHECONF
    }

    _tune_ini "${fpm_ini}"
    _tune_ini "${cli_ini}"
    _tune_opcache "${fpm_ini}"
    ok "PHP ${php_ver} ini tuned"
}

# ---------------------------------------------------------------------------
# Apply Redis tuning
# ---------------------------------------------------------------------------
apply_redis_tuning() {
    local redis_conf="/etc/redis/redis.conf"
    [[ -f "${redis_conf}" ]] || { warn "Redis config not found: ${redis_conf}"; return 0; }

    sed -i "s|^# maxmemory .*|maxmemory ${TUNE_REDIS_MAX_MB}mb|" "${redis_conf}"
    sed -i "s|^maxmemory .*|maxmemory ${TUNE_REDIS_MAX_MB}mb|" "${redis_conf}"

    # Set if not present
    grep -q '^maxmemory ' "${redis_conf}" || echo "maxmemory ${TUNE_REDIS_MAX_MB}mb" >> "${redis_conf}"
    grep -q '^maxmemory-policy ' "${redis_conf}" || echo "maxmemory-policy allkeys-lru" >> "${redis_conf}"

    sed -i "s|^maxmemory-policy .*|maxmemory-policy allkeys-lru|" "${redis_conf}"

    # Disable persistence for pure caching use
    sed -i "s|^save |# save |" "${redis_conf}"
    sed -i "s|^appendonly yes|appendonly no|" "${redis_conf}"

    systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null || true
    ok "Redis tuned: maxmemory=${TUNE_REDIS_MAX_MB}MB, policy=allkeys-lru"
}

# ---------------------------------------------------------------------------
# Print tuning report (no changes)
# ---------------------------------------------------------------------------
print_tuning_report() {
    local num_sites="${1:-1}"
    local db_type="${2:-postgres}"

    calculate_tuning "balanced" "${num_sites}" "${db_type}"

    section "MoodleKit Tuning Report"
    echo ""
    echo -e "${C_BOLD}Server:${C_RESET}         ${RAM_TOTAL_MB}MB RAM, ${CPU_CORES} CPU cores, disk=${DISK_TYPE}"
    echo -e "${C_BOLD}Sites:${C_RESET}          ${num_sites}"
    echo -e "${C_BOLD}Database:${C_RESET}       ${db_type}"
    echo ""
    echo -e "${C_BOLD_CYAN}PHP-FPM (per site):${C_RESET}"
    echo -e "  pm.max_children      = ${TUNE_FPM_MAX_CHILDREN}"
    echo -e "  pm.start_servers     = ${TUNE_FPM_START_SERVERS}"
    echo -e "  pm.min_spare_servers = ${TUNE_FPM_MIN_SPARE}"
    echo -e "  pm.max_spare_servers = ${TUNE_FPM_MAX_SPARE}"
    echo -e "  memory_limit         = ${TUNE_PHP_MEMORY_LIMIT_MB}M"
    echo -e "  upload_max_filesize  = ${TUNE_PHP_UPLOAD_MB}M"
    echo ""
    if [[ "${db_type}" == "postgres" ]]; then
        echo -e "${C_BOLD_CYAN}PostgreSQL 17:${C_RESET}"
        echo -e "  shared_buffers       = ${TUNE_PG_SHARED_BUFFERS_MB}MB"
        echo -e "  effective_cache_size = ${TUNE_PG_EFFECTIVE_CACHE_MB}MB"
        echo -e "  work_mem             = ${TUNE_PG_WORK_MEM_MB}MB"
        echo -e "  max_connections      = ${TUNE_PG_MAX_CONNECTIONS}"
    else
        echo -e "${C_BOLD_CYAN}InnoDB (${db_type}):${C_RESET}"
        echo -e "  innodb_buffer_pool_size = ${TUNE_INNODB_BUFFER_POOL_MB}MB"
        echo -e "  max_connections         = ${TUNE_MYSQL_MAX_CONNECTIONS}"
    fi
    echo ""
    echo -e "${C_BOLD_CYAN}Redis:${C_RESET}"
    echo -e "  maxmemory            = ${TUNE_REDIS_MAX_MB}MB (allkeys-lru)"
    echo ""
    echo -e "${C_BOLD_CYAN}OPcache:${C_RESET}"
    echo -e "  memory_consumption   = ${TUNING_OPCACHE_MB}MB"
    echo -e "  jit_buffer_size      = ${TUNING_JIT_BUFFER_MB}MB"
    echo ""

    # Safety check
    local total_used=$(( TUNING_OS_RESERVE_MB + db_alloc_mb + TUNING_OPCACHE_MB + TUNING_JIT_BUFFER_MB + TUNE_REDIS_MAX_MB ))
    local fpm_used=$(( TUNE_FPM_MAX_CHILDREN * num_sites * TUNING_WORKER_MEMORY_MB ))
    local grand_total=$(( total_used + fpm_used ))
    local pct=$(( grand_total * 100 / RAM_TOTAL_MB ))
    echo -e "${C_BOLD}Estimated total RAM usage: ~$(human_size $(( grand_total * 1024 * 1024 ))) (${pct}% of ${RAM_TOTAL_GB}GB)${C_RESET}"
    if (( pct > 85 )); then
        warn "RAM usage is high (${pct}%%). Consider adding RAM or reducing FPM workers."
    else
        ok "RAM budget is safe (${pct}%%)"
    fi
}

# ---------------------------------------------------------------------------
# Rebalance FPM pools for all existing sites after add/remove
# ---------------------------------------------------------------------------
rebalance_fpm_pools() {
    local db_type="${1:-postgres}"
    local slugs=()
    while IFS= read -r slug; do
        [[ -n "${slug}" ]] && slugs+=("${slug}")
    done < <(list_site_slugs)

    local num_sites="${#slugs[@]}"
    [[ "${num_sites}" -eq 0 ]] && return 0

    calculate_tuning "balanced" "${num_sites}" "${db_type}"
    info "Rebalancing ${num_sites} FPM pool(s): max_children=${TUNE_FPM_MAX_CHILDREN} per site"

    for slug in "${slugs[@]}"; do
        # shellcheck source=/dev/null
        local pool_conf
        pool_conf="$(find /etc/php -name "moodle_${slug}.conf" -type f 2>/dev/null | head -1)"
        if [[ -f "${pool_conf}" ]]; then
            sed -i "s|^pm\.max_children\s*=.*|pm.max_children = ${TUNE_FPM_MAX_CHILDREN}|" "${pool_conf}"
            sed -i "s|^pm\.start_servers\s*=.*|pm.start_servers = ${TUNE_FPM_START_SERVERS}|" "${pool_conf}"
            sed -i "s|^pm\.min_spare_servers\s*=.*|pm.min_spare_servers = ${TUNE_FPM_MIN_SPARE}|" "${pool_conf}"
            sed -i "s|^pm\.max_spare_servers\s*=.*|pm.max_spare_servers = ${TUNE_FPM_MAX_SPARE}|" "${pool_conf}"
            ok "  Updated pool for ${slug}"
        fi
    done

    reload_fpm
    ok "All FPM pools rebalanced"
}
