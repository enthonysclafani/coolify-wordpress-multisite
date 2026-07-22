#!/usr/bin/env bash
set -Eeuo pipefail

readonly PHP_BIN="/usr/local/bin/stack-php"
readonly LSPHP_BIN="/usr/local/lsws/fcgi-bin/lsphp"
readonly PHP_TEMPLATE="/usr/local/share/wordpress-stack/custom.ini.template"
readonly OPCACHE_TEMPLATE="/usr/local/share/wordpress-stack/opcache.ini.template"
readonly OLS_TEMPLATE="/usr/local/share/wordpress-stack/httpd_config.conf.template"
readonly OLS_CONFIG="/usr/local/lsws/conf/httpd_config.conf"
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

# shellcheck disable=SC2329 # Funzione richiamata indirettamente da trap ERR.
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

validate_integer_range() {
    local variable_name=$1
    local value=$2
    local minimum=$3
    local maximum=$4
    [[ ${value} =~ ^[0-9]+$ && ${value} -ge ${minimum} && ${value} -le ${maximum} ]] || \
        die "${variable_name} deve essere un intero tra ${minimum} e ${maximum}."
}

resolve_runtime_profile() {
    local profile=${WORDPRESS_RUNTIME_PROFILE:-balanced}
    case "${profile}" in
        small)
            PROFILE_LSAPI_CHILDREN=4
            PROFILE_LSAPI_AVOID_FORK=64M
            PROFILE_OLS_MAX_CONNECTIONS=2000
            PROFILE_OPCACHE_MEMORY=128
            PROFILE_OPCACHE_STRINGS=8
            PROFILE_OPCACHE_FILES=10000
            ;;
        balanced)
            PROFILE_LSAPI_CHILDREN=10
            PROFILE_LSAPI_AVOID_FORK=200M
            PROFILE_OLS_MAX_CONNECTIONS=10000
            PROFILE_OPCACHE_MEMORY=192
            PROFILE_OPCACHE_STRINGS=16
            PROFILE_OPCACHE_FILES=20000
            ;;
        large)
            PROFILE_LSAPI_CHILDREN=24
            PROFILE_LSAPI_AVOID_FORK=512M
            PROFILE_OLS_MAX_CONNECTIONS=20000
            PROFILE_OPCACHE_MEMORY=384
            PROFILE_OPCACHE_STRINGS=32
            PROFILE_OPCACHE_FILES=40000
            ;;
        *) die "WORDPRESS_RUNTIME_PROFILE deve essere small, balanced oppure large." ;;
    esac
    RUNTIME_PROFILE=${profile}
}

resolve_php_scan_directory() {
    local directory
    directory=$("${PHP_BIN}" --ini | sed -n 's/^Scan for additional .ini files in: //p' | head -n 1)
    [[ -n ${directory} && ${directory} != '(none)' && -d ${directory} ]] || \
        die "Directory di scansione PHP ini non individuata."
    printf '%s' "${directory}"
}

render_runtime_configuration() {
    local upload_max=${PHP_UPLOAD_MAX_FILESIZE:-1024M}
    local post_max=${PHP_POST_MAX_SIZE:-1024M}
    local memory_limit=${PHP_MEMORY_LIMIT:-512M}
    local timezone=${WORDPRESS_TIMEZONE:-Europe/Rome}
    local max_execution_time=${PHP_MAX_EXECUTION_TIME:-300}
    local max_input_time=${PHP_MAX_INPUT_TIME:-300}
    local max_input_vars=${PHP_MAX_INPUT_VARS:-5000}
    local lsapi_children=${PHP_LSAPI_CHILDREN:-${PROFILE_LSAPI_CHILDREN}}
    local lsapi_avoid_fork=${LSAPI_AVOID_FORK:-${PROFILE_LSAPI_AVOID_FORK}}
    local ols_max_connections=${OLS_MAX_CONNECTIONS:-${PROFILE_OLS_MAX_CONNECTIONS}}
    local ols_keep_alive_timeout=${OLS_KEEP_ALIVE_TIMEOUT:-5}
    local ols_max_request_body_size=${OLS_MAX_REQUEST_BODY_SIZE:-2047M}
    local opcache_memory=${PHP_OPCACHE_MEMORY_CONSUMPTION:-${PROFILE_OPCACHE_MEMORY}}
    local opcache_strings=${PHP_OPCACHE_INTERNED_STRINGS_BUFFER:-${PROFILE_OPCACHE_STRINGS}}
    local opcache_files=${PHP_OPCACHE_MAX_ACCELERATED_FILES:-${PROFILE_OPCACHE_FILES}}
    local opcache_validate=${PHP_OPCACHE_VALIDATE_TIMESTAMPS:-1}
    local opcache_revalidate=${PHP_OPCACHE_REVALIDATE_FREQ:-2}
    local php_scan_directory php_runtime_ini opcache_runtime_ini

    for size_pair in \
        "PHP_UPLOAD_MAX_FILESIZE:${upload_max}" \
        "PHP_POST_MAX_SIZE:${post_max}" \
        "PHP_MEMORY_LIMIT:${memory_limit}" \
        "LSAPI_AVOID_FORK:${lsapi_avoid_fork}" \
        "OLS_MAX_REQUEST_BODY_SIZE:${ols_max_request_body_size}"; do
        validate_ini_size "${size_pair%%:*}" "${size_pair#*:}"
    done
    validate_integer_range PHP_MAX_EXECUTION_TIME "${max_execution_time}" 1 86400
    validate_integer_range PHP_MAX_INPUT_TIME "${max_input_time}" 1 86400
    validate_integer_range PHP_MAX_INPUT_VARS "${max_input_vars}" 100 1000000
    validate_integer_range PHP_LSAPI_CHILDREN "${lsapi_children}" 1 256
    validate_integer_range OLS_MAX_CONNECTIONS "${ols_max_connections}" 100 1000000
    validate_integer_range OLS_KEEP_ALIVE_TIMEOUT "${ols_keep_alive_timeout}" 1 300
    validate_integer_range PHP_OPCACHE_MEMORY_CONSUMPTION "${opcache_memory}" 32 4096
    validate_integer_range PHP_OPCACHE_INTERNED_STRINGS_BUFFER "${opcache_strings}" 4 256
    validate_integer_range PHP_OPCACHE_MAX_ACCELERATED_FILES "${opcache_files}" 1000 1000000
    validate_integer_range PHP_OPCACHE_VALIDATE_TIMESTAMPS "${opcache_validate}" 0 1
    validate_integer_range PHP_OPCACHE_REVALIDATE_FREQ "${opcache_revalidate}" 0 3600

    if ! TZ_VALUE="${timezone}" "${PHP_BIN}" -r 'exit(in_array(getenv("TZ_VALUE"), DateTimeZone::listIdentifiers(), true) ? 0 : 1);'; then
        die "WORDPRESS_TIMEZONE non e un identificatore timezone PHP valido."
    fi

    php_scan_directory=$(resolve_php_scan_directory)
    php_runtime_ini="${php_scan_directory}/99-wordpress-runtime.ini"
    opcache_runtime_ini="${php_scan_directory}/99-wordpress-opcache.ini"

    sed \
        -e "s|@UPLOAD_MAX_FILESIZE@|${upload_max}|g" \
        -e "s|@POST_MAX_SIZE@|${post_max}|g" \
        -e "s|@MEMORY_LIMIT@|${memory_limit}|g" \
        -e "s|@MAX_EXECUTION_TIME@|${max_execution_time}|g" \
        -e "s|@MAX_INPUT_TIME@|${max_input_time}|g" \
        -e "s|@MAX_INPUT_VARS@|${max_input_vars}|g" \
        -e "s|@TIMEZONE@|${timezone}|g" \
        "${PHP_TEMPLATE}" > "${php_runtime_ini}"
    sed \
        -e "s|@OPCACHE_MEMORY_CONSUMPTION@|${opcache_memory}|g" \
        -e "s|@OPCACHE_INTERNED_STRINGS_BUFFER@|${opcache_strings}|g" \
        -e "s|@OPCACHE_MAX_ACCELERATED_FILES@|${opcache_files}|g" \
        -e "s|@OPCACHE_VALIDATE_TIMESTAMPS@|${opcache_validate}|g" \
        -e "s|@OPCACHE_REVALIDATE_FREQ@|${opcache_revalidate}|g" \
        "${OPCACHE_TEMPLATE}" > "${opcache_runtime_ini}"
    sed \
        -e "s|@OLS_MAX_CONNECTIONS@|${ols_max_connections}|g" \
        -e "s|@OLS_KEEP_ALIVE_TIMEOUT@|${ols_keep_alive_timeout}|g" \
        -e "s|@OLS_MAX_REQUEST_BODY_SIZE@|${ols_max_request_body_size}|g" \
        -e "s|@LSAPI_CHILDREN@|${lsapi_children}|g" \
        -e "s|@LSAPI_AVOID_FORK@|${lsapi_avoid_fork}|g" \
        "${OLS_TEMPLATE}" > "${OLS_CONFIG}"
    chmod 0644 "${php_runtime_ini}" "${opcache_runtime_ini}"
    chmod 0640 "${OLS_CONFIG}"

    RUNTIME_LSAPI_CHILDREN=${lsapi_children}
    RUNTIME_LSAPI_AVOID_FORK=${lsapi_avoid_fork}
}

wait_for_lsphp() {
    local _
    for _ in {1..30}; do
        # shellcheck disable=SC2016 # Il frammento e PHP, non deve espandere $socket nella shell.
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
    resolve_runtime_profile
    log "Genero la configurazione runtime dal profilo ${RUNTIME_PROFILE}."
    render_runtime_configuration
    "${OLS_BIN}" -t

    log "Avvio il bootstrap idempotente di WordPress."
    /usr/local/bin/bootstrap-wordpress

    install -d -m 0755 -o nobody -g nogroup /tmp/lshttpd
    install -m 0640 -o nobody -g nogroup /dev/null /usr/local/lsws/logs/error.log
    install -m 0644 -o nobody -g nogroup /dev/null /usr/local/lsws/logs/access.log
    tail -n 0 -F /usr/local/lsws/logs/error.log /usr/local/lsws/logs/access.log &
    LOG_TAIL_PID=$!

    log "Avvio LSPHP con ${RUNTIME_LSAPI_CHILDREN} processi massimi."
    runuser -u nobody -- env \
        "PHP_LSAPI_CHILDREN=${RUNTIME_LSAPI_CHILDREN}" \
        "LSAPI_CHILDREN=${RUNTIME_LSAPI_CHILDREN}" \
        "LSAPI_AVOID_FORK=${RUNTIME_LSAPI_AVOID_FORK}" \
        "${LSPHP_BIN}" -b 127.0.0.1:9000 &
    LSPHP_PID=$!
    wait_for_lsphp

    log "Avvio OpenLiteSpeed in modalita foreground sulla porta 7080."
    "${OLS_BIN}" -d &
    OLS_PID=$!
    trap 'stop_processes 0' INT TERM

    set +e
    wait -n "${OLS_PID}" "${LSPHP_PID}"
    exit_code=$?
    set -e
    [[ ${exit_code} -eq 0 ]] || warn "OpenLiteSpeed o LSPHP si e arrestato con codice ${exit_code}."
    stop_processes "${exit_code}"
}

main "$@"
