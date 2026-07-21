FROM litespeedtech/openlitespeed:1.8.5-lsphp83

ARG WP_CLI_VERSION=2.12.0

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -Eeuo pipefail; \
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
    /usr/local/lsws/lsphp83/bin/php /usr/local/bin/wp --info >/dev/null

COPY openlitespeed/httpd_config.conf /usr/local/lsws/conf/httpd_config.conf
COPY openlitespeed/vhosts/wordpress/vhconf.conf /usr/local/lsws/conf/vhosts/wordpress/vhconf.conf
COPY openlitespeed/vhosts/wordpress/.htaccess.template /usr/local/share/wordpress-stack/.htaccess.template
COPY docker/php/custom.ini.template /usr/local/share/wordpress-stack/custom.ini.template
COPY docker/php/opcache.ini /usr/local/lsws/lsphp83/etc/php/8.3/mods-available/99-wordpress-opcache.ini
COPY docker/entrypoint.sh /usr/local/bin/wordpress-entrypoint
COPY docker/bootstrap-wordpress.sh /usr/local/bin/bootstrap-wordpress
COPY docker/healthcheck.sh /usr/local/bin/wordpress-healthcheck
COPY docker/cron.sh /usr/local/bin/wordpress-cron
COPY docker/manage-htaccess.php /usr/local/lib/wordpress-stack/manage-htaccess.php
COPY docker/manage-wp-config.php /usr/local/lib/wordpress-stack/manage-wp-config.php

RUN set -Eeuo pipefail; \
    chmod 0755 \
        /usr/local/bin/wordpress-entrypoint \
        /usr/local/bin/bootstrap-wordpress \
        /usr/local/bin/wordpress-healthcheck \
        /usr/local/bin/wordpress-cron; \
    chmod 0644 \
        /usr/local/lib/wordpress-stack/manage-htaccess.php \
        /usr/local/lib/wordpress-stack/manage-wp-config.php \
        /usr/local/share/wordpress-stack/.htaccess.template \
        /usr/local/share/wordpress-stack/custom.ini.template \
        /usr/local/lsws/lsphp83/etc/php/8.3/mods-available/99-wordpress-opcache.ini; \
    chown -R lsadm:lsadm /usr/local/lsws/conf; \
    find /usr/local/lsws/conf -type d -exec chmod 0750 {} +; \
    find /usr/local/lsws/conf -type f -exec chmod 0640 {} +; \
    required_extensions=(curl exif gd imagick intl mbstring mysqli "zend opcache" redis zip); \
    loaded_extensions="$(/usr/local/lsws/lsphp83/bin/php -m | tr '[:upper:]' '[:lower:]')"; \
    for extension in "${required_extensions[@]}"; do \
        grep -qx "${extension}" <<<"${loaded_extensions}" || { echo "Estensione PHP richiesta assente: ${extension}" >&2; exit 1; }; \
    done; \
    /usr/local/lsws/lsphp83/bin/php -l /usr/local/lib/wordpress-stack/manage-htaccess.php >/dev/null; \
    /usr/local/lsws/lsphp83/bin/php -l /usr/local/lib/wordpress-stack/manage-wp-config.php >/dev/null; \
    /usr/local/lsws/bin/openlitespeed -t

WORKDIR /var/www/vhosts/localhost/html

EXPOSE 7080

ENTRYPOINT ["/usr/local/bin/wordpress-entrypoint"]
