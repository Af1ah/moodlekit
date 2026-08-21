# =============================================================================
# templates/nginx-moodle4.conf.tpl — Moodle 4.x (flat / index.php routing)
# =============================================================================
# Placeholders: {{DOMAIN}} {{MOODLE_DIR}} {{MOODLEDATA_DIR}}
#               {{PHP_VERSION}} {{SLUG}}
# =============================================================================

# HTTP → HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS — Moodle 4.x (traditional flat directory structure)
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

    # ── Moodle 4.x: web root is the Moodle directory itself ──────────────────
    root  {{MOODLE_DIR}};
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

    # ── Upload limits ─────────────────────────────────────────────────────────
    client_max_body_size 256M;

    # ── Block sensitive paths ─────────────────────────────────────────────────
    location ~ /\.                            { deny all; return 404; }
    location ^~ /vendor/                      { deny all; return 404; }
    location ^~ /node_modules/                { deny all; return 404; }
    location ~* (composer\.(json|lock)|package\.json) { deny all; return 404; }
    location ~* /(phpunit|behat)             { deny all; return 404; }
    location ~* \.(md|txt|rst)$             { deny all; return 404; }
    location = /config.php                   { deny all; return 404; }

    # ── Moodle 4.x routing: non-file requests → index.php ────────────────────
    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    # ── PHP handler with PATH_INFO ─────────────────────────────────────────────
    location ~ \.php(/|$) {
        fastcgi_split_path_info  ^(.+\.php)(/.*)$;
        fastcgi_pass             unix:{{FPM_SOCK}};
        include                  fastcgi_params;

        fastcgi_param SCRIPT_FILENAME  $realpath_root$fastcgi_script_name;
        fastcgi_param PATH_INFO        $fastcgi_path_info;
        fastcgi_param SCRIPT_NAME      $fastcgi_script_name;

        fastcgi_read_timeout   300;
        fastcgi_send_timeout   300;
        fastcgi_connect_timeout 60;
        fastcgi_buffers        16 16k;
        fastcgi_buffer_size    32k;
    }

    # ── Login rate limiting ────────────────────────────────────────────────────
    location = /login/index.php {
        limit_req zone=moodle_login burst=3 nodelay;
        limit_req_status 429;
        fastcgi_split_path_info  ^(.+\.php)(/.*)$;
        fastcgi_pass             unix:{{FPM_SOCK}};
        include                  fastcgi_params;
        fastcgi_param SCRIPT_FILENAME  $realpath_root$fastcgi_script_name;
        fastcgi_param PATH_INFO        $fastcgi_path_info;
    }

    # ── X-Accel-Redirect for moodledata file serving ──────────────────────────
    location /dataroot/ {
        internal;
        alias {{MOODLEDATA_DIR}}/;
    }

    # Static assets caching removed as per user request.

}
