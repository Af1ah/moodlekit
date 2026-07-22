# =============================================================================
# templates/nginx-moodle5.conf.tpl — Moodle 5.x (public/ + r.php routing)
# =============================================================================
# Placeholders: {{DOMAIN}} {{MOODLE_DIR}} {{MOODLEDATA_DIR}}
#               {{PHP_VERSION}} {{SLUG}} {{DOMAIN}}
# =============================================================================

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    # Allow ACME challenge for Certbot
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS — Moodle 5.x (public/ web root + r.php front controller)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{DOMAIN}};

    # ── TLS ──────────────────────────────────────────────────────────────────
    ssl_certificate      /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
    ssl_certificate_key  /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/{{DOMAIN}}/chain.pem;
    ssl_session_timeout  1d;
    ssl_session_cache    shared:MozSSL:10m;
    ssl_protocols        TLSv1.2 TLSv1.3;
    ssl_ciphers          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_stapling on;
    ssl_stapling_verify on;

    # ── Moodle 5.x: document root is /public subdirectory ────────────────────
    root  {{MOODLE_DIR}}/public;
    index index.php;

    # ── Logging ──────────────────────────────────────────────────────────────
    access_log /var/log/nginx/moodle-{{SLUG}}.access.log;
    error_log  /var/log/nginx/moodle-{{SLUG}}.error.log;

    # ── Security headers ──────────────────────────────────────────────────────
    add_header X-Frame-Options         "SAMEORIGIN"                      always;
    add_header X-Content-Type-Options  "nosniff"                         always;
    add_header Referrer-Policy         "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection        "1; mode=block"                   always;
    add_header Permissions-Policy      "geolocation=(), microphone=()"   always;
    server_tokens off;

    # ── Upload limits (matching PHP ini) ─────────────────────────────────────
    client_max_body_size 256M;

    # ── Block access to sensitive paths ──────────────────────────────────────
    # Hidden files (.git, .env, .htaccess)
    location ~ /\.                              { deny all; return 404; }
    # Moodle 5.x: vendor/node_modules are outside public/ but block if found
    location ^~ /vendor/                        { deny all; return 404; }
    location ^~ /node_modules/                  { deny all; return 404; }
    # Composer/npm metadata
    location ~* (composer\.(json|lock)|package\.json|yarn\.lock) { deny all; return 404; }
    # PHPUnit & Behat
    location ~* /(phpunit|behat)               { deny all; return 404; }
    # Readme / changelogs
    location ~* \.(md|txt|rst)$               { deny all; return 404; }
    # config.php is outside public/ in Moodle 5.x — but guard anyway
    location = /config.php                     { deny all; return 404; }

    # ── Moodle 5.x Router: all non-file requests → r.php ─────────────────────
    location / {
        try_files $uri $uri/ /r.php?$args;
    }

    # ── PHP handler with PATH_INFO for slash-arguments ────────────────────────
    # e.g. /styles.php/boost/1234567890/all
    location ~ \.php(/|$) {
        fastcgi_split_path_info  ^(.+\.php)(/.*)$;
        fastcgi_pass             unix:/run/php/php{{PHP_VERSION}}-fpm-moodle_{{SLUG}}.sock;
        include                  fastcgi_params;

        # Essential for Moodle 5.x router — use realpath_root not document_root
        fastcgi_param SCRIPT_FILENAME  $realpath_root$fastcgi_script_name;
        fastcgi_param PATH_INFO        $fastcgi_path_info;
        fastcgi_param SCRIPT_NAME      $fastcgi_script_name;

        # Timeouts & buffers
        fastcgi_read_timeout   300;
        fastcgi_send_timeout   300;
        fastcgi_connect_timeout 60;
        fastcgi_buffers        16 16k;
        fastcgi_buffer_size    32k;
        fastcgi_busy_buffers_size 64k;
    }

    # ── Login rate limiting (5 req/min per IP) ────────────────────────────────
    location = /login/index.php {
        limit_req zone=moodle_login burst=3 nodelay;
        limit_req_status 429;
        # Still needs PHP handler
        fastcgi_split_path_info  ^(.+\.php)(/.*)$;
        fastcgi_pass             unix:/run/php/php{{PHP_VERSION}}-fpm-moodle_{{SLUG}}.sock;
        include                  fastcgi_params;
        fastcgi_param SCRIPT_FILENAME  $realpath_root$fastcgi_script_name;
        fastcgi_param PATH_INFO        $fastcgi_path_info;
    }

    # ── X-Accel-Redirect: internal file serving for moodledata ───────────────
    location /dataroot/ {
        internal;
        alias {{MOODLEDATA_DIR}}/;
    }

    # Static assets caching removed as per user request.

}
