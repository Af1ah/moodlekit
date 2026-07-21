#!/bin/bash
source lib/common.sh
slug="ansar"
cache_block="
// ── Redis Session Handler ─────────────────────────────────────────────────
\$CFG->session_handler_class = '\core\session\redis';
\$CFG->session_redis_host    = '127.0.0.1';
"
render_template_to_file "templates/config-moodle4.php.tpl" "test_config.php" "CACHE_CONFIG=${cache_block}" "DB_TYPE=mysqli" "DB_NAME=a" "DB_USER=b" "DB_PASS=c" "DB_PORT=3306" "DOMAIN=d" "MOODLEDATA_DIR=e" "PHP_VERSION=8.3"
cat test_config.php | grep session
