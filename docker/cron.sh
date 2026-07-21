#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORDPRESS_ROOT="/var/www/vhosts/localhost/html"
readonly WP_BIN="/usr/local/bin/wp"
readonly LOCK_FILE="/tmp/wordpress-cron.lock"

log() {
    printf '[cron] %s\n' "$*"
}

warn() {
    printf '[cron] ATTENZIONE: %s\n' "$*" >&2
}

normalise_boolean() {
    local value=${1,,}
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) warn "WORDPRESS_DISABLE_WP_CRON non è valido; il runner resta inattivo."; printf 'false' ;;
    esac
}

main() {
    local enabled interval
    enabled=$(normalise_boolean "${WORDPRESS_DISABLE_WP_CRON:-true}")
    interval=${WORDPRESS_CRON_INTERVAL_SECONDS:-300}
    [[ ${interval} =~ ^[0-9]+$ && ${interval} -ge 60 ]] || {
        warn "WORDPRESS_CRON_INTERVAL_SECONDS deve essere un intero di almeno 60 secondi."
        exit 1
    }

    if [[ ${enabled} != true ]]; then
        log "WP-Cron nativo è abilitato; il runner separato resta inattivo."
        exec sleep infinity
    fi

    log "Runner attivo con intervallo di ${interval} secondi."
    while true; do
        if [[ -f ${WORDPRESS_ROOT}/wp-config.php ]]; then
            if flock --nonblock "${LOCK_FILE}" \
                "${WP_BIN}" --path="${WORDPRESS_ROOT}" --no-color cron event run --due-now --quiet; then
                log "Eventi WP-Cron scaduti elaborati."
            else
                warn "Esecuzione saltata o fallita; un lock impedisce esecuzioni concorrenti."
            fi
        else
            log "WordPress non è ancora inizializzato; attendo."
        fi
        sleep "${interval}"
    done
}

main "$@"
