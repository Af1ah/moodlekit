<?php
// =============================================================================
// MoodleKit — Generated Multi-Tenant config.php
// Tenant: {{SLUG}} | Domain: {{DOMAIN}}
// =============================================================================

unset($CFG);
global $CFG;
$CFG = new stdClass();

// ── Database Configuration ──────────────────────────────────────────────────
$CFG->dbtype    = '{{DB_TYPE}}';        // mariadb | mysqli | pgsql
$CFG->dblibrary = 'native';
$CFG->dbhost    = '{{DB_HOST}}';
$CFG->dbname    = '{{DB_NAME}}';
$CFG->dbuser    = '{{DB_USER}}';
$CFG->dbpass    = '{{DB_PASS}}';
$CFG->prefix    = '{{DB_PREFIX}}';
$CFG->dboptions = [
    'dbpersist'     => 0,
    'dbport'        => '{{DB_PORT}}',
    'dbsocket'      => '',
{{#IS_POSTGRES}}
    'dbcollation'   => 'utf8',
{{/IS_POSTGRES}}
{{^IS_POSTGRES}}
    'dbcollation'   => 'utf8mb4_unicode_ci',
{{/IS_POSTGRES}}
    'connecttimeout'=> 20,
];

// ── Site & URL Configuration ────────────────────────────────────────────────
$CFG->wwwroot   = '{{WWWROOT}}';
$CFG->dataroot  = '/var/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02775;
$CFG->filepermissions      = 0664;

// ── Reverse Proxy & SSL Trust ───────────────────────────────────────────────
// Trusts Caddy SSL termination and X-Forwarded-* headers
$CFG->sslproxy      = {{SSLPROXY}};
$CFG->reverseproxy  = false;

// ── High Performance Internal File Serving (X-Accel-Redirect) ───────────────
// Dataroot is NOT directly accessible via HTTP; Caddy streams files internally
$CFG->xsendfile        = 'X-Accel-Redirect';
$CFG->xsendfilealiases = [
    '/dataroot/' => $CFG->dataroot,
];

// ── Moodle 5.x Router Support ───────────────────────────────────────────────
{{#IS_MOODLE5}}
$CFG->routerconfigured = true;
{{/IS_MOODLE5}}

// ── Redis Session Storage ───────────────────────────────────────────────────
{{#USE_REDIS_SESSIONS}}
$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host    = '{{REDIS_HOST}}';
$CFG->session_redis_port    = {{REDIS_PORT}};
{{#REDIS_AUTH}}
$CFG->session_redis_auth    = '{{REDIS_AUTH}}';
{{/REDIS_AUTH}}
$CFG->session_redis_prefix  = '{{SLUG}}_sess_';
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire          = 7200;
$CFG->session_redis_serializer_use_igbinary = true;
{{/USE_REDIS_SESSIONS}}

// ── Cron & CLI Limits ───────────────────────────────────────────────────────
$CFG->cronclionly   = true;
$CFG->pathtophp     = '/usr/local/bin/php';

// ── Security & Maintenance ──────────────────────────────────────────────────
$CFG->preventexecpath = true;

require_once(__DIR__ . '/lib/setup.php');
