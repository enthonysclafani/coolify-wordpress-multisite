#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_WORK_DIRECTORY="/tmp/wordpress-suite-backup"
readonly DATABASE_CONFIG="${BACKUP_WORK_DIRECTORY}/database.cnf"
readonly DATABASE_DUMP="${BACKUP_WORK_DIRECTORY}/wordpress.sql"
readonly LOCK_DIRECTORY="/tmp/wordpress-suite-backup.lock"

log() {
    printf '[backup] %s\n' "$*"
}

warn() {
    printf '[backup] ATTENZIONE: %s\n' "$*" >&2
}

die() {
    printf '[backup] ERRORE: %s\n' "$*" >&2
    exit 1
}

require_value() {
    local name=$1
    [[ -n ${!name:-} ]] || die "La variabile ${name} e obbligatoria."
}

normalise_boolean() {
    local value=${1,,}
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

cleanup_backup_state() {
    rm -rf -- "${LOCK_DIRECTORY}" "${BACKUP_WORK_DIRECTORY}"
}

split_database_host() {
    local value=$1
    DATABASE_HOST=${value}
    DATABASE_PORT=3306
    if [[ ${value} =~ ^\[([^]]+)](:([0-9]+))?$ ]]; then
        DATABASE_HOST=${BASH_REMATCH[1]}
        DATABASE_PORT=${BASH_REMATCH[3]:-3306}
    elif [[ ${value} =~ ^([^:]+):([0-9]+)$ ]]; then
        DATABASE_HOST=${BASH_REMATCH[1]}
        DATABASE_PORT=${BASH_REMATCH[2]}
    fi
}

prepare_repository() {
    if restic cat config >/dev/null 2>&1; then
        return 0
    fi

    local auto_init
    auto_init=$(normalise_boolean "${BACKUP_AUTO_INIT:-false}") || die "BACKUP_AUTO_INIT non e valido."
    [[ ${auto_init} == true ]] || die "Repository Restic non inizializzato; inizializzalo manualmente o abilita BACKUP_AUTO_INIT."
    log "Inizializzo il repository Restic."
    restic init
}

create_database_dump() {
    local -a dump_arguments=(
        "--defaults-extra-file=${DATABASE_CONFIG}"
        "--host=${DATABASE_HOST}"
        "--port=${DATABASE_PORT}"
        --single-transaction
        --routines
        --triggers
        --events
        --hex-blob
    )

    umask 077
    mkdir -p "${BACKUP_WORK_DIRECTORY}"
    printf '[client]\nuser=%s\npassword=%s\n' \
        "${WORDPRESS_DB_USER}" \
        "${WORDPRESS_DB_PASSWORD}" > "${DATABASE_CONFIG}"

    if [[ ${DATABASE_SSL} == true ]]; then
        dump_arguments+=(--ssl)
    else
        dump_arguments+=(--skip-ssl)
    fi
    mariadb-dump "${dump_arguments[@]}" "${WORDPRESS_DB_NAME}" > "${DATABASE_DUMP}"
}

run_backup() {
    local keep_daily=$1
    local keep_weekly=$2
    local keep_monthly=$3
    local run_number=$4
    local check_interval=$5

    if ! mkdir "${LOCK_DIRECTORY}" 2>/dev/null; then
        warn "Backup saltato: un'altra esecuzione detiene il lock."
        return 0
    fi

    create_database_dump
    restic backup \
        --tag coolify-wordpress-suite \
        --exclude '/data/wordpress/wp-content/cache' \
        --exclude '/data/wordpress/wp-content/litespeed' \
        /data/wordpress \
        "${DATABASE_DUMP}"
    restic forget \
        --tag coolify-wordpress-suite \
        "--keep-daily=${keep_daily}" \
        "--keep-weekly=${keep_weekly}" \
        "--keep-monthly=${keep_monthly}" \
        --prune

    if (( run_number % check_interval == 0 )); then
        restic check
    fi
    date -u +%FT%TZ > /tmp/wordpress-backup-last-success
    touch /tmp/wordpress-backup-ready
    cleanup_backup_state
    log "Backup e retention completati."
}

main() {
    local enabled interval keep_daily keep_weekly keep_monthly check_interval run_number=0
    enabled=$(normalise_boolean "${BACKUP_ENABLED:-true}") || die "BACKUP_ENABLED non e valido."
    DATABASE_SSL=$(normalise_boolean "${WORDPRESS_DB_SSL:-false}") || die "WORDPRESS_DB_SSL non e valido."
    [[ ${enabled} == true ]] || die "Il servizio backup e stato avviato con BACKUP_ENABLED=false."

    require_value RESTIC_REPOSITORY
    require_value RESTIC_PASSWORD
    require_value WORDPRESS_DB_HOST
    require_value WORDPRESS_DB_NAME
    require_value WORDPRESS_DB_USER
    require_value WORDPRESS_DB_PASSWORD

    interval=${BACKUP_INTERVAL_SECONDS:-86400}
    keep_daily=${BACKUP_KEEP_DAILY:-7}
    keep_weekly=${BACKUP_KEEP_WEEKLY:-4}
    keep_monthly=${BACKUP_KEEP_MONTHLY:-6}
    check_interval=${BACKUP_CHECK_INTERVAL_RUNS:-7}
    for value in "${interval}" "${keep_daily}" "${keep_weekly}" "${keep_monthly}" "${check_interval}"; do
        [[ ${value} =~ ^[0-9]+$ ]] || die "Intervalli e retention backup devono essere interi."
    done
    (( interval >= 3600 )) || die "BACKUP_INTERVAL_SECONDS deve essere almeno 3600."
    (( check_interval >= 1 )) || die "BACKUP_CHECK_INTERVAL_RUNS deve essere almeno 1."

    cleanup_backup_state
    rm -f /tmp/wordpress-backup-ready /tmp/wordpress-backup-last-success
    trap cleanup_backup_state EXIT
    split_database_host "${WORDPRESS_DB_HOST}"
    prepare_repository
    log "Servizio attivo; intervallo ${interval}s."

    while true; do
        run_number=$((run_number + 1))
        run_backup "${keep_daily}" "${keep_weekly}" "${keep_monthly}" "${run_number}" "${check_interval}"
        sleep "${interval}"
    done
}

main "$@"
