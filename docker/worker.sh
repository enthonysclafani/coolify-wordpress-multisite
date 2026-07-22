#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORDPRESS_ROOT="/var/www/vhosts/localhost/html"
readonly WP_BIN="/usr/local/bin/wp"
readonly LOCK_FILE="/tmp/wordpress-worker.lock"
readonly WP_CLI_HOME="/tmp/wordpress-worker-wp-cli"

log() {
    printf '[worker] %s\n' "$*"
}

warn() {
    printf '[worker] ATTENZIONE: %s\n' "$*" >&2
}

normalise_boolean() {
    local value=${1,,}
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) return 1 ;;
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
    should_bootstrap=$(normalise_boolean "${WORDPRESS_CLI_BOOTSTRAP:-false}") || {
        warn "WORDPRESS_CLI_BOOTSTRAP non e valido."
        exit 1
    }
    if [[ ! -f ${WORDPRESS_ROOT}/wp-config.php && ${should_bootstrap} == true ]]; then
        [[ $(id -u) -eq 0 ]] || {
            warn "WORDPRESS_CLI_BOOTSTRAP richiede che il worker parta come root."
            exit 1
        }
        log "Preparo il filesystem immutabile del worker."
        /usr/local/bin/bootstrap-wordpress
    fi
}

run_for_site() {
    local site_url=$1
    local batch_size=$2
    local batches=$3
    local -a command=(--url="${site_url}" action-scheduler run "--batch-size=${batch_size}" "--batches=${batches}")

    if [[ -n ${WORDPRESS_ACTION_SCHEDULER_GROUP:-} ]]; then
        command+=("--group=${WORDPRESS_ACTION_SCHEDULER_GROUP}")
    fi
    if [[ -n ${WORDPRESS_ACTION_SCHEDULER_HOOKS:-} ]]; then
        command+=("--hooks=${WORDPRESS_ACTION_SCHEDULER_HOOKS}")
    fi

    if wp_cli --url="${site_url}" cli has-command action-scheduler >/dev/null 2>&1; then
        wp_cli "${command[@]}"
    else
        warn "Action Scheduler non e disponibile su ${site_url}; esecuzione saltata."
    fi
}

run_worker_cycle() {
    local batch_size=$1
    local batches=$2
    local site_url

    if wp_cli core is-installed --network >/dev/null 2>&1; then
        while IFS= read -r site_url; do
            [[ -n ${site_url} ]] && run_for_site "${site_url}" "${batch_size}" "${batches}"
        done < <(wp_cli site list --field=url --skip-plugins --skip-themes)
    else
        site_url=$(wp_cli option get home --skip-plugins --skip-themes)
        run_for_site "${site_url}" "${batch_size}" "${batches}"
    fi
}

main() {
    local mode interval batch_size batches
    mode=${WORDPRESS_WORKER_MODE:-action-scheduler}
    interval=${WORDPRESS_WORKER_INTERVAL_SECONDS:-30}
    batch_size=${WORDPRESS_ACTION_SCHEDULER_BATCH_SIZE:-100}
    batches=${WORDPRESS_ACTION_SCHEDULER_BATCHES:-1}

    [[ ${mode} == action-scheduler ]] || {
        warn "WORDPRESS_WORKER_MODE deve essere action-scheduler."
        exit 1
    }
    [[ ${interval} =~ ^[0-9]+$ && ${interval} -ge 10 ]] || {
        warn "WORDPRESS_WORKER_INTERVAL_SECONDS deve essere almeno 10."
        exit 1
    }
    [[ ${batch_size} =~ ^[0-9]+$ && ${batch_size} -ge 1 && ${batch_size} -le 1000 ]] || {
        warn "WORDPRESS_ACTION_SCHEDULER_BATCH_SIZE deve essere tra 1 e 1000."
        exit 1
    }
    [[ ${batches} =~ ^[0-9]+$ && ${batches} -le 1000 ]] || {
        warn "WORDPRESS_ACTION_SCHEDULER_BATCHES deve essere tra 0 e 1000."
        exit 1
    }
    [[ ${WORDPRESS_ACTION_SCHEDULER_GROUP:-} =~ ^[A-Za-z0-9._:-]*$ ]] || {
        warn "WORDPRESS_ACTION_SCHEDULER_GROUP contiene caratteri non validi."
        exit 1
    }
    [[ ${WORDPRESS_ACTION_SCHEDULER_HOOKS:-} =~ ^[A-Za-z0-9._,:-]*$ ]] || {
        warn "WORDPRESS_ACTION_SCHEDULER_HOOKS contiene caratteri non validi."
        exit 1
    }

    install -d -m 0755 "${WP_CLI_HOME}" "${WP_CLI_HOME}/cache"
    if [[ $(id -u) -eq 0 ]]; then
        chown -R nobody:nogroup "${WP_CLI_HOME}"
    fi
    bootstrap_cli_container_if_needed
    [[ -f ${WORDPRESS_ROOT}/wp-config.php ]] || {
        warn "wp-config.php non disponibile."
        exit 1
    }

    touch /tmp/wordpress-worker-ready
    log "Worker Action Scheduler attivo: batch ${batch_size}, cicli ${batches}, intervallo ${interval}s."
    while true; do
        set +e
        (
            flock --nonblock 9 || exit 75
            run_worker_cycle "${batch_size}" "${batches}"
        ) 9>"${LOCK_FILE}"
        cycle_status=$?
        set -e
        case "${cycle_status}" in
            0) log "Ciclo Action Scheduler completato." ;;
            75) warn "Ciclo saltato: worker gia in esecuzione." ;;
            *) warn "Ciclo Action Scheduler non riuscito (codice ${cycle_status})." ;;
        esac
        sleep "${interval}"
    done
}

main "$@"
