#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORDPRESS_ROOT="/var/www/vhosts/localhost/html"
readonly PHP_BIN="/usr/local/lsws/lsphp83/bin/php"
readonly WP_BIN="/usr/local/bin/wp"
readonly WEB_USER="nobody"
readonly WEB_GROUP="nogroup"
readonly WP_CLI_HOME="/tmp/wordpress-wp-cli"
readonly HTACCESS_TEMPLATE_DIRECTORY="/usr/local/share/wordpress-stack"
readonly MULTISITE_HTTPS_MU_PLUGIN_SOURCE="/usr/local/share/wordpress-stack/coolify-multisite-https.php"
readonly LITESPEED_CACHE_VERSION="7.8.1"
readonly REDIS_CACHE_VERSION="2.8.0"

log() {
    printf '[bootstrap] %s\n' "$*"
}

warn() {
    printf '[bootstrap] ATTENZIONE: %s\n' "$*" >&2
}

die() {
    printf '[bootstrap] ERRORE: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    printf '[bootstrap] ERRORE alla riga %s (codice %s).\n' "${BASH_LINENO[0]}" "${exit_code}" >&2
    exit "${exit_code}"
}
trap on_error ERR

require_value() {
    local variable_name=$1
    [[ -n ${!variable_name:-} ]] || die "La variabile ${variable_name} è obbligatoria."
}

normalise_boolean() {
    local variable_name=$1
    local value=${2,,}
    case "${value}" in
        true|1|yes|on) printf 'true' ;;
        false|0|no|off) printf 'false' ;;
        *) die "${variable_name} deve essere true oppure false." ;;
    esac
}

normalise_multisite_mode() {
    local value=${1,,}
    case "${value}" in
        subdirectory|subdomain) printf '%s' "${value}" ;;
        *) die "WORDPRESS_MULTISITE_MODE deve essere subdirectory oppure subdomain." ;;
    esac
}

validate_php_size() {
    local variable_name=$1
    local value=$2
    [[ ${value} =~ ^[1-9][0-9]*[KMG]?$ ]] || die "${variable_name} deve essere un valore PHP valido, per esempio 256M."
}

normalise_domain() {
    local raw_value=$1
    local host

    [[ ${raw_value} != *[[:space:]]* ]] || die "WORDPRESS_DOMAIN non può contenere spazi."
    case "${raw_value}" in
        http://*) host=${raw_value#http://} ;;
        https://*) host=${raw_value#https://} ;;
        *://*) die "WORDPRESS_DOMAIN accetta soltanto gli schemi http e https." ;;
        *) host=${raw_value} ;;
    esac

    host=${host%/}
    [[ -n ${host} ]] || die "WORDPRESS_DOMAIN è vuoto."
    [[ ${host} != */* ]] || die "WORDPRESS_DOMAIN non può contenere un path."
    [[ ${host} != *\?* && ${host} != *\#* && ${host} != *@* && ${host} != *:* ]] || \
        die "WORDPRESS_DOMAIN non può contenere query, fragment, credenziali o porte."
    [[ ${#host} -le 253 ]] || die "WORDPRESS_DOMAIN supera 253 caratteri."

    host=${host,,}
    local label
    local -a labels
    IFS='.' read -r -a labels <<< "${host}"
    [[ ${#labels[@]} -ge 2 ]] || die "WORDPRESS_DOMAIN deve essere un nome DNS completo, per esempio example.com."
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || die "WORDPRESS_DOMAIN contiene un'etichetta DNS non valida."
        [[ ${label} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "WORDPRESS_DOMAIN contiene caratteri DNS non validi."
    done

    printf '%s' "${host}"
}

wp_cli() {
    runuser -u "${WEB_USER}" -- env \
        HOME="${WP_CLI_HOME}" \
        WP_CLI_CACHE_DIR="${WP_CLI_HOME}/cache" \
        HTTPS=on \
        SERVER_PORT=443 \
        "${WP_BIN}" --path="${WORDPRESS_ROOT}" --no-color "$@"
}

wait_for_mariadb() {
    local _
    log "Attendo MariaDB."
    for _ in {1..60}; do
        # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere variabili shell.
        if DB_HOST_VALUE="${WORDPRESS_DB_HOST}" \
            DB_NAME_VALUE="${WORDPRESS_DB_NAME}" \
            DB_USER_VALUE="${WORDPRESS_DB_USER}" \
            DB_PASSWORD_VALUE="${WORDPRESS_DB_PASSWORD}" \
            "${PHP_BIN}" -r '
                mysqli_report(MYSQLI_REPORT_OFF);
                [$host, $port] = array_pad(explode(":", getenv("DB_HOST_VALUE"), 2), 2, "3306");
                $db = @new mysqli($host, getenv("DB_USER_VALUE"), getenv("DB_PASSWORD_VALUE"), getenv("DB_NAME_VALUE"), (int) $port);
                exit($db->connect_errno === 0 ? 0 : 1);
            ' >/dev/null 2>&1; then
            log "MariaDB è disponibile."
            return 0
        fi
        sleep 2
    done
    die "MariaDB non è raggiungibile dopo 120 secondi."
}

redis_is_available() {
    # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere variabili shell.
    REDIS_HOST_VALUE="${WORDPRESS_REDIS_HOST}" \
        REDIS_PORT_VALUE="${WORDPRESS_REDIS_PORT}" \
        "${PHP_BIN}" -r '
            try {
                $redis = new Redis();
                $redis->connect(getenv("REDIS_HOST_VALUE"), (int) getenv("REDIS_PORT_VALUE"), 1.0);
                $redis->ping();
                $redis->close();
                exit(0);
            } catch (Throwable $error) {
                exit(1);
            }
        ' >/dev/null 2>&1
}

wait_for_redis() {
    local _
    log "Attendo Redis."
    for _ in {1..30}; do
        if redis_is_available; then
            log "Redis è disponibile."
            return 0
        fi
        sleep 2
    done
    return 1
}

repair_ownership_if_needed() {
    local mismatch
    mismatch=$(find "${WORDPRESS_ROOT}" -xdev \( ! -user "${WEB_USER}" -o ! -group "${WEB_GROUP}" \) -print -quit)
    if [[ -n ${mismatch} ]]; then
        log "Correggo l'ownership del volume WordPress."
        chown -R "${WEB_USER}:${WEB_GROUP}" "${WORDPRESS_ROOT}"
    fi
}

create_wp_config() {
    log "Creo wp-config.php."
    wp_cli config create \
        --dbname="${WORDPRESS_DB_NAME}" \
        --dbuser="${WORDPRESS_DB_USER}" \
        --dbpass="${WORDPRESS_DB_PASSWORD}" \
        --dbhost="${WORDPRESS_DB_HOST}" \
        --dbprefix="${WORDPRESS_TABLE_PREFIX}" \
        --dbcharset=utf8mb4 \
        --skip-check \
        --force
    chmod 0640 "${WORDPRESS_ROOT}/wp-config.php"
}

manage_wp_config() {
    runuser -u "${WEB_USER}" -- "${PHP_BIN}" \
        /usr/local/lib/wordpress-stack/manage-wp-config.php \
        "${WORDPRESS_ROOT}/wp-config.php"
}

manage_htaccess() {
    local multisite_enabled=$1
    local multisite_mode=$2
    local template

    if [[ ${multisite_enabled} != true ]]; then
        template="${HTACCESS_TEMPLATE_DIRECTORY}/.htaccess.single.template"
    elif [[ ${multisite_mode} == subdomain ]]; then
        template="${HTACCESS_TEMPLATE_DIRECTORY}/.htaccess.multisite-subdomain.template"
    else
        template="${HTACCESS_TEMPLATE_DIRECTORY}/.htaccess.template"
    fi

    runuser -u "${WEB_USER}" -- "${PHP_BIN}" \
        /usr/local/lib/wordpress-stack/manage-htaccess.php \
        "${WORDPRESS_ROOT}/.htaccess" \
        "${template}"
    chmod 0644 "${WORDPRESS_ROOT}/.htaccess"
}

set_raw_constant() {
    wp_cli config set "$1" "$2" --raw --type=constant --quiet
}

set_string_constant() {
    wp_cli config set "$1" "$2" --type=constant --quiet
}

delete_constant_if_present() {
    if wp_cli config has "$1" --type=constant >/dev/null 2>&1; then
        wp_cli config delete "$1" --type=constant --quiet
    fi
}

install_or_convert_wordpress() {
    local canonical_url=$1
    local skip_email=$2
    local multisite_enabled=$3
    local multisite_mode=$4
    local -a install_args=(
        "--url=${canonical_url}"
        "--title=${WORDPRESS_TITLE}"
        "--admin_user=${WORDPRESS_ADMIN_USER}"
        "--admin_password=${WORDPRESS_ADMIN_PASSWORD}"
        "--admin_email=${WORDPRESS_ADMIN_EMAIL}"
    )
    if [[ ${skip_email} == true ]]; then
        install_args+=(--skip-email)
    fi

    if ! wp_cli core is-installed >/dev/null 2>&1; then
        if [[ ${multisite_enabled} == true ]]; then
            local -a multisite_install_args=(core multisite-install "${install_args[@]}")
            if [[ ${multisite_mode} == subdomain ]]; then
                multisite_install_args+=(--subdomains)
            fi
            log "Installo WordPress Multisite in modalità ${multisite_mode}."
            wp_cli "${multisite_install_args[@]}"
        else
            log "Installo WordPress in modalità single-site."
            wp_cli core install "${install_args[@]}"
        fi
        return 0
    fi

    if wp_cli core is-installed --network >/dev/null 2>&1; then
        [[ ${multisite_enabled} == true ]] || \
            die "Il volume contiene già un network Multisite. La disattivazione automatica non è sicura: ripristina WORDPRESS_ENABLE_MULTISITE=true oppure esegui una migrazione esplicita verso un nuovo single-site."

        local current_subdomain current_subdomain_raw expected_subdomain
        wp_cli config has SUBDOMAIN_INSTALL --type=constant >/dev/null 2>&1 || \
            die "Il network esistente non dichiara SUBDOMAIN_INSTALL in wp-config.php. Ripristina la configurazione Multisite prima del redeploy."
        current_subdomain_raw=$(wp_cli config get SUBDOMAIN_INSTALL --type=constant)
        case "${current_subdomain_raw,,}" in
            true|1) current_subdomain=true ;;
            false|0|'') current_subdomain=false ;;
            *) die "SUBDOMAIN_INSTALL contiene un valore non riconosciuto." ;;
        esac
        expected_subdomain=false
        [[ ${multisite_mode} == subdomain ]] && expected_subdomain=true
        [[ ${current_subdomain} == "${expected_subdomain}" ]] || \
            die "Il network esistente usa una topologia diversa da WORDPRESS_MULTISITE_MODE='${multisite_mode}'. La conversione automatica tra subdomain e subdirectory non è sicura."

        log "WordPress Multisite ${multisite_mode} è già installato: nessuna reinstallazione."
    elif [[ ${multisite_enabled} == true ]]; then
        local -a convert_args=(core multisite-convert "--title=${WORDPRESS_TITLE}")
        if [[ ${multisite_mode} == subdomain ]]; then
            convert_args+=(--subdomains)
        fi
        log "Converto automaticamente il single-site esistente in Multisite ${multisite_mode}."
        wp_cli "${convert_args[@]}"
    else
        log "WordPress single-site è già installato: nessuna reinstallazione."
    fi
}

verify_network_domain() {
    local expected_domain=$1
    local stored_domain
    # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere $wpdb nella shell.
    stored_domain=$(wp_cli eval \
        'global $wpdb; echo (string) $wpdb->get_var("SELECT domain FROM {$wpdb->site} WHERE id = 1");' \
        --skip-plugins --skip-themes)
    [[ ${stored_domain,,} == "${expected_domain}" ]] || \
        die "Il network esistente usa il dominio '${stored_domain}', diverso da WORDPRESS_DOMAIN='${expected_domain}'. Esegui una migrazione esplicita invece di cambiare solo la variabile."
}

verify_single_site_domain() {
    local expected_domain=$1
    local stored_url stored_domain
    stored_url=$(wp_cli option get home --skip-plugins --skip-themes)
    # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere variabili shell.
    stored_domain=$(URL_VALUE="${stored_url}" "${PHP_BIN}" -r '
        $host = parse_url((string) getenv("URL_VALUE"), PHP_URL_HOST);
        if (!is_string($host) || $host === "") {
            exit(1);
        }
        echo strtolower($host);
    ') || die "Il single-site esistente contiene un URL home non valido: '${stored_url}'."
    [[ ${stored_domain} == "${expected_domain}" ]] || \
        die "Il single-site esistente usa il dominio '${stored_domain}', diverso da WORDPRESS_DOMAIN='${expected_domain}'. Esegui una migrazione esplicita invece di cambiare solo la variabile."
}

configure_wordpress() {
    local host=$1
    local canonical_url=$2
    local debug=$3
    local disable_cron=$4
    local install_plugins=$5
    local multisite_enabled=$6
    local multisite_mode=$7
    local redis_prefix
    redis_prefix="wp:$(printf '%s' "${host}" | sha256sum | cut -c1-16):"

    if [[ ${multisite_enabled} == true ]]; then
        local subdomain_install=false
        [[ ${multisite_mode} == subdomain ]] && subdomain_install=true
        verify_network_domain "${host}"
        set_raw_constant MULTISITE true
        set_raw_constant SUBDOMAIN_INSTALL "${subdomain_install}"
        set_string_constant DOMAIN_CURRENT_SITE "${host}"
        set_string_constant PATH_CURRENT_SITE /
        set_raw_constant SITE_ID_CURRENT_SITE 1
        set_raw_constant BLOG_ID_CURRENT_SITE 1
    else
        verify_single_site_domain "${host}"
        delete_constant_if_present MULTISITE
        delete_constant_if_present SUBDOMAIN_INSTALL
        delete_constant_if_present DOMAIN_CURRENT_SITE
        delete_constant_if_present PATH_CURRENT_SITE
        delete_constant_if_present SITE_ID_CURRENT_SITE
        delete_constant_if_present BLOG_ID_CURRENT_SITE
    fi

    set_string_constant WP_MEMORY_LIMIT "${WORDPRESS_MEMORY_LIMIT}"
    set_string_constant WP_MAX_MEMORY_LIMIT "${WORDPRESS_MAX_MEMORY_LIMIT}"
    set_raw_constant DISABLE_WP_CRON "${disable_cron}"
    set_raw_constant WP_CACHE "${install_plugins}"
    set_raw_constant WP_DEBUG "${debug}"
    set_raw_constant WP_DEBUG_LOG "${debug}"
    set_raw_constant WP_DEBUG_DISPLAY false
    set_raw_constant FORCE_SSL_ADMIN true
    set_string_constant FS_METHOD direct
    set_string_constant WP_REDIS_HOST "${WORDPRESS_REDIS_HOST}"
    set_raw_constant WP_REDIS_PORT "${WORDPRESS_REDIS_PORT}"
    set_raw_constant WP_REDIS_DATABASE 0
    set_string_constant WP_REDIS_PREFIX "${redis_prefix}"
    set_raw_constant WP_REDIS_TIMEOUT 1
    set_raw_constant WP_REDIS_READ_TIMEOUT 1

    wp_cli option update home "${canonical_url}" --quiet
    wp_cli option update siteurl "${canonical_url}" --quiet
    wp_cli option update timezone_string "${WORDPRESS_TIMEZONE}" --quiet

    if [[ ${WORDPRESS_LOCALE} != en_US ]]; then
        wp_cli language core install "${WORDPRESS_LOCALE}" --activate --quiet
    fi
}

configure_multisite_https() {
    local multisite_enabled=$1
    local multisite_mode=$2
    local mu_plugin_directory="${WORDPRESS_ROOT}/wp-content/mu-plugins"
    local mu_plugin_target="${mu_plugin_directory}/coolify-multisite-https.php"

    if [[ ${multisite_enabled} != true || ${multisite_mode} != subdomain ]]; then
        return 0
    fi

    install -d -m 0755 -o "${WEB_USER}" -g "${WEB_GROUP}" "${mu_plugin_directory}"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" \
        "${MULTISITE_HTTPS_MU_PLUGIN_SOURCE}" \
        "${mu_plugin_target}"

    # shellcheck disable=SC2016 # Il frammento è PHP, non deve espandere variabili shell.
    wp_cli eval '
        foreach (get_sites(["number" => 0]) as $site) {
            switch_to_blog((int) $site->blog_id);
            foreach (["home", "siteurl"] as $option) {
                $current = (string) get_option($option);
                $https = set_url_scheme($current, "https");
                if ($https !== $current) {
                    update_option($option, $https);
                }
            }
            restore_current_blog();
        }
    ' --skip-plugins --skip-themes
    log "HTTPS forzato per i siti del network a sottodomini tramite MU-plugin gestito."
}

configure_plugins() {
    local install_plugins=$1
    local enable_redis=$2
    local multisite_enabled=$3
    local activation_description="sul single-site"
    local -a scope_args=()

    if [[ ${multisite_enabled} == true ]]; then
        scope_args=(--network)
        activation_description="sull'intero network"
    fi

    if [[ ${install_plugins} == true ]]; then
        if ! wp_cli plugin is-installed litespeed-cache; then
            log "Installazione del plugin LiteSpeed Cache."
            wp_cli plugin install litespeed-cache --version="${LITESPEED_CACHE_VERSION}" --quiet
        fi
        wp_cli plugin activate litespeed-cache "${scope_args[@]}" --quiet

        if ! wp_cli plugin is-installed redis-cache; then
            log "Installazione del plugin Redis Object Cache."
            wp_cli plugin install redis-cache --version="${REDIS_CACHE_VERSION}" --quiet
        fi
        wp_cli plugin activate redis-cache "${scope_args[@]}" --quiet
        log "Plugin attivati ${activation_description}."
    else
        log "Installazione automatica dei plugin disabilitata."
    fi

    if [[ ${enable_redis} == true && ${install_plugins} == true ]]; then
        if ! wp_cli plugin is-active redis-cache "${scope_args[@]}"; then
            warn "Redis Object Cache non è attivo ${activation_description}; salto l'abilitazione del drop-in."
            return 0
        fi
        if ! "${PHP_BIN}" -m | tr '[:upper:]' '[:lower:]' | grep -qx redis; then
            warn "L'estensione PHP Redis non è caricata; salto l'abilitazione del drop-in."
            return 0
        fi
        if ! redis_is_available; then
            warn "Redis non risponde; WordPress resta installato ma l'object cache non viene abilitata."
            return 0
        fi
        if ! wp_cli cli has-command redis >/dev/null 2>&1; then
            warn "Il comando WP-CLI 'redis' non è disponibile; salto l'abilitazione del drop-in."
            return 0
        fi
        if wp_cli redis enable; then
            log "Redis Object Cache abilitata."
        else
            warn "'wp redis enable' non è riuscito; WordPress resta operativo senza object cache persistente."
        fi
    elif wp_cli plugin is-installed redis-cache; then
        if wp_cli cli has-command redis >/dev/null 2>&1; then
            wp_cli redis disable >/dev/null 2>&1 || warn "Non è stato possibile rimuovere il drop-in Redis."
        fi
        wp_cli plugin deactivate redis-cache "${scope_args[@]}" --quiet >/dev/null 2>&1 || true
        log "Redis Object Cache disabilitata."
    fi
}

main() {
    umask 027

    require_value WORDPRESS_DOMAIN
    require_value WORDPRESS_DB_HOST
    require_value WORDPRESS_DB_NAME
    require_value WORDPRESS_DB_USER
    require_value WORDPRESS_DB_PASSWORD

    WORDPRESS_LOCALE=${WORDPRESS_LOCALE:-it_IT}
    WORDPRESS_TIMEZONE=${WORDPRESS_TIMEZONE:-Europe/Rome}
    WORDPRESS_TABLE_PREFIX=${WORDPRESS_TABLE_PREFIX:-wp_}
    WORDPRESS_MEMORY_LIMIT=${WORDPRESS_MEMORY_LIMIT:-256M}
    WORDPRESS_MAX_MEMORY_LIMIT=${WORDPRESS_MAX_MEMORY_LIMIT:-512M}
    WORDPRESS_REDIS_HOST=${WORDPRESS_REDIS_HOST:-redis}
    WORDPRESS_REDIS_PORT=${WORDPRESS_REDIS_PORT:-6379}
    WORDPRESS_VERSION=${WORDPRESS_VERSION:-7.0.2}

    local debug skip_email multisite_enabled multisite_mode install_plugins enable_redis disable_cron
    local host canonical_url redis_available installation_label admin_url
    debug=$(normalise_boolean WORDPRESS_DEBUG "${WORDPRESS_DEBUG:-false}")
    skip_email=$(normalise_boolean WORDPRESS_SKIP_EMAIL "${WORDPRESS_SKIP_EMAIL:-true}")
    multisite_enabled=$(normalise_boolean WORDPRESS_ENABLE_MULTISITE "${WORDPRESS_ENABLE_MULTISITE:-true}")
    multisite_mode=$(normalise_multisite_mode "${WORDPRESS_MULTISITE_MODE:-subdirectory}")
    install_plugins=$(normalise_boolean WORDPRESS_INSTALL_PLUGINS "${WORDPRESS_INSTALL_PLUGINS:-true}")
    enable_redis=$(normalise_boolean WORDPRESS_ENABLE_REDIS "${WORDPRESS_ENABLE_REDIS:-true}")
    disable_cron=$(normalise_boolean WORDPRESS_DISABLE_WP_CRON "${WORDPRESS_DISABLE_WP_CRON:-true}")

    [[ ${WORDPRESS_LOCALE} =~ ^[A-Za-z_@.-]+$ ]] || die "WORDPRESS_LOCALE contiene caratteri non validi."
    [[ ${WORDPRESS_TABLE_PREFIX} =~ ^[A-Za-z0-9_]+$ ]] || die "WORDPRESS_TABLE_PREFIX può contenere soltanto lettere, numeri e underscore."
    [[ ${WORDPRESS_VERSION} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "WORDPRESS_VERSION deve essere una versione numerica pinata."
    [[ ${WORDPRESS_REDIS_PORT} =~ ^[0-9]+$ ]] || die "WORDPRESS_REDIS_PORT deve essere numerica."
    validate_php_size WORDPRESS_MEMORY_LIMIT "${WORDPRESS_MEMORY_LIMIT}"
    validate_php_size WORDPRESS_MAX_MEMORY_LIMIT "${WORDPRESS_MAX_MEMORY_LIMIT}"

    host=$(normalise_domain "${WORDPRESS_DOMAIN}")
    canonical_url="https://${host}"
    redis_available=false
    installation_label="single-site"
    admin_url="${canonical_url}/wp-admin/"
    if [[ ${multisite_enabled} == true ]]; then
        installation_label="multisite-${multisite_mode}"
        admin_url="${canonical_url}/wp-admin/network/"
    fi
    log "Dominio normalizzato: ${host}; URL canonico: ${canonical_url}; modalità: ${installation_label}."

    install -d -m 0755 -o "${WEB_USER}" -g "${WEB_GROUP}" "${WORDPRESS_ROOT}" "${WP_CLI_HOME}" "${WP_CLI_HOME}/cache"
    repair_ownership_if_needed
    wait_for_mariadb

    if [[ ${enable_redis} == true ]]; then
        if wait_for_redis; then
            redis_available=true
        else
            warn "Redis non è disponibile durante il bootstrap; proseguo senza rendere fallita un'installazione WordPress valida."
        fi
    fi

    if [[ ! -f ${WORDPRESS_ROOT}/wp-load.php || ! -f ${WORDPRESS_ROOT}/wp-includes/version.php ]]; then
        log "Scarico WordPress ${WORDPRESS_VERSION}."
        wp_cli core download --version="${WORDPRESS_VERSION}" --locale="${WORDPRESS_LOCALE}" --force
    else
        log "I file core di WordPress sono già presenti."
    fi

    if [[ ! -f ${WORDPRESS_ROOT}/wp-config.php ]]; then
        create_wp_config
    else
        log "wp-config.php è già presente: non viene ricreato."
    fi

    manage_wp_config

    if [[ ${enable_redis} != true || ${redis_available} != true ]]; then
        set_raw_constant WP_REDIS_DISABLED true
    elif wp_cli config has WP_REDIS_DISABLED >/dev/null 2>&1; then
        wp_cli config delete WP_REDIS_DISABLED --type=constant --quiet
    fi

    if ! wp_cli core is-installed >/dev/null 2>&1; then
        require_value WORDPRESS_TITLE
        require_value WORDPRESS_ADMIN_USER
        require_value WORDPRESS_ADMIN_EMAIL
        require_value WORDPRESS_ADMIN_PASSWORD
        [[ ${#WORDPRESS_ADMIN_USER} -le 60 && ${WORDPRESS_ADMIN_USER} =~ ^[A-Za-z0-9._@-]+$ ]] || \
            die "WORDPRESS_ADMIN_USER non è valido."
        EMAIL_VALUE="${WORDPRESS_ADMIN_EMAIL}" "${PHP_BIN}" -r \
            'exit(filter_var(getenv("EMAIL_VALUE"), FILTER_VALIDATE_EMAIL) ? 0 : 1);' || \
            die "WORDPRESS_ADMIN_EMAIL non è un indirizzo email valido."
        [[ ${#WORDPRESS_ADMIN_PASSWORD} -ge 12 ]] || die "WORDPRESS_ADMIN_PASSWORD deve contenere almeno 12 caratteri."
    elif [[ ${multisite_enabled} == true ]] && ! wp_cli core is-installed --network >/dev/null 2>&1; then
        require_value WORDPRESS_TITLE
    fi

    install_or_convert_wordpress "${canonical_url}" "${skip_email}" "${multisite_enabled}" "${multisite_mode}"
    configure_wordpress \
        "${host}" \
        "${canonical_url}" \
        "${debug}" \
        "${disable_cron}" \
        "${install_plugins}" \
        "${multisite_enabled}" \
        "${multisite_mode}"
    configure_multisite_https "${multisite_enabled}" "${multisite_mode}"
    configure_plugins "${install_plugins}" "${enable_redis}" "${multisite_enabled}"
    manage_htaccess "${multisite_enabled}" "${multisite_mode}"

    printf '%s\n' '<?php echo "ok";' > "${WORDPRESS_ROOT}/healthz.php"
    chown "${WEB_USER}:${WEB_GROUP}" "${WORDPRESS_ROOT}/healthz.php"
    chmod 0644 "${WORDPRESS_ROOT}/healthz.php"
    chmod 0640 "${WORDPRESS_ROOT}/wp-config.php"

    log "Bootstrap completato; area amministrativa: ${admin_url}."
}

main "$@"
