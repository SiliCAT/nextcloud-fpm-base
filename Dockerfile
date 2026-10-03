FROM php:8.4-fpm-alpine3.23

ARG APCU_VERSION=5.1.28
ARG IGBINARY_VERSION=3.2.16
ARG IMAGICK_VERSION=3.8.1
ARG REDIS_VERSION=6.3.0

ENV PHP_MEMORY_LIMIT=512M \
    PHP_UPLOAD_LIMIT=512M \
    PHP_OPCACHE_MEMORY_CONSUMPTION=128

# Route C PHP-FPM base image.
#
# This image owns only the PHP-FPM execution environment:
# - PHP runtime packages
# - required PHP extensions
# - PHP ini snippets
# - PHP-FPM pool settings
# - supervisord
# - cron helper
# - minimal runtime directory preparation for read-only rootfs
#
# It intentionally does not own the Nextcloud application lifecycle:
# - no Nextcloud source tree
# - no config.php
# - no .ncdata
# - no appdata_*
# - no install logic
# - no upgrade logic
# - no source switch logic
# - no runtime config reconciliation
# - no data migration
#
# Production persistent state contract:
#
# - /var/lib/nextcloud
#   Route C production file-state root.
#   In production this path must be supplied by an Incus storage volume.
#   It is not a Podman named volume contract.
#
# Expected production layout inside /var/lib/nextcloud:
#
# - /var/lib/nextcloud/releases
#   Versioned Nextcloud release trees.
#
# - /var/lib/nextcloud/web
#   Current Nextcloud work tree symlink.
#
# - /var/lib/nextcloud/local
#   Instance-local state root.
#
# - /var/lib/nextcloud/local/config
#   Persistent config directory.
#
# - /var/lib/nextcloud/local/custom_apps
#   Persistent third-party app directory.
#
# - /var/lib/nextcloud/local/themes
#   Persistent non-shipped themes source.
#
# - /var/lib/nextcloud/local/state
#   Deployment/source-switch state.
#
# - /var/lib/nextcloud/data
#   Local Nextcloud datadirectory.
#
# Runtime scratch contract:
#
# - /var/tmp/nextcloud/app
#   App-container runtime scratch root.
#   This path is not production persistent state and should not enter the
#   Incus storage volume backup boundary.
#
# Expected runtime app layout:
#
# - /var/tmp/nextcloud/app/php
#   PHP sys_temp_dir.
#
# - /var/tmp/nextcloud/app/php-upload
#   PHP upload_tmp_dir.
#
# - /var/tmp/nextcloud/app/nextcloud
#   Nextcloud tempdirectory.
#
# - /var/tmp/nextcloud/app/log
#   PHP-FPM slowlog and app-runtime logs.
#
# - /var/tmp/nextcloud/app/run
#   App runtime pid/socket/helper state.
#
# Runtime writable mounts expected for hardened app container:
#
# - /tmp
#   Generic process temporary directory.
#   Recommended as tmpfs.
#
# - /run
#   pid / runtime state.
#   Recommended as tmpfs.
#
# - /var/lib/nextcloud
#   Incus-volume-backed production file state, mounted rw for app container.
#
# - /var/tmp/nextcloud/app
#   Runtime scratch mounted rw for app container.
#
# External cron config expected at runtime:
#
# - /etc/crontabs/www-data
#   The deployment / cron_enable layer owns this file.
#   It may provide it via bind mount, generated config mount, or writable
#   runtime crontab mount. This image intentionally does not create the job file.
#
# Important boundary:
#
# The image may create only top-level placeholders required for mount targets.
# It must not create /var/lib/nextcloud/releases, web, local, or data business
# state. Those paths belong to Incus volume preparation, source, install,
# runtime, and volume owner convergence layers.
RUN set -eux; \
    apk add --no-cache \
        bash \
        supervisor \
        tzdata \
        imagemagick \
        imagemagick-pdf \
        imagemagick-jpeg \
        imagemagick-raw \
        imagemagick-tiff \
        imagemagick-heic \
        imagemagick-webp \
        imagemagick-svg \
    ; \
    mkdir -p \
        /var/lib/nextcloud \
        /etc/crontabs \
        /var/tmp/nextcloud \
        /var/tmp/nextcloud/app \
    ; \
    chown www-data:www-data /var/lib/nextcloud; \
    chown www-data:www-data /var/tmp/nextcloud/app; \
    chmod 0755 /var/lib/nextcloud; \
    chmod 0750 /var/tmp/nextcloud/app; \
    rm -f /etc/crontabs/root /var/spool/cron/crontabs/root

# Build PHP extensions required by the Nextcloud PHP-FPM base runtime.
#
# Removed by design:
# - pdo_mysql
# - ldap
# - memcached
# - ftp
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        ${PHPIZE_DEPS} \
        autoconf \
        freetype-dev \
        gmp-dev \
        icu-dev \
        imagemagick-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        lz4-dev \
        pcre-dev \
        postgresql-dev \
        zstd-dev \
    ; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        gd \
        gmp \
        intl \
        pcntl \
        pdo_pgsql \
        sysvsem \
        zip \
    ; \
    pecl install APCu-${APCU_VERSION}; \
    pecl install igbinary-${IGBINARY_VERSION}; \
    pecl install imagick-${IMAGICK_VERSION}; \
    pecl install --configureoptions 'enable-redis-igbinary="yes" enable-redis-zstd="yes" enable-redis-lz4="yes"' redis-${REDIS_VERSION}; \
    docker-php-ext-enable \
        apcu \
        igbinary \
        imagick \
        redis \
    ; \
    rm -rf /tmp/pear; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-network --virtual .nextcloud-phpext-rundeps ${runDeps}; \
    apk del --no-network .build-deps; \
    rm -rf /tmp/* /var/cache/apk/*

# Recommended PHP / OPcache / APCu / igbinary settings.
#
# Notes:
# - JIT is intentionally not enabled.
# - OPcache is already available in the official PHP image and is verified
#   by runtime inspection.
# - ${...} values are intentionally written into ini files for runtime env expansion.
# - docker-php-ext-*.ini files are still generated by docker-php-ext-install /
#   docker-php-ext-enable; this block only adds runtime parameters.
# - FPM-only timeout and tmpdir settings are placed in the FPM pool below,
#   not in global CLI/FPM shared ini.
RUN set -eux; \
    { \
        echo 'opcache.enable=1'; \
        echo 'opcache.enable_cli=1'; \
        echo 'opcache.interned_strings_buffer=32'; \
        echo 'opcache.max_accelerated_files=10000'; \
        echo 'opcache.memory_consumption=${PHP_OPCACHE_MEMORY_CONSUMPTION}'; \
        echo 'opcache.save_comments=1'; \
        echo 'opcache.revalidate_freq=60'; \
    } > "${PHP_INI_DIR}/conf.d/opcache-recommended.ini"; \
    { \
        echo 'apc.enable_cli=1'; \
    } >> "${PHP_INI_DIR}/conf.d/docker-php-ext-apcu.ini"; \
    { \
        echo 'apc.serializer=igbinary'; \
        echo 'session.serialize_handler=igbinary'; \
    } >> "${PHP_INI_DIR}/conf.d/docker-php-ext-igbinary.ini"; \
    { \
        echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
        echo 'upload_max_filesize=${PHP_UPLOAD_LIMIT}'; \
        echo 'post_max_size=${PHP_UPLOAD_LIMIT}'; \
    } > "${PHP_INI_DIR}/conf.d/nextcloud.ini"

# Override only the upstream www.conf pool body.
#
# Important:
# - keep upstream docker.conf and zz-docker.conf
# - keep the official [www] pool name
# - do not duplicate docker.conf-owned container runtime settings
#
# docker.conf already owns:
# - [global] error_log = /proc/self/fd/2
# - log_limit = 8192
# - [www] access.log = /proc/self/fd/2
# - [www] clear_env = no
# - [www] catch_workers_output = yes
# - [www] decorate_workers_output = no
# - [www] listen = 9000
#
# This www.conf only defines:
# - pool user/group
# - process manager policy
# - request timeout / slowlog / status / ping
# - FPM-only php_admin_value settings
#
# Read-only rootfs note:
# - slowlog is placed under /var/tmp/nextcloud/app/log
# - /var/tmp/nextcloud/app must be an explicit writable runtime mount
# - /entrypoint.sh recreates child directories before php-fpm starts
#
# Route C app-container assumptions:
# - all Nextcloud-aware containers see the same instance namespace at /var/lib/nextcloud
# - PHP-FPM app container uses /var/lib/nextcloud/web as the Nextcloud work tree
# - local datadirectory is /var/lib/nextcloud/data
# - web container reaches this app container via FastCGI TCP/9000
# - topology-specific access control belongs to the Podman/network layer,
#   not to the image build layer
RUN set -eux; \
    { \
        echo '[www]'; \
        echo 'user = www-data'; \
        echo 'group = www-data'; \
        echo ''; \
        echo 'pm = dynamic'; \
        echo 'pm.max_children = 32'; \
        echo 'pm.start_servers = 4'; \
        echo 'pm.min_spare_servers = 2'; \
        echo 'pm.max_spare_servers = 8'; \
        echo 'pm.max_requests = 500'; \
        echo ''; \
        echo 'request_terminate_timeout = 3600s'; \
        echo 'request_slowlog_timeout = 60s'; \
        echo 'slowlog = /var/tmp/nextcloud/app/log/php-fpm-slow.log'; \
        echo ''; \
        echo 'pm.status_path = /fpm-status'; \
        echo 'ping.path = /fpm-ping'; \
        echo 'ping.response = pong'; \
        echo ''; \
        echo 'php_admin_value[max_execution_time] = 3600'; \
        echo 'php_admin_value[max_input_time] = 3600'; \
        echo 'php_admin_value[output_buffering] = 0'; \
        echo 'php_admin_value[cgi.fix_pathinfo] = 0'; \
        echo 'php_admin_value[upload_tmp_dir] = /var/tmp/nextcloud/app/php-upload'; \
        echo 'php_admin_value[sys_temp_dir] = /var/tmp/nextcloud/app/php'; \
    } > /usr/local/etc/php-fpm.d/www.conf

# Minimal cron daemon helper supervised by supervisord.
#
# This mirrors the upstream fpm-alpine cron.sh shape:
# - /cron.sh only starts busybox crond in foreground
# - it does not install any crontab
#
# Alpine / BusyBox cron contract:
# - /var/spool/cron/crontabs may be a symlink to /etc/crontabs
# - the real crontab file expected by this image is /etc/crontabs/www-data
# - the deployment / cron_enable layer owns that file
# - the image intentionally does not create the job file
#
# The cron_enable layer should write jobs that use:
# - php /var/lib/nextcloud/web/cron.php
#
# It should not use old work tree paths.
RUN set -eux; \
    { \
        echo '#!/bin/sh'; \
        echo 'set -eu'; \
        echo ''; \
        echo 'exec busybox crond -f -L /dev/stdout'; \
    } > /cron.sh; \
    chmod 0755 /cron.sh

# Minimal runtime directory preparation.
#
# This is not a Nextcloud lifecycle entrypoint.
# It does not install, upgrade, source-sync, or write config.php.
#
# It only prepares paths that may be hidden by explicit runtime mounts in a
# read-only rootfs deployment, then execs the requested command.
#
# Idempotency:
# - mkdir -p only creates missing runtime directories
# - chown/chmod only target fixed runtime directories
# - no recursive ownership rewrite is performed at container start
# - /var/lib/nextcloud is not created or repaired here
# - /var/lib/nextcloud/releases, web, local, and data are owned by the source /
#   install / runtime / volume-owner-converge layers, not by this image entrypoint
# - if ownership changes are not permitted for runtime mount paths, the script
#   still attempts mode convergence and then leaves the real writability check
#   to the runtime validation layer
RUN set -eux; \
    { \
        echo '#!/bin/sh'; \
        echo 'set -eu'; \
        echo ''; \
        echo 'mkdir -p /run'; \
        echo 'mkdir -p /tmp'; \
        echo 'mkdir -p /var/tmp/nextcloud/app/php'; \
        echo 'mkdir -p /var/tmp/nextcloud/app/php-upload'; \
        echo 'mkdir -p /var/tmp/nextcloud/app/nextcloud'; \
        echo 'mkdir -p /var/tmp/nextcloud/app/log'; \
        echo 'mkdir -p /var/tmp/nextcloud/app/run'; \
        echo ''; \
        echo 'RUNTIME_DIRS="/var/tmp/nextcloud/app /var/tmp/nextcloud/app/php /var/tmp/nextcloud/app/php-upload /var/tmp/nextcloud/app/nextcloud /var/tmp/nextcloud/app/log /var/tmp/nextcloud/app/run"'; \
        echo ''; \
        echo 'chown www-data:www-data ${RUNTIME_DIRS} 2>/dev/null || true'; \
        echo 'chmod 0750 ${RUNTIME_DIRS} 2>/dev/null || true'; \
        echo ''; \
        echo 'exec "$@"'; \
    } > /entrypoint.sh; \
    chmod 0755 /entrypoint.sh

# Container-local process supervisor.
#
# Read-only rootfs contract:
# - supervisord does not write persistent logs under /var/log
# - supervisord pidfile is under /run
# - child program stdout/stderr go to container logs
# - php-fpm is supervised
# - cron helper is supervised
#
# Crontab is intentionally absent from the image. The container may run with
# crond active but without jobs until deployment binds or creates:
# - /etc/crontabs/www-data
RUN set -eux; \
    { \
        echo '[supervisord]'; \
        echo 'nodaemon=true'; \
        echo 'user=root'; \
        echo 'logfile=/dev/null'; \
        echo 'logfile_maxbytes=0'; \
        echo 'pidfile=/run/supervisord.pid'; \
        echo 'childlogdir=/tmp'; \
        echo 'loglevel=error'; \
        echo ''; \
        echo '[program:php-fpm]'; \
        echo 'stdout_logfile=/dev/stdout'; \
        echo 'stdout_logfile_maxbytes=0'; \
        echo 'stderr_logfile=/dev/stderr'; \
        echo 'stderr_logfile_maxbytes=0'; \
        echo 'command=php-fpm'; \
        echo ''; \
        echo '[program:cron]'; \
        echo 'stdout_logfile=/dev/stdout'; \
        echo 'stdout_logfile_maxbytes=0'; \
        echo 'stderr_logfile=/dev/stderr'; \
        echo 'stderr_logfile_maxbytes=0'; \
        echo 'command=/cron.sh'; \
    } > /supervisord.conf

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/supervisord.conf"]
