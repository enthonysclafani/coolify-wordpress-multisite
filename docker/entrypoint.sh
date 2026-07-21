#!/usr/bin/env bash
set -Eeuo pipefail

readonly PHP_BIN="/usr/local/lsws/lsphp83/bin/php"
readonly LSPHP_BIN="/usr/local/lsws/fcgi-bin/lsphp"
readonly PHP_TEMPLATE="/usr/local/share/wordpress-stack/custom.ini.template"
readonly PHP_RUNTIME_INI="/usr/local/lsws/lsphp83/etc/php/8.3/mods-available/99-wordpress-runtime.ini"
readonly OLS_BIN="/usr/local/lsws/bin/openlitespeed"

log() {
    printf '[entrypoint] %s\n' "$*"
}

warn() {
    printf '[entrypoint] ATTENZIONE: %s\n' "$*" >&2
}

die() {
    printf '[entrypoint] ERRORE: %s\n' "$*" >&2
    exit 1
}

# shellcheck disable=SC2317 # Funzione richiamata indirettamente da trap ERR.
on_error() {
    local exit_code=$?
    printf '[entrypoint] ERRORE alla riga %s (codice %s).\n' "${BASH_LINENO[0]}" "${exit_code}" >&2
    exit "${exit_code}"
}
trap on_error ERR

validate_ini_size() {
    local variable_name=$1
    local value=$2
    [[ ${value} =~ ^[1-9][0-9]*[KMG]?$ ]] || die "${variable_name} deve essere un valore PHP valido, per esempio 512M."
}

render_php_configuration() {
    local upload_max=${PHP_UPLOAD_MAX_FILESIZE:-1024M}
    local post_max=${PHP_POST_MAX_SIZE:-1024M}
    local memory_limit=${PHP_MEMORY_LIMIT:-512M}
    local timezone=${WORDPRESS_TIMEZONE:-Europe/Rome}

    validate_ini_size PHP_UPLOAD_MAX_FILESIZE "${upload_max}"
    validate_ini_size PHP_POST_MAX_SIZE "${post_max}"
    validate_ini_size PHP_MEMORY_LIMIT "${memory_limit}"

    if ! TZ_VALUE="${timezone}" "${PHP_BIN}" -r 'exit(in_array(getenv("TZ_VALUE"), DateTimeZone::listIdentifiers(), true) ? 0 : 1);'; then
        die "WORDPRESS_TIMEZONE non è un identificatore timezone PHP valido."
    fi

    sed \
        -e "s|@UPLOAD_MAX_FILESIZE@|${upload_max}|g" \
        -e "s|@POST_MAX_SIZE@|${post_max}|g" \
        -e "s|@MEMORY_LIMIT@|${memory_limit}|g" \
        -e "s|@TIMEZONE@|${timezone}|g" \
        "${PHP_TEMPLATE}" > "${PHP_RUNTIME_INI}"
    chmod 0644 "${PHP_RUNTIME_INI}"
}

wait_for_lsphp() {
    local _
    for _ in {1..30}; do
        # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere variabili shell.
        if "${PHP_BIN}" -r '
            $socket = @fsockopen("127.0.0.1", 9000, $errorCode, $errorMessage, 0.2);
            if (is_resource($socket)) {
                fclose($socket);
                exit(0);
            }
            exit(1);
        '; then
            return 0
        fi
        sleep 1
    done
    die "LSPHP non ha aperto il listener LSAPI 127.0.0.1:9000."
}

stop_processes() {
    local exit_code=${1:-0}
    trap - ERR INT TERM
    for process_id in "${OLS_PID:-}" "${LSPHP_PID:-}" "${LOG_TAIL_PID:-}"; do
        if [[ -n ${process_id} ]] && kill -0 "${process_id}" 2>/dev/null; then
            kill -TERM "${process_id}" 2>/dev/null || true
        fi
    done
    wait "${OLS_PID:-}" "${LSPHP_PID:-}" "${LOG_TAIL_PID:-}" 2>/dev/null || true
    exit "${exit_code}"
}

main() {
    umask 027
    log "Genero la configurazione PHP runtime."
    render_php_configuration

    log "Avvio il bootstrap idempotente di WordPress."
    /usr/local/bin/bootstrap-wordpress

    install -d -m 0755 -o nobody -g nogroup /tmp/lshttpd
    install -m 0640 -o nobody -g nogroup /dev/null /usr/local/lsws/logs/error.log
    install -m 0644 -o nobody -g nogroup /dev/null /usr/local/lsws/logs/access.log
    tail -n 0 -F /usr/local/lsws/logs/error.log /usr/local/lsws/logs/access.log &
    LOG_TAIL_PID=$!

    log "Avvio LSPHP come server LSAPI locale."
    runuser -u nobody -- env \
        PHP_LSAPI_CHILDREN=10 \
        LSAPI_CHILDREN=10 \
        LSAPI_AVOID_FORK=200M \
        "${LSPHP_BIN}" -b 127.0.0.1:9000 &
    LSPHP_PID=$!
    wait_for_lsphp

    log "Avvio OpenLiteSpeed in modalità foreground sulla porta 7080."
    "${OLS_BIN}" -d &
    OLS_PID=$!
    trap 'stop_processes 0' INT TERM

    set +e
    wait -n "${OLS_PID}" "${LSPHP_PID}"
    exit_code=$?
    set -e
    [[ ${exit_code} -eq 0 ]] || warn "OpenLiteSpeed o LSPHP si è arrestato con codice ${exit_code}."
    stop_processes "${exit_code}"
}

main "$@"
