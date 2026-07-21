#!/bin/bash
val="
\$CFG->session_handler_class = '\core\session\redis';
\$CFG->session_redis_host    = '127.0.0.1';
\$CFG->session_redis_port    = 6379;
\$CFG->session_redis_prefix  = 'mdl_test_sess_';"

content="start {{CACHE_CONFIG}} end"
key="CACHE_CONFIG"

# old way
echo "Old way:"
val_old="$(echo "${val}" | sed 's/[&/\\]/\\&/g; s/\n/\\n/g')"
echo "${content}" | sed "s|{{${key}}}|${val_old}|g" || echo "FAILED"

# new way
echo "New way:"
val_new="${val}"
val_new="${val_new//\\/\\\\}"
val_new="${val_new//|/\\|}"
val_new="${val_new//&/\\&}"
val_new="${val_new//$'\n'/\\n}"
echo "${content}" | sed "s|{{${key}}}|${val_new}|g"
