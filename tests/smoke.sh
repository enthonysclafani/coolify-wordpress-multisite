#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY_ROOT

log() {
    printf '[smoke] %s\n' "$*"
}

die() {
    printf '[smoke] ERRORE: %s\n' "$*" >&2
    exit 1
}

main() {
    local compose_file=${1:-docker-compose.yml}
    local topology=${2:-subdirectory}
    local profiles=${3:-}
    local run_suffix=${GITHUB_RUN_ID:-local}
    local safe_name safe_profiles project multisite=true preset=standard
    local -a compose_command=(docker compose)

    if command -v docker-compose >/dev/null 2>&1; then
        compose_command=(docker-compose)
    fi

    case "${topology}" in
        single) multisite=false ;;
        subdirectory|subdomain) ;;
        *) die "Topologia non valida: ${topology}." ;;
    esac
    [[ -f ${REPOSITORY_ROOT}/${compose_file} ]] || die "Compose non trovato: ${compose_file}."

    safe_name=${compose_file//[^A-Za-z0-9]/-}
    safe_profiles=${profiles//[^A-Za-z0-9]/-}
    [[ ${profiles} =~ ^(worker|backup|worker,backup|backup,worker)?$ ]] || die "Profili smoke non validi: ${profiles}."
    project="cwps-${safe_name}-${topology}-${safe_profiles:-base}-${run_suffix}"
    project=$(printf '%s' "${project}" | tr '[:upper:]' '[:lower:]')
    project=${project:0:63}
    [[ ${project} =~ ^[a-z0-9][a-z0-9_-]+$ ]] || die "Nome progetto smoke non sicuro."

    [[ ${compose_file} == compose/minimal.yml ]] && preset=minimal
    [[ ${compose_file} == compose/immutable.yml ]] && preset=immutable

    export WORDPRESS_DOMAIN=example.test
    export WORDPRESS_TITLE='Smoke Test'
    export WORDPRESS_ADMIN_USER=smokeadmin
    export WORDPRESS_ADMIN_EMAIL=admin@example.test
    export WORDPRESS_ADMIN_PASSWORD=smoke-placeholder-at-least-12
    export WORDPRESS_ENABLE_MULTISITE=${multisite}
    export WORDPRESS_MULTISITE_MODE=${topology/single/subdirectory}
    export WORDPRESS_BOOTSTRAP_PRESET=${preset}
    export SERVICE_PASSWORD_MARIADB=smoke-mariadb-root
    export SERVICE_PASSWORD_MYSQL=smoke-mysql-root
    export SERVICE_PASSWORD_WORDPRESS=smoke-wordpress-db
    export COMPOSE_PROFILES=${profiles}
    if [[ ${profiles} == *backup* ]]; then
        export BACKUP_AUTO_INIT=true
        export RESTIC_PASSWORD=smoke-restic-secret
    fi

    cleanup() {
        log "Teardown del solo progetto ${project}."
        "${compose_command[@]}" -p "${project}" -f "${compose_file}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    cd "${REPOSITORY_ROOT}"
    log "Avvio ${compose_file}, topologia ${topology}."
    "${compose_command[@]}" -p "${project}" -f "${compose_file}" up -d --build --wait --wait-timeout 600
    "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T --user 65534:65534 wordpress \
        wp --path=/var/www/vhosts/localhost/html --no-color core is-installed
    if [[ ${multisite} == true ]]; then
        "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T --user 65534:65534 wordpress \
            wp --path=/var/www/vhosts/localhost/html --no-color core is-installed --network
    fi
    "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T --user 65534:65534 wordpress \
        wp --path=/var/www/vhosts/localhost/html --no-color option get home
    "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T wordpress \
        /usr/local/bin/wordpress-healthcheck
    if [[ ${profiles} == *worker* ]]; then
        "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T worker \
            test -f /tmp/wordpress-worker-ready
    fi
    if [[ ${profiles} == *backup* ]]; then
        "${compose_command[@]}" -p "${project}" -f "${compose_file}" exec -T backup \
            restic snapshots --tag coolify-wordpress-suite --json
    fi
    log "Smoke test completato."
    cleanup
    trap - EXIT
}

main "$@"
