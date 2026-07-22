#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORDPRESS_ROOT="/var/www/vhosts/localhost/html"
readonly WP_BIN="/usr/local/bin/wp"
readonly LOCK_FILE="/tmp/wordpress-cron.lock"
readonly WP_CLI_HOME="/tmp/wordpress-cron-wp-cli"

log() {
    printf '[cron] %s\n' "$*"
}

warn() {
    printf '[cron] ATTENZIONE: %s\n' "$*" >&2
}

normalise_boolean() {
    local variable_name=$1
    local value=${2,,}
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) warn "${variable_name} non è valido."; return 1 ;;
    esac
}

wp_cli() {
    if [[ $(id -u) -eq 0 ]]; then
        runuser -u nobody -- env HOME="${WP_CLI_HOME}" WP_CLI_CACHE_DIR="${WP_CLI_HOME}/cache" \
            "${WP_BIN}" --path="${WORDPRESS_ROOT}" --no-color "$@"
    else
        HOME="${WP_CLI_HOME}" WP_CLI_CACHE_DIR="${WP_CLI_HOME}/cache" \
            "${WP_BIN}" --path="${WORDPRESS_ROOT}" --no-color "$@"
    fi
}

bootstrap_cli_container_if_needed() {
    local should_bootstrap
    should_bootstrap=$(normalise_boolean WORDPRESS_CLI_BOOTSTRAP "${WORDPRESS_CLI_BOOTSTRAP:-false}") || exit 1
    if [[ ! -f ${WORDPRESS_ROOT}/wp-config.php && ${should_bootstrap} == true ]]; then
        [[ $(id -u) -eq 0 ]] || {
            warn "WORDPRESS_CLI_BOOTSTRAP richiede che il container cron parta come root."
            exit 1
        }
        log "Preparo il filesystem immutabile del runner cron."
        /usr/local/bin/bootstrap-wordpress
    fi
}

main() {
    local enabled interval
    enabled=$(normalise_boolean WORDPRESS_DISABLE_WP_CRON "${WORDPRESS_DISABLE_WP_CRON:-true}") || exit 1
    interval=${WORDPRESS_CRON_INTERVAL_SECONDS:-300}
    [[ ${interval} =~ ^[0-9]+$ && ${interval} -ge 60 ]] || {
        warn "WORDPRESS_CRON_INTERVAL_SECONDS deve essere un intero di almeno 60 secondi."
        exit 1
    }

    if [[ ${enabled} != true ]]; then
        log "WP-Cron nativo è abilitato; il runner separato resta inattivo."
        exec sleep infinity
    fi

    install -d -m 0755 "${WP_CLI_HOME}" "${WP_CLI_HOME}/cache"
    if [[ $(id -u) -eq 0 ]]; then
        chown -R nobody:nogroup "${WP_CLI_HOME}"
    fi
    bootstrap_cli_container_if_needed

    log "Runner attivo con intervallo di ${interval} secondi."
    while true; do
        if [[ -f ${WORDPRESS_ROOT}/wp-config.php ]]; then
            set +e
            (
                flock --nonblock 9 || exit 75
                wp_cli cron event run --due-now --quiet
            ) 9>"${LOCK_FILE}"
            cycle_status=$?
            set -e
            case "${cycle_status}" in
                0) log "Eventi WP-Cron scaduti elaborati." ;;
                75) warn "Esecuzione saltata: un lock impedisce esecuzioni concorrenti." ;;
                *) warn "Esecuzione WP-Cron fallita (codice ${cycle_status})." ;;
            esac
        else
            log "WordPress non è ancora inizializzato; attendo."
        fi
        sleep "${interval}"
    done
}

main "$@"
