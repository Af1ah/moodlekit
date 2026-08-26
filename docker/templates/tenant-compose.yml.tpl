# =============================================================================
# MoodleKit Tenant Compose Definition: {{SLUG}}
# Plan: {{PLAN_NAME}} ({{PLAN_DESC}})
# =============================================================================
services:
  moodle-app-{{SLUG}}:
    image: {{IMAGE_NAME}}
    container_name: moodle-app-{{SLUG}}
    restart: unless-stopped
    environment:
      PUID: ${PUID:-33}
      PGID: ${PGID:-33}
      DOMAIN: "{{DOMAIN}}"
      DB_TYPE: "{{DB_TYPE}}"
      DB_HOST: "{{DB_HOST}}"
      DB_PORT: "{{DB_PORT}}"
      DB_NAME: "{{DB_NAME}}"
      DB_USER: "{{DB_USER}}"
      DB_PASSWORD: "{{DB_PASS}}"
      REDIS_HOST: redis
      REDIS_PASSWORD: "{{REDIS_AUTH}}"
      # PHP-FPM Sizing Profile Parameters
      FPM_PM: "{{FPM_PM}}"
      FPM_MAX_CHILDREN: "{{FPM_MAX_CHILDREN}}"
      FPM_START_SERVERS: "{{FPM_START_SERVERS}}"
      FPM_MIN_SPARE_SERVERS: "{{FPM_MIN_SPARE}}"
      FPM_MAX_SPARE_SERVERS: "{{FPM_MAX_SPARE}}"
      FPM_PROCESS_IDLE_TIMEOUT: "{{FPM_IDLE_TIMEOUT}}"
      FPM_MAX_REQUESTS: "{{FPM_MAX_REQUESTS}}"
      PHP_MEMORY_LIMIT: "{{PHP_MEM_LIMIT}}"
    volumes:
      - {{BASE_DIR}}/sites/{{SLUG}}/code:/var/www/html
      - {{MOODLEDATA_PATH}}:/var/moodledata
      - {{BASE_DIR}}/docker/conf/php/fpm-pool.conf:/usr/local/etc/php-fpm.d/zz-moodlekit-pool.conf:ro
    deploy:
      resources:
        limits:
          cpus: "{{CPU_LIMIT}}"
          memory: "{{MEM_LIMIT}}"
    networks:
      - moodle_net

  moodle-cron-{{SLUG}}:
    image: {{IMAGE_NAME}}
    container_name: moodle-cron-{{SLUG}}
    restart: unless-stopped
    entrypoint: ["/usr/local/bin/docker-cron-entrypoint.sh"]
    environment:
      PUID: ${PUID:-33}
      PGID: ${PGID:-33}
      DOMAIN: "{{DOMAIN}}"
      CRON_INTERVAL: ${CRON_INTERVAL:-60}
      DB_TYPE: "{{DB_TYPE}}"
      DB_HOST: "{{DB_HOST}}"
      DB_PORT: "{{DB_PORT}}"
      DB_NAME: "{{DB_NAME}}"
      REDIS_HOST: redis
    volumes:
      - {{BASE_DIR}}/sites/{{SLUG}}/code:/var/www/html
      - {{MOODLEDATA_PATH}}:/var/moodledata
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: "1.0G"
    networks:
      - moodle_net

networks:
  moodle_net:
    external: true
