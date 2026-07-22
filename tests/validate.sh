#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

log() {
    printf '[validate] %s\n' "$*"
}

find_php() {
    if [[ -n ${PHP_BIN:-} && -x ${PHP_BIN} ]]; then
        printf '%s' "${PHP_BIN}"
        return 0
    fi
    if command -v php >/dev/null 2>&1; then
        command -v php
        return 0
    fi
    return 1
}

main() {
    cd "${REPOSITORY_ROOT}"

    log "Sintassi Bash."
    bash -n docker/*.sh tests/*.sh
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck docker/*.sh tests/*.sh
    else
        log "ShellCheck non disponibile: controllo delegato alla CI."
    fi

    local php_command
    if php_command=$(find_php); then
        log "Lint PHP e manifest."
        while IFS= read -r php_file; do
            "${php_command}" -l "${php_file}" >/dev/null
        done < <(find docker -maxdepth 1 -type f -name '*.php' -print | sort)
        while IFS= read -r manifest; do
            "${php_command}" docker/manifest-tool.php validate "${manifest}" >/dev/null
        done < <(find config/wordpress-presets -type f -name '*.json' -print | sort)
    else
        log "PHP CLI non disponibile: lint PHP delegato alla build Docker/CI."
    fi

    log "Sintassi YAML."
    if command -v ruby >/dev/null 2>&1; then
        ruby -e 'require "yaml"; ARGV.each { |file| YAML.parse_file(file) }' \
            docker-compose.yml compose/*.yml .github/workflows/*.yml
    fi

    log "Rendering di ogni stack Compose."
    export WORDPRESS_DOMAIN=example.com
    export WORDPRESS_TITLE='Validation Site'
    export WORDPRESS_ADMIN_USER=admin
    export WORDPRESS_ADMIN_EMAIL=admin@example.com
    export WORDPRESS_ADMIN_PASSWORD=validation-placeholder-at-least-12
    export SERVICE_PASSWORD_MARIADB=validation-mariadb
    export SERVICE_PASSWORD_MYSQL=validation-mysql
    export SERVICE_PASSWORD_WORDPRESS=validation-wordpress
    export WORDPRESS_DB_HOST=db.example.internal:3306
    export WORDPRESS_DB_NAME=wordpress
    export WORDPRESS_DB_USER=wordpress
    export WORDPRESS_DB_PASSWORD=validation-external
    export WORDPRESS_REDIS_HOST=redis.example.internal

    local compose_file
    for compose_file in docker-compose.yml compose/minimal.yml compose/external.yml compose/mysql.yml compose/immutable.yml; do
        docker compose -f "${compose_file}" config --quiet
        COMPOSE_PROFILES=worker,backup docker compose -f "${compose_file}" config --quiet
    done

    git diff --check
    log "Validazione statica completata."
}

main "$@"
