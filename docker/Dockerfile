# =============================================================================
# MoodleKit — High-Performance Production Moodle PHP-FPM Docker Image
# Supports Moodle 4.x (Classic) & Moodle 5.x (Modern public/ + r.php)
# =============================================================================
FROM php:8.3-fpm-bookworm

LABEL maintainer="MoodleKit Team"
LABEL description="Optimized Multi-Tenant Production Moodle PHP-FPM container"

# Set environment defaults
ENV DEBIAN_FRONTEND=noninteractive \
    PUID=33 \
    PGID=33 \
    MOODLE_DIR=/var/www/html \
    MOODLEDATA_DIR=/var/moodledata

# Install core build dependencies and runtime tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    # VCS & Utilities
    git \
    curl \
    wget \
    unzip \
    zip \
    tar \
    gosu \
    ca-certificates \
    locales \
    # Image & Document processing for Moodle
    ghostscript \
    graphviz \
    aspell \
    # Database clients for CLI healthchecks and backups
    mariadb-client \
    postgresql-client \
    # Extension build libraries
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libwebp-dev \
    libicu-dev \
    libzip-dev \
    libxml2-dev \
    libldap2-dev \
    libpq-dev \
    libonig-dev \
    libcurl4-openssl-dev \
    libsodium-dev \
    libzstd-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Configure locales
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Configure and compile PHP extensions
RUN docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    && docker-php-ext-configure ldap --with-libdir=lib/x86_64-linux-gnu/ \
    && docker-php-ext-install -j$(nproc) \
        bcmath \
        curl \
        exif \
        gd \
        intl \
        ldap \
        mbstring \
        mysqli \
        opcache \
        pcntl \
        pdo_mysql \
        pdo_pgsql \
        pgsql \
        soap \
        sodium \
        xml \
        zip

# Compile PECL extensions (Redis with igbinary & zstd compression, APCu)
RUN pecl install -o -f \
        igbinary \
        zstd \
        apcu \
    && pecl install --configureoptions='enable-redis-igbinary="yes" enable-redis-zstd="yes"' redis \
    && docker-php-ext-enable igbinary zstd redis apcu \
    && rm -rf /tmp/pear

# Install Composer
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Create required directories
RUN mkdir -p /var/www/html /var/moodledata /var/log/php /run/php \
    && chown -R www-data:www-data /var/www/html /var/moodledata /var/log/php /run/php \
    && chmod 2775 /var/moodledata

# Copy PHP and FPM configuration files
COPY conf/php/php.ini /usr/local/etc/php/conf.d/99-moodle-custom.ini
COPY conf/php/opcache.ini /usr/local/etc/php/conf.d/10-opcache.ini
COPY conf/php/fpm-pool.conf /usr/local/etc/php-fpm.d/zz-moodle.conf

# Copy entrypoint scripts
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY cron-entrypoint.sh /usr/local/bin/docker-cron-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-cron-entrypoint.sh

WORKDIR /var/www/html
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["php-fpm"]
