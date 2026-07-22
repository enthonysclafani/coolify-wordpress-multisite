ARG OPENLITESPEED_IMAGE=litespeedtech/openlitespeed:1.8.5-lsphp83

FROM ${OPENLITESPEED_IMAGE} AS wordpress-runtime

ARG WP_CLI_VERSION=2.12.0

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -Eeuo pipefail; \
    php_candidates=(/usr/local/lsws/lsphp*/bin/php); \
    [[ ${#php_candidates[@]} -eq 1 && -x ${php_candidates[0]} ]] || { \
        echo "Atteso un solo runtime LSPHP, trovati: ${php_candidates[*]}" >&2; \
        exit 1; \
    }; \
    ln -s "${php_candidates[0]}" /usr/local/bin/stack-php; \
    for command in curl sha512sum runuser flock; do \
        command -v "${command}" >/dev/null || { echo "Comando richiesto assente: ${command}" >&2; exit 1; }; \
    done; \
    wp_cli_url="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    curl --fail --silent --show-error --location "${wp_cli_url}" --output /tmp/wp-cli.phar; \
    curl --fail --silent --show-error --location "${wp_cli_url}.sha512" --output /tmp/wp-cli.phar.sha512; \
    expected_checksum="$(tr -d '[:space:]' < /tmp/wp-cli.phar.sha512)"; \
    printf '%s  %s\n' "${expected_checksum}" /tmp/wp-cli.phar | sha512sum --check --strict -; \
    install -m 0755 /tmp/wp-cli.phar /usr/local/bin/wp; \
    rm -f /tmp/wp-cli.phar /tmp/wp-cli.phar.sha512; \
    /usr/local/bin/stack-php /usr/local/bin/wp --info >/dev/null

COPY openlitespeed/httpd_config.conf /usr/local/share/wordpress-stack/httpd_config.conf.template
COPY openlitespeed/vhosts/wordpress/vhconf.conf /usr/local/lsws/conf/vhosts/wordpress/vhconf.conf
COPY openlitespeed/vhosts/wordpress/.htaccess.template /usr/local/share/wordpress-stack/.htaccess.template
COPY openlitespeed/vhosts/wordpress/.htaccess.multisite-subdomain.template /usr/local/share/wordpress-stack/.htaccess.multisite-subdomain.template
COPY openlitespeed/vhosts/wordpress/.htaccess.single.template /usr/local/share/wordpress-stack/.htaccess.single.template
COPY config/wordpress-presets/ /usr/local/share/wordpress-stack/presets/
COPY docker/php/custom.ini.template /usr/local/share/wordpress-stack/custom.ini.template
COPY docker/php/opcache.ini.template /usr/local/share/wordpress-stack/opcache.ini.template
COPY docker/entrypoint.sh /usr/local/bin/wordpress-entrypoint
COPY docker/bootstrap-wordpress.sh /usr/local/bin/bootstrap-wordpress
COPY docker/healthcheck.sh /usr/local/bin/wordpress-healthcheck
COPY docker/cron.sh /usr/local/bin/wordpress-cron
COPY docker/worker.sh /usr/local/bin/wordpress-worker
COPY docker/coolify-multisite-https.php /usr/local/share/wordpress-stack/coolify-multisite-https.php
COPY docker/coolify-suite.php /usr/local/share/wordpress-stack/coolify-suite.php
COPY docker/coolify-s3-uploads.php /usr/local/share/wordpress-stack/coolify-s3-uploads.php
COPY docker/health-endpoint.php /usr/local/share/wordpress-stack/health-endpoint.php
COPY docker/manifest-tool.php /usr/local/lib/wordpress-stack/manifest-tool.php
COPY docker/apply-manifest.php /usr/local/lib/wordpress-stack/apply-manifest.php
COPY docker/manage-htaccess.php /usr/local/lib/wordpress-stack/manage-htaccess.php
COPY docker/manage-wp-config.php /usr/local/lib/wordpress-stack/manage-wp-config.php

RUN set -Eeuo pipefail; \
    chmod 0755 \
        /usr/local/bin/wordpress-entrypoint \
        /usr/local/bin/bootstrap-wordpress \
        /usr/local/bin/wordpress-healthcheck \
        /usr/local/bin/wordpress-cron \
        /usr/local/bin/wordpress-worker; \
    find /usr/local/share/wordpress-stack /usr/local/lib/wordpress-stack -type f -exec chmod 0644 {} +; \
    sed \
        -e 's|@OLS_MAX_CONNECTIONS@|10000|g' \
        -e 's|@OLS_KEEP_ALIVE_TIMEOUT@|5|g' \
        -e 's|@OLS_MAX_REQUEST_BODY_SIZE@|2047M|g' \
        -e 's|@LSAPI_CHILDREN@|10|g' \
        -e 's|@LSAPI_AVOID_FORK@|200M|g' \
        /usr/local/share/wordpress-stack/httpd_config.conf.template \
        > /usr/local/lsws/conf/httpd_config.conf; \
    chown -R lsadm:lsadm /usr/local/lsws/conf; \
    find /usr/local/lsws/conf -type d -exec chmod 0750 {} +; \
    find /usr/local/lsws/conf -type f -exec chmod 0640 {} +; \
    required_extensions=(curl exif gd imagick intl mbstring mysqli "zend opcache" redis zip); \
    loaded_extensions="$(/usr/local/bin/stack-php -m | tr '[:upper:]' '[:lower:]')"; \
    for extension in "${required_extensions[@]}"; do \
        grep -qx "${extension}" <<<"${loaded_extensions}" || { echo "Estensione PHP richiesta assente: ${extension}" >&2; exit 1; }; \
    done; \
    for php_file in \
        /usr/local/share/wordpress-stack/coolify-multisite-https.php \
        /usr/local/share/wordpress-stack/coolify-suite.php \
        /usr/local/share/wordpress-stack/coolify-s3-uploads.php \
        /usr/local/share/wordpress-stack/health-endpoint.php \
        /usr/local/lib/wordpress-stack/manifest-tool.php \
        /usr/local/lib/wordpress-stack/apply-manifest.php \
        /usr/local/lib/wordpress-stack/manage-htaccess.php \
        /usr/local/lib/wordpress-stack/manage-wp-config.php; do \
        /usr/local/bin/stack-php -l "${php_file}" >/dev/null; \
    done; \
    for manifest in /usr/local/share/wordpress-stack/presets/*.json; do \
        /usr/local/bin/stack-php /usr/local/lib/wordpress-stack/manifest-tool.php validate "${manifest}" >/dev/null; \
    done; \
    /usr/local/lsws/bin/openlitespeed -t

WORKDIR /var/www/vhosts/localhost/html

EXPOSE 7080

ENTRYPOINT ["/usr/local/bin/wordpress-entrypoint"]

FROM wordpress-runtime AS final

FROM composer:2.10.1 AS s3-module-builder

WORKDIR /app
COPY docker/s3-module/ /app/
RUN composer install \
    --no-dev \
    --no-interaction \
    --no-progress \
    --no-scripts \
    --prefer-dist \
    --classmap-authoritative

FROM wordpress-runtime AS wordpress-suite
COPY --from=s3-module-builder /app /usr/local/share/wordpress-stack/s3-module

FROM wordpress-runtime AS wordpress-immutable

ARG WORDPRESS_VERSION=7.0.2
ARG WORDPRESS_LOCALE=it_IT
ARG LITESPEED_CACHE_VERSION=7.8.1
ARG REDIS_CACHE_VERSION=2.8.0
ARG ELASTICPRESS_VERSION=5.3.3
ARG LITESPEED_CACHE_SHA256=b4c550a197f30212ab59489f75eb00e3610253db9ee3d837b1e8f7bf8ba803a9
ARG REDIS_CACHE_SHA256=f077ac8b9c154cee936d3872b0734d42f7fd7f350e68fe8b2b20a69e854980cd
ARG ELASTICPRESS_SHA256=157cd901955a7da718301431f668e9abcac48d41b8392897c3c4ccc93e820813

RUN set -Eeuo pipefail; \
    wordpress_root=/var/www/vhosts/localhost/html; \
    wp_cli_home=/tmp/wordpress-image-wp-cli; \
    install -d -m 0755 -o nobody -g nogroup "${wordpress_root}" "${wp_cli_home}" "${wp_cli_home}/cache"; \
    runuser -u nobody -- env HOME="${wp_cli_home}" WP_CLI_CACHE_DIR="${wp_cli_home}/cache" \
        /usr/local/bin/wp --path="${wordpress_root}" --no-color core download \
        --version="${WORDPRESS_VERSION}" --locale="${WORDPRESS_LOCALE}" --force; \
    for plugin_spec in \
        "litespeed-cache:${LITESPEED_CACHE_VERSION}:${LITESPEED_CACHE_SHA256}:litespeed-cache.php" \
        "redis-cache:${REDIS_CACHE_VERSION}:${REDIS_CACHE_SHA256}:redis-cache.php" \
        "elasticpress:${ELASTICPRESS_VERSION}:${ELASTICPRESS_SHA256}:elasticpress.php"; do \
        IFS=: read -r plugin_slug plugin_version plugin_sha256 plugin_main <<< "${plugin_spec}"; \
        plugin_archive="/tmp/${plugin_slug}.zip"; \
        curl --fail --silent --show-error --location \
            "https://downloads.wordpress.org/plugin/${plugin_slug}.${plugin_version}.zip" \
            --output "${plugin_archive}"; \
        printf '%s  %s\n' "${plugin_sha256}" "${plugin_archive}" | sha256sum --check --strict -; \
        rm -rf "${wordpress_root}/wp-content/plugins/${plugin_slug}"; \
        PLUGIN_ARCHIVE="${plugin_archive}" PLUGIN_DESTINATION="${wordpress_root}/wp-content/plugins" \
            /usr/local/bin/stack-php -r '$archive = new ZipArchive(); $opened = $archive->open((string) getenv("PLUGIN_ARCHIVE")); if ($opened !== true || ! $archive->extractTo((string) getenv("PLUGIN_DESTINATION"))) { fwrite(STDERR, "Impossibile estrarre il plugin.\n"); exit(1); } $archive->close();'; \
        [[ -f "${wordpress_root}/wp-content/plugins/${plugin_slug}/${plugin_main}" ]] || { \
            echo "File principale inatteso per ${plugin_slug}." >&2; \
            exit 1; \
        }; \
        rm -f "${plugin_archive}"; \
    done; \
    chown -R nobody:nogroup "${wordpress_root}"; \
    find "${wordpress_root}" -type d -exec chmod 0755 {} +; \
    find "${wordpress_root}" -type f -exec chmod 0644 {} +; \
    rm -rf "${wp_cli_home}"

FROM wordpress-immutable AS wordpress-immutable-suite
COPY --from=s3-module-builder /app /usr/local/share/wordpress-stack/s3-module
