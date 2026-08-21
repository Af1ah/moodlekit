[{{SLUG}}]
; =============================================================================
; MoodleKit PHP-FPM Pool — {{SLUG}}
; Generated: {{TIMESTAMP}}
; Worker calculation: (available_ram - db - cache - os) / 384MB / num_sites
; =============================================================================

; ── Identity ────────────────────────────────────────────────────────────────
user  = www-data
group = www-data

; ── Unix socket (no TCP overhead) ────────────────────────────────────────────
listen = {{FPM_SOCK}}
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

; ── Process manager — dynamic ─────────────────────────────────────────────────
pm                   = dynamic
pm.max_children      = {{MAX_CHILDREN}}
pm.start_servers     = {{START_SERVERS}}
pm.min_spare_servers = {{MIN_SPARE}}
pm.max_spare_servers = {{MAX_SPARE}}
pm.max_requests      = 500

; ── Timeouts ─────────────────────────────────────────────────────────────────
request_terminate_timeout = 300
request_slowlog_timeout   = 10
slowlog = /var/log/php{{PHP_VERSION}}-fpm-{{SLUG}}-slow.log

; ── PHP ini overrides for this pool ──────────────────────────────────────────
php_admin_value[memory_limit]          = 384M
php_admin_value[upload_max_filesize]   = 256M
php_admin_value[post_max_size]         = 256M
php_admin_value[max_execution_time]    = 300
php_admin_value[max_input_time]        = 600
php_admin_value[max_input_vars]        = 5000
php_admin_value[date.timezone]         = {{TIMEZONE}}
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_value[error_log]             = /var/log/php{{PHP_VERSION}}-fpm-{{SLUG}}.log

; ── OPcache: validate timestamps in case of upgrades ─────────────────────────
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq]     = 60
php_admin_value[opcache.save_comments]       = 1

; ── Security ──────────────────────────────────────────────────────────────────
php_admin_value[open_basedir]          = {{MOODLE_DIR}}:{{MOODLEDATA_DIR}}:/tmp:/usr/share/php
php_admin_value[disable_functions]     = exec,passthru,proc_open,popen,system
php_admin_flag[expose_php]             = off

; ── Status page (for monitoring) ─────────────────────────────────────────────
pm.status_path = /fpm-status-{{SLUG}}
ping.path      = /fpm-ping-{{SLUG}}
ping.response  = pong

; ── Environment ──────────────────────────────────────────────────────────────
env[HOSTNAME]      = $HOSTNAME
env[PATH]          = /usr/local/bin:/usr/bin:/bin
env[TMP]           = /tmp
env[TMPDIR]        = /tmp
env[TEMP]          = /tmp
env[MOODLEKIT_SLUG] = {{SLUG}}
