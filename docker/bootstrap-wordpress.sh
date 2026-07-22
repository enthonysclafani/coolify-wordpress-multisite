#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORDPRESS_ROOT="/var/www/vhosts/localhost/html"
readonly PHP_BIN="/usr/local/bin/stack-php"
readonly WP_BIN="/usr/local/bin/wp"
readonly WEB_USER="nobody"
readonly WEB_GROUP="nogroup"
readonly WP_CLI_HOME="/tmp/wordpress-wp-cli"
readonly HTACCESS_TEMPLATE_DIRECTORY="/usr/local/share/wordpress-stack"
readonly MULTISITE_HTTPS_MU_PLUGIN_SOURCE="/usr/local/share/wordpress-stack/coolify-multisite-https.php"
readonly SUITE_MU_PLUGIN_SOURCE="/usr/local/share/wordpress-stack/coolify-suite.php"
readonly S3_MU_PLUGIN_SOURCE="/usr/local/share/wordpress-stack/coolify-s3-uploads.php"
readonly HEALTH_ENDPOINT_SOURCE="/usr/local/share/wordpress-stack/health-endpoint.php"
readonly MANIFEST_TOOL="/usr/local/lib/wordpress-stack/manifest-tool.php"
readonly MANIFEST_APPLIER="/usr/local/lib/wordpress-stack/apply-manifest.php"
readonly MANIFEST_PRESET_DIRECTORY="/usr/local/share/wordpress-stack/presets"
readonly DEFAULT_REDIS_CACHE_VERSION="2.8.0"
readonly DEFAULT_ELASTICPRESS_VERSION="5.3.3"

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

validate_integer_range() {
    local variable_name=$1
    local value=$2
    local minimum=$3
    local maximum=$4
    [[ ${value} =~ ^[0-9]+$ && ${value} -ge ${minimum} && ${value} -le ${maximum} ]] || \
        die "${variable_name} deve essere un intero tra ${minimum} e ${maximum}."
}

normalise_filesystem_mode() {
    local value=${1,,}
    case "${value}" in
        mutable|immutable) printf '%s' "${value}" ;;
        *) die "WORDPRESS_FILESYSTEM_MODE deve essere mutable oppure immutable." ;;
    esac
}

normalise_redis_scheme() {
    local value=${1,,}
    case "${value}" in
        tcp|tls) printf '%s' "${value}" ;;
        *) die "WORDPRESS_REDIS_SCHEME deve essere tcp oppure tls." ;;
    esac
}

validate_url() {
    local variable_name=$1
    local value=$2
    # shellcheck disable=SC2016 # Il frammento e PHP e non deve espandere variabili shell.
    URL_VALUE="${value}" "${PHP_BIN}" -r '
        $url = getenv("URL_VALUE");
        $parts = is_string($url) ? parse_url($url) : false;
        exit(
            is_array($parts)
            && in_array($parts["scheme"] ?? "", ["http", "https"], true)
            && is_string($parts["host"] ?? null)
            && $parts["host"] !== ""
            && ! isset($parts["user"], $parts["pass"])
                ? 0
                : 1
        );
    ' || die "${variable_name} deve essere un URL http/https valido senza credenziali incorporate."
}

resolve_manifest() {
    local preset=${WORDPRESS_BOOTSTRAP_PRESET:-standard}
    local configured_path=${WORDPRESS_BOOTSTRAP_MANIFEST:-}
    local inline_json=${WORDPRESS_BOOTSTRAP_MANIFEST_JSON:-}
    local path

    [[ ${preset} =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || \
        die "WORDPRESS_BOOTSTRAP_PRESET non e valido."
    [[ -z ${configured_path} || -z ${inline_json} ]] || \
        die "Usa soltanto una tra WORDPRESS_BOOTSTRAP_MANIFEST e WORDPRESS_BOOTSTRAP_MANIFEST_JSON."

    if [[ -n ${inline_json} ]]; then
        path=/tmp/wordpress-bootstrap-manifest.json
        umask 077
        printf '%s' "${inline_json}" > "${path}"
    elif [[ -n ${configured_path} ]]; then
        path=${configured_path}
    else
        path="${MANIFEST_PRESET_DIRECTORY}/${preset}.json"
    fi

    [[ -f ${path} && -r ${path} ]] || die "Manifest WordPress non leggibile: ${path}."
    "${PHP_BIN}" "${MANIFEST_TOOL}" validate "${path}" >/dev/null

    WORDPRESS_RESOLVED_MANIFEST=${path}
    WORDPRESS_RESOLVED_MANIFEST_HASH=$("${PHP_BIN}" "${MANIFEST_TOOL}" hash "${path}")
    export WORDPRESS_RESOLVED_MANIFEST WORDPRESS_RESOLVED_MANIFEST_HASH
    log "Manifest validato: $(manifest_get name unknown) (${WORDPRESS_RESOLVED_MANIFEST_HASH:0:12})."
}

manifest_get() {
    local path=$1
    local default=${2:-}
    "${PHP_BIN}" "${MANIFEST_TOOL}" get "${WORDPRESS_RESOLVED_MANIFEST}" "${path}" "${default}"
}

manifest_plugin_version() {
    local requested_slug=$1
    local fallback_version=$2
    local slug version activation required

    while IFS=$'\t' read -r slug version activation required; do
        if [[ ${slug} == "${requested_slug}" ]]; then
            printf '%s' "${version}"
            return 0
        fi
    done < <("${PHP_BIN}" "${MANIFEST_TOOL}" plugins "${WORDPRESS_RESOLVED_MANIFEST}")
    printf '%s' "${fallback_version}"
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
    log "Attendo il database MySQL/MariaDB."
    for _ in {1..60}; do
        # shellcheck disable=SC2016 # Il frammento e PHP, non deve espandere variabili shell.
        if DB_HOST_VALUE="${WORDPRESS_DB_HOST}" \
            DB_NAME_VALUE="${WORDPRESS_DB_NAME}" \
            DB_USER_VALUE="${WORDPRESS_DB_USER}" \
            DB_PASSWORD_VALUE="${WORDPRESS_DB_PASSWORD}" \
            DB_SSL_VALUE="${WORDPRESS_DB_SSL:-false}" \
            "${PHP_BIN}" -r '
                mysqli_report(MYSQLI_REPORT_OFF);
                $hostValue = (string) getenv("DB_HOST_VALUE");
                $host = $hostValue;
                $port = 3306;
                if (preg_match("/^\\[([^]]+)](?::([0-9]+))?$/", $hostValue, $matches) === 1) {
                    $host = $matches[1];
                    $port = isset($matches[2]) ? (int) $matches[2] : 3306;
                } elseif (preg_match("/^([^:]+):([0-9]+)$/", $hostValue, $matches) === 1) {
                    $host = $matches[1];
                    $port = (int) $matches[2];
                }
                $db = mysqli_init();
                $flags = 0;
                if (in_array(strtolower((string) getenv("DB_SSL_VALUE")), ["true", "1", "yes", "on"], true)) {
                    $flags = MYSQLI_CLIENT_SSL;
                }
                $connected = @$db->real_connect(
                    $host,
                    (string) getenv("DB_USER_VALUE"),
                    (string) getenv("DB_PASSWORD_VALUE"),
                    (string) getenv("DB_NAME_VALUE"),
                    $port,
                    null,
                    $flags
                );
                exit($connected ? 0 : 1);
            ' >/dev/null 2>&1; then
            log "Database disponibile."
            return 0
        fi
        sleep 2
    done
    die "Il database non e raggiungibile dopo 120 secondi."
}

redis_is_available() {
    # shellcheck disable=SC2016 # Il frammento e PHP, non deve espandere variabili shell.
    REDIS_HOST_VALUE="${WORDPRESS_REDIS_HOST}" \
        REDIS_PORT_VALUE="${WORDPRESS_REDIS_PORT}" \
        REDIS_SCHEME_VALUE="${WORDPRESS_REDIS_SCHEME}" \
        REDIS_USERNAME_VALUE="${WORDPRESS_REDIS_USERNAME:-}" \
        REDIS_PASSWORD_VALUE="${WORDPRESS_REDIS_PASSWORD:-}" \
        REDIS_DATABASE_VALUE="${WORDPRESS_REDIS_DATABASE}" \
        REDIS_TLS_CA_VALUE="${WORDPRESS_REDIS_TLS_CA:-}" \
        "${PHP_BIN}" -r '
            try {
                $redis = new Redis();
                $host = (string) getenv("REDIS_HOST_VALUE");
                if (getenv("REDIS_SCHEME_VALUE") === "tls") {
                    $caFile = (string) getenv("REDIS_TLS_CA_VALUE");
                    if ($caFile !== "") {
                        stream_context_set_default([
                            "ssl" => [
                                "cafile" => $caFile,
                                "verify_peer" => true,
                                "verify_peer_name" => true,
                            ],
                        ]);
                    }
                    $host = "tls://" . $host;
                }
                $redis->connect($host, (int) getenv("REDIS_PORT_VALUE"), 1.0);
                $username = (string) getenv("REDIS_USERNAME_VALUE");
                $password = (string) getenv("REDIS_PASSWORD_VALUE");
                if ($password !== "") {
                    $redis->auth($username !== "" ? [$username, $password] : $password);
                }
                $redis->select((int) getenv("REDIS_DATABASE_VALUE"));
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
    local filesystem_mode=$1
    local managed_root=${WORDPRESS_ROOT}
    local mismatch

    if [[ ${filesystem_mode} == immutable ]]; then
        managed_root="${WORDPRESS_ROOT}/wp-content/uploads"
        install -d -m 0755 -o "${WEB_USER}" -g "${WEB_GROUP}" "${managed_root}"
    fi

    mismatch=$(find "${managed_root}" -xdev \( ! -user "${WEB_USER}" -o ! -group "${WEB_GROUP}" \) -print -quit)
    if [[ -n ${mismatch} ]]; then
        log "Correggo l'ownership di ${managed_root}."
        chown -R "${WEB_USER}:${WEB_GROUP}" "${managed_root}"
    fi
}

ensure_wordpress_core() {
    local filesystem_mode=$1
    local installed_version

    if [[ ! -f ${WORDPRESS_ROOT}/wp-load.php || ! -f ${WORDPRESS_ROOT}/wp-includes/version.php ]]; then
        [[ ${filesystem_mode} == mutable ]] || \
            die "Il target immutabile non contiene il core WordPress. Ricostruisci l'immagine wordpress-immutable."
        log "Scarico WordPress ${WORDPRESS_VERSION}."
        wp_cli core download --version="${WORDPRESS_VERSION}" --locale="${WORDPRESS_LOCALE}" --force
        return 0
    fi

    installed_version=$(wp_cli core version)
    if [[ ${filesystem_mode} == immutable && ${installed_version} != "${WORDPRESS_VERSION}" ]]; then
        die "L'immagine contiene WordPress ${installed_version}, ma WORDPRESS_VERSION richiede ${WORDPRESS_VERSION}. Ricostruisci l'immagine con gli stessi build arg."
    fi
    log "Core WordPress ${installed_version} già presente."
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

sync_database_config() {
    local current_prefix

    set_string_constant DB_NAME "${WORDPRESS_DB_NAME}"
    set_string_constant DB_USER "${WORDPRESS_DB_USER}"
    set_string_constant DB_PASSWORD "${WORDPRESS_DB_PASSWORD}"
    set_string_constant DB_HOST "${WORDPRESS_DB_HOST}"
    set_string_constant DB_CHARSET utf8mb4

    current_prefix=$(wp_cli config get table_prefix --type=variable)
    [[ ${current_prefix} == "${WORDPRESS_TABLE_PREFIX}" ]] || \
        die "wp-config.php usa il prefisso '${current_prefix}', diverso da WORDPRESS_TABLE_PREFIX='${WORDPRESS_TABLE_PREFIX}'. Una modifica automatica renderebbe invisibili le tabelle esistenti."
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
    local multisite_enabled=$5
    local multisite_mode=$6
    local filesystem_mode=$7
    local redis_prefix environment update_policy disallow_file_edit disallow_file_mods
    redis_prefix="wp:$(printf '%s' "${host}" | sha256sum | cut -c1-16):"
    environment=$(manifest_get wordpress.environment production)
    update_policy=$(manifest_get wordpress.update_policy default)
    disallow_file_edit=$(manifest_get wordpress.disallow_file_edit false)
    disallow_file_mods=$(manifest_get wordpress.disallow_file_mods false)
    if [[ ${filesystem_mode} == immutable ]]; then
        disallow_file_edit=true
        disallow_file_mods=true
    fi

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
    set_raw_constant WP_CACHE false
    set_raw_constant WP_DEBUG "${debug}"
    set_raw_constant WP_DEBUG_LOG "${debug}"
    set_raw_constant WP_DEBUG_DISPLAY false
    set_raw_constant FORCE_SSL_ADMIN true
    set_string_constant WP_ENVIRONMENT_TYPE "${environment}"
    set_string_constant FS_METHOD direct
    set_raw_constant DISALLOW_FILE_EDIT "${disallow_file_edit}"
    set_raw_constant DISALLOW_FILE_MODS "${disallow_file_mods}"
    set_string_constant WP_REDIS_HOST "${WORDPRESS_REDIS_HOST}"
    set_raw_constant WP_REDIS_PORT "${WORDPRESS_REDIS_PORT}"
    set_string_constant WP_REDIS_SCHEME "${WORDPRESS_REDIS_SCHEME}"
    set_raw_constant WP_REDIS_DATABASE "${WORDPRESS_REDIS_DATABASE}"
    set_string_constant WP_REDIS_PREFIX "${redis_prefix}"
    set_raw_constant WP_REDIS_TIMEOUT 1
    set_raw_constant WP_REDIS_READ_TIMEOUT 1

    wp_cli option update home "${canonical_url}" --quiet
    wp_cli option update siteurl "${canonical_url}" --quiet
    wp_cli option update timezone_string "${WORDPRESS_TIMEZONE}" --quiet

    case "${update_policy}" in
        default)
            delete_constant_if_present AUTOMATIC_UPDATER_DISABLED
            delete_constant_if_present WP_AUTO_UPDATE_CORE
            ;;
        minor)
            delete_constant_if_present AUTOMATIC_UPDATER_DISABLED
            set_string_constant WP_AUTO_UPDATE_CORE minor
            ;;
        all)
            delete_constant_if_present AUTOMATIC_UPDATER_DISABLED
            set_raw_constant WP_AUTO_UPDATE_CORE true
            ;;
        disabled)
            set_raw_constant AUTOMATIC_UPDATER_DISABLED true
            set_raw_constant WP_AUTO_UPDATE_CORE false
            ;;
    esac

    if [[ ${WORDPRESS_LOCALE} != en_US ]]; then
        if wp_cli language core is-installed "${WORDPRESS_LOCALE}" >/dev/null 2>&1; then
            wp_cli site switch-language "${WORDPRESS_LOCALE}" --quiet
        elif [[ ${filesystem_mode} == mutable ]]; then
            wp_cli language core install "${WORDPRESS_LOCALE}" --activate --quiet
        else
            die "La lingua ${WORDPRESS_LOCALE} non è inclusa nell'immagine immutabile. Ricostruiscila con WORDPRESS_LOCALE=${WORDPRESS_LOCALE}."
        fi
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

plugin_scope_args() {
    local activation=$1
    local multisite_enabled=$2
    PLUGIN_SCOPE_ARGS=()
    if [[ ${multisite_enabled} == true && ( ${activation} == auto || ${activation} == network ) ]]; then
        PLUGIN_SCOPE_ARGS=(--network)
    fi
}

ensure_plugin() {
    local slug=$1
    local version=$2
    local activation=$3
    local required=$4
    local filesystem_mode=$5
    local multisite_enabled=$6
    local installed_version

    if wp_cli plugin is-installed "${slug}"; then
        installed_version=$(wp_cli plugin get "${slug}" --field=version)
        if [[ ${installed_version} != "${version}" ]]; then
            if [[ ${filesystem_mode} == immutable ]]; then
                [[ ${required} == true ]] && \
                    die "Il plugin richiesto ${slug} è ${installed_version}, ma il manifest richiede ${version}. Ricostruisci l'immagine immutabile."
                warn "Plugin opzionale ${slug} non attivato: versione immagine ${installed_version}, manifest ${version}."
                return 0
            fi
            log "Allineo ${slug} da ${installed_version} a ${version}."
            if ! wp_cli plugin install "${slug}" --version="${version}" --force --quiet; then
                [[ ${required} == true ]] && die "Installazione del plugin richiesto ${slug} non riuscita."
                warn "Installazione del plugin opzionale ${slug} non riuscita."
                return 0
            fi
        fi
    elif [[ ${filesystem_mode} == immutable ]]; then
        [[ ${required} == true ]] && \
            die "Il plugin richiesto ${slug} ${version} non è incluso nell'immagine immutabile."
        warn "Plugin opzionale ${slug} assente dall'immagine immutabile."
        return 0
    else
        log "Installo ${slug} ${version}."
        if ! wp_cli plugin install "${slug}" --version="${version}" --quiet; then
            [[ ${required} == true ]] && die "Installazione del plugin richiesto ${slug} non riuscita."
            warn "Installazione del plugin opzionale ${slug} non riuscita."
            return 0
        fi
    fi

    [[ ${activation} != none ]] || return 0
    plugin_scope_args "${activation}" "${multisite_enabled}"
    if ! wp_cli plugin activate "${slug}" "${PLUGIN_SCOPE_ARGS[@]}" --quiet; then
        [[ ${required} == true ]] && die "Attivazione del plugin richiesto ${slug} non riuscita."
        warn "Attivazione del plugin opzionale ${slug} non riuscita."
    fi
}

configure_manifest_plugins() {
    local install_plugins=$1
    local filesystem_mode=$2
    local multisite_enabled=$3
    local slug version activation required

    if [[ ${install_plugins} != true ]]; then
        log "Provisioning dei plugin del manifest disabilitato da WORDPRESS_INSTALL_PLUGINS=false."
        return 0
    fi

    while IFS=$'\t' read -r slug version activation required; do
        [[ -n ${slug} ]] || continue
        ensure_plugin "${slug}" "${version}" "${activation}" "${required}" "${filesystem_mode}" "${multisite_enabled}"
    done < <("${PHP_BIN}" "${MANIFEST_TOOL}" plugins "${WORDPRESS_RESOLVED_MANIFEST}")
}

ensure_theme() {
    local slug=$1
    local version=$2
    local activate=$3
    local required=$4
    local filesystem_mode=$5
    local multisite_enabled=$6
    local installed_version

    if wp_cli theme is-installed "${slug}"; then
        installed_version=$(wp_cli theme get "${slug}" --field=version)
        if [[ ${installed_version} != "${version}" ]]; then
            if [[ ${filesystem_mode} == immutable ]]; then
                [[ ${required} == true ]] && \
                    die "Il tema richiesto ${slug} è ${installed_version}, ma il manifest richiede ${version}."
                warn "Tema opzionale ${slug} non attivato per versione non allineata."
                return 0
            fi
            if ! wp_cli theme install "${slug}" --version="${version}" --force --quiet; then
                [[ ${required} == true ]] && die "Installazione del tema richiesto ${slug} non riuscita."
                warn "Installazione del tema opzionale ${slug} non riuscita."
                return 0
            fi
        fi
    elif [[ ${filesystem_mode} == immutable ]]; then
        [[ ${required} == true ]] && die "Il tema richiesto ${slug} ${version} non è incluso nell'immagine immutabile."
        warn "Tema opzionale ${slug} assente dall'immagine immutabile."
        return 0
    elif ! wp_cli theme install "${slug}" --version="${version}" --quiet; then
        [[ ${required} == true ]] && die "Installazione del tema richiesto ${slug} non riuscita."
        warn "Installazione del tema opzionale ${slug} non riuscita."
        return 0
    fi

    if [[ ${multisite_enabled} == true ]]; then
        wp_cli theme enable "${slug}" --network --quiet
    fi
    if [[ ${activate} == true ]]; then
        wp_cli theme activate "${slug}" --quiet
    fi
}

configure_manifest_themes() {
    local install_themes=$1
    local filesystem_mode=$2
    local multisite_enabled=$3
    local slug version activate required

    [[ ${install_themes} == true ]] || {
        log "Provisioning dei temi del manifest disabilitato."
        return 0
    }
    while IFS=$'\t' read -r slug version activate required; do
        [[ -n ${slug} ]] || continue
        ensure_theme "${slug}" "${version}" "${activate}" "${required}" "${filesystem_mode}" "${multisite_enabled}"
    done < <("${PHP_BIN}" "${MANIFEST_TOOL}" themes "${WORDPRESS_RESOLVED_MANIFEST}")
}

configure_redis() {
    local enable_redis=$1
    local redis_available=$2
    local filesystem_mode=$3
    local multisite_enabled=$4
    local redis_cache_version

    plugin_scope_args auto "${multisite_enabled}"
    if [[ ${enable_redis} == true ]]; then
        redis_cache_version=$(manifest_plugin_version redis-cache "${REDIS_CACHE_VERSION}")
        ensure_plugin redis-cache "${redis_cache_version}" auto true "${filesystem_mode}" "${multisite_enabled}"
        if [[ ${redis_available} != true ]]; then
            set_raw_constant WP_REDIS_DISABLED true
            warn "Redis non risponde; l'object cache resta disabilitata."
            return 0
        fi
        if ! "${PHP_BIN}" -m | tr '[:upper:]' '[:lower:]' | grep -qx redis; then
            die "WORDPRESS_ENABLE_REDIS=true ma l'estensione PHP Redis non è caricata."
        fi
        wp_cli config delete WP_REDIS_DISABLED --type=constant --quiet >/dev/null 2>&1 || true
        wp_cli cli has-command redis >/dev/null 2>&1 || die "Il plugin Redis non espone il comando WP-CLI atteso."
        wp_cli redis enable
        log "Redis Object Cache abilitata."
        return 0
    fi

    set_raw_constant WP_REDIS_DISABLED true
    if wp_cli plugin is-installed redis-cache; then
        wp_cli redis disable >/dev/null 2>&1 || true
        wp_cli plugin deactivate redis-cache "${PLUGIN_SCOPE_ARGS[@]}" --quiet >/dev/null 2>&1 || true
    fi
    log "Redis Object Cache disabilitata."
}

configure_search() {
    local search_mode=$1
    local filesystem_mode=$2
    local multisite_enabled=$3
    local activation=$4
    local verify=$5
    local site_url elasticpress_version

    [[ ${search_mode} == elasticpress ]] || return 0
    elasticpress_version=$(manifest_plugin_version elasticpress "${ELASTICPRESS_VERSION}")
    ensure_plugin elasticpress "${elasticpress_version}" none true "${filesystem_mode}" "${multisite_enabled}"

    if [[ ${multisite_enabled} == true && ${activation} == network ]]; then
        wp_cli plugin activate elasticpress --network --quiet
    elif [[ ${multisite_enabled} == true ]]; then
        while IFS= read -r site_url; do
            [[ -n ${site_url} ]] && wp_cli --url="${site_url}" plugin activate elasticpress --quiet
        done < <(wp_cli site list --field=url --skip-plugins --skip-themes)
    else
        wp_cli plugin activate elasticpress --quiet
    fi

    if [[ ${verify} == true ]]; then
        wp_cli cli has-command elasticpress >/dev/null 2>&1 || die "Comando ElasticPress non disponibile."
        wp_cli elasticpress health-check
    fi
    log "ElasticPress configurato (${activation})."
}

configure_cache_constant() {
    local multisite_enabled=$1
    local -a scope_args=()
    [[ ${multisite_enabled} == true ]] && scope_args=(--network)
    if wp_cli plugin is-installed litespeed-cache \
        && wp_cli plugin is-active litespeed-cache "${scope_args[@]}"; then
        set_raw_constant WP_CACHE true
    else
        set_raw_constant WP_CACHE false
    fi
}

install_managed_runtime_files() {
    local mu_plugin_directory="${WORDPRESS_ROOT}/wp-content/mu-plugins"
    local managed_manifest="${mu_plugin_directory}/coolify-suite-manifest.json"
    install -d -m 0755 -o "${WEB_USER}" -g "${WEB_GROUP}" "${mu_plugin_directory}"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" "${SUITE_MU_PLUGIN_SOURCE}" \
        "${mu_plugin_directory}/coolify-suite.php"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" "${S3_MU_PLUGIN_SOURCE}" \
        "${mu_plugin_directory}/coolify-s3-uploads.php"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" "${WORDPRESS_RESOLVED_MANIFEST}" \
        "${managed_manifest}"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" "${HEALTH_ENDPOINT_SOURCE}" \
        "${WORDPRESS_ROOT}/healthz.php"
    install -m 0644 -o "${WEB_USER}" -g "${WEB_GROUP}" "${HEALTH_ENDPOINT_SOURCE}" \
        "${WORDPRESS_ROOT}/healthz-live.php"
    WORDPRESS_RESOLVED_MANIFEST=${managed_manifest}
    export WORDPRESS_RESOLVED_MANIFEST
}

apply_manifest() {
    local was_fresh=$1
    local reapply=$2
    local multisite_enabled=$3
    local apply_mode

    if [[ ${was_fresh} == true ]]; then
        apply_mode=fresh
    elif [[ ${reapply} == true ]]; then
        apply_mode=reapply
    elif [[ ${multisite_enabled} == true ]] \
        && ! wp_cli site option get _coolify_suite_manifest_v1 --format=json >/dev/null 2>&1; then
        apply_mode=fresh
        warn "Manifest non registrato dopo un bootstrap precedente; riprendo l'applicazione iniziale."
    elif [[ ${multisite_enabled} != true ]] \
        && ! wp_cli option get _coolify_suite_manifest_v1 --format=json >/dev/null 2>&1; then
        apply_mode=fresh
        warn "Manifest non registrato dopo un bootstrap precedente; riprendo l'applicazione iniziale."
    else
        log "Manifest già applicabile solo su richiesta; nessuna mutazione dei contenuti esistenti."
        return 0
    fi
    export WORDPRESS_MANIFEST_APPLY_MODE=${apply_mode}
    wp_cli eval-file "${MANIFEST_APPLIER}" --skip-themes
    unset WORDPRESS_MANIFEST_APPLY_MODE
    log "Manifest applicato in modalità ${apply_mode}."
}

validate_optional_modules() {
    local smtp_mode=$1
    local smtp_auth=$2
    local media_storage=$3
    local s3_instance_profile=$4
    local search_mode=$5
    local search_activation=$6

    case "${smtp_mode}" in
        disabled) ;;
        smtp)
            require_value WORDPRESS_SMTP_HOST
            validate_integer_range WORDPRESS_SMTP_PORT "${WORDPRESS_SMTP_PORT}" 1 65535
            [[ ${WORDPRESS_SMTP_ENCRYPTION} =~ ^(none|tls|ssl)$ ]] || \
                die "WORDPRESS_SMTP_ENCRYPTION deve essere none, tls oppure ssl."
            if [[ ${smtp_auth} == true ]]; then
                require_value WORDPRESS_SMTP_USERNAME
                require_value WORDPRESS_SMTP_PASSWORD
            fi
            if [[ -n ${WORDPRESS_SMTP_FROM_EMAIL:-} ]]; then
                EMAIL_VALUE="${WORDPRESS_SMTP_FROM_EMAIL}" "${PHP_BIN}" -r \
                    'exit(filter_var(getenv("EMAIL_VALUE"), FILTER_VALIDATE_EMAIL) ? 0 : 1);' || \
                    die "WORDPRESS_SMTP_FROM_EMAIL non è valido."
            fi
            ;;
        *) die "WORDPRESS_SMTP_MODE deve essere disabled oppure smtp." ;;
    esac

    case "${media_storage}" in
        local) ;;
        s3)
            [[ -r /usr/local/share/wordpress-stack/s3-module/vendor/autoload.php ]] || \
                die "WORDPRESS_MEDIA_STORAGE=s3 richiede il target Docker wordpress-suite o wordpress-immutable-suite."
            require_value WORDPRESS_S3_BUCKET
            require_value WORDPRESS_S3_REGION
            if [[ ${s3_instance_profile} != true ]]; then
                require_value WORDPRESS_S3_ACCESS_KEY
                require_value WORDPRESS_S3_SECRET_KEY
            fi
            [[ -z ${WORDPRESS_S3_ENDPOINT:-} ]] || validate_url WORDPRESS_S3_ENDPOINT "${WORDPRESS_S3_ENDPOINT}"
            [[ -z ${WORDPRESS_S3_BUCKET_URL:-} ]] || validate_url WORDPRESS_S3_BUCKET_URL "${WORDPRESS_S3_BUCKET_URL}"
            ;;
        *) die "WORDPRESS_MEDIA_STORAGE deve essere local oppure s3." ;;
    esac

    case "${search_mode}" in
        disabled) ;;
        elasticpress)
            require_value WORDPRESS_SEARCH_HOST
            validate_url WORDPRESS_SEARCH_HOST "${WORDPRESS_SEARCH_HOST}"
            [[ ${search_activation} =~ ^(network|per-site)$ ]] || \
                die "WORDPRESS_SEARCH_MULTISITE_ACTIVATION deve essere network oppure per-site."
            [[ ${WORDPRESS_SEARCH_INDEX_PREFIX} =~ ^[A-Za-z0-9._-]+$ ]] || \
                die "WORDPRESS_SEARCH_INDEX_PREFIX contiene caratteri non validi."
            ;;
        *) die "WORDPRESS_SEARCH_MODE deve essere disabled oppure elasticpress." ;;
    esac
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
    WORDPRESS_REDIS_DATABASE=${WORDPRESS_REDIS_DATABASE:-0}
    WORDPRESS_REDIS_SCHEME=$(normalise_redis_scheme "${WORDPRESS_REDIS_SCHEME:-tcp}")
    WORDPRESS_VERSION=${WORDPRESS_VERSION:-7.0.2}
    REDIS_CACHE_VERSION=${REDIS_CACHE_VERSION:-${DEFAULT_REDIS_CACHE_VERSION}}
    ELASTICPRESS_VERSION=${ELASTICPRESS_VERSION:-${DEFAULT_ELASTICPRESS_VERSION}}
    WORDPRESS_SMTP_PORT=${WORDPRESS_SMTP_PORT:-587}
    WORDPRESS_SMTP_ENCRYPTION=${WORDPRESS_SMTP_ENCRYPTION:-tls}
    WORDPRESS_SMTP_TIMEOUT_SECONDS=${WORDPRESS_SMTP_TIMEOUT_SECONDS:-15}
    WORDPRESS_SEARCH_INDEX_PREFIX=${WORDPRESS_SEARCH_INDEX_PREFIX:-coolifywp}
    WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES=${WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES:-1}

    local debug skip_email multisite_enabled multisite_mode install_plugins install_themes enable_redis disable_cron
    local filesystem_mode reapply_manifest smtp_mode smtp_auth smtp_verify_tls media_storage s3_instance_profile
    local s3_autoenable s3_path_style s3_use_local s3_checksum search_mode search_activation search_verify
    local host canonical_url redis_available installation_label admin_url was_fresh
    debug=$(normalise_boolean WORDPRESS_DEBUG "${WORDPRESS_DEBUG:-false}")
    skip_email=$(normalise_boolean WORDPRESS_SKIP_EMAIL "${WORDPRESS_SKIP_EMAIL:-true}")
    multisite_enabled=$(normalise_boolean WORDPRESS_ENABLE_MULTISITE "${WORDPRESS_ENABLE_MULTISITE:-true}")
    multisite_mode=$(normalise_multisite_mode "${WORDPRESS_MULTISITE_MODE:-subdirectory}")
    install_plugins=$(normalise_boolean WORDPRESS_INSTALL_PLUGINS "${WORDPRESS_INSTALL_PLUGINS:-true}")
    install_themes=$(normalise_boolean WORDPRESS_INSTALL_THEMES "${WORDPRESS_INSTALL_THEMES:-true}")
    enable_redis=$(normalise_boolean WORDPRESS_ENABLE_REDIS "${WORDPRESS_ENABLE_REDIS:-true}")
    disable_cron=$(normalise_boolean WORDPRESS_DISABLE_WP_CRON "${WORDPRESS_DISABLE_WP_CRON:-true}")
    filesystem_mode=$(normalise_filesystem_mode "${WORDPRESS_FILESYSTEM_MODE:-mutable}")
    reapply_manifest=$(normalise_boolean WORDPRESS_MANIFEST_REAPPLY "${WORDPRESS_MANIFEST_REAPPLY:-false}")
    smtp_mode=${WORDPRESS_SMTP_MODE:-disabled}
    smtp_auth=$(normalise_boolean WORDPRESS_SMTP_AUTH "${WORDPRESS_SMTP_AUTH:-true}")
    smtp_verify_tls=$(normalise_boolean WORDPRESS_SMTP_VERIFY_TLS "${WORDPRESS_SMTP_VERIFY_TLS:-true}")
    media_storage=${WORDPRESS_MEDIA_STORAGE:-local}
    s3_instance_profile=$(normalise_boolean WORDPRESS_S3_USE_INSTANCE_PROFILE "${WORDPRESS_S3_USE_INSTANCE_PROFILE:-false}")
    s3_autoenable=$(normalise_boolean WORDPRESS_S3_AUTOENABLE "${WORDPRESS_S3_AUTOENABLE:-true}")
    s3_path_style=$(normalise_boolean WORDPRESS_S3_PATH_STYLE "${WORDPRESS_S3_PATH_STYLE:-true}")
    s3_use_local=$(normalise_boolean WORDPRESS_S3_USE_LOCAL "${WORDPRESS_S3_USE_LOCAL:-false}")
    s3_checksum=$(normalise_boolean WORDPRESS_S3_CHECKSUM_WHEN_REQUIRED "${WORDPRESS_S3_CHECKSUM_WHEN_REQUIRED:-true}")
    search_mode=${WORDPRESS_SEARCH_MODE:-disabled}
    search_activation=${WORDPRESS_SEARCH_MULTISITE_ACTIVATION:-per-site}
    search_verify=$(normalise_boolean WORDPRESS_SEARCH_VERIFY "${WORDPRESS_SEARCH_VERIFY:-false}")
    export WORDPRESS_SMTP_AUTH=${smtp_auth} WORDPRESS_SMTP_VERIFY_TLS=${smtp_verify_tls}
    export WORDPRESS_S3_USE_INSTANCE_PROFILE=${s3_instance_profile} WORDPRESS_S3_AUTOENABLE=${s3_autoenable}
    export WORDPRESS_S3_PATH_STYLE=${s3_path_style} WORDPRESS_S3_USE_LOCAL=${s3_use_local}
    export WORDPRESS_S3_CHECKSUM_WHEN_REQUIRED=${s3_checksum}
    export WORDPRESS_REDIS_SCHEME WORDPRESS_REDIS_DATABASE WORDPRESS_SMTP_PORT WORDPRESS_SMTP_ENCRYPTION
    export WORDPRESS_SMTP_TIMEOUT_SECONDS WORDPRESS_SEARCH_INDEX_PREFIX
    export WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES
    export REDIS_CACHE_VERSION ELASTICPRESS_VERSION

    [[ ${WORDPRESS_LOCALE} =~ ^[A-Za-z_@.-]+$ ]] || die "WORDPRESS_LOCALE contiene caratteri non validi."
    [[ ${WORDPRESS_TABLE_PREFIX} =~ ^[A-Za-z0-9_]+$ ]] || die "WORDPRESS_TABLE_PREFIX può contenere soltanto lettere, numeri e underscore."
    [[ ${WORDPRESS_VERSION} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "WORDPRESS_VERSION deve essere una versione numerica pinata."
    [[ ${REDIS_CACHE_VERSION} =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]] || \
        die "REDIS_CACHE_VERSION deve essere una versione pinata."
    [[ ${ELASTICPRESS_VERSION} =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)?$ ]] || \
        die "ELASTICPRESS_VERSION deve essere una versione pinata."
    [[ ${WORDPRESS_REDIS_PORT} =~ ^[0-9]+$ ]] || die "WORDPRESS_REDIS_PORT deve essere numerica."
    validate_integer_range WORDPRESS_REDIS_PORT "${WORDPRESS_REDIS_PORT}" 1 65535
    validate_integer_range WORDPRESS_REDIS_DATABASE "${WORDPRESS_REDIS_DATABASE}" 0 255
    [[ -n ${WORDPRESS_REDIS_HOST} && ${WORDPRESS_REDIS_HOST} != *://* ]] || \
        die "WORDPRESS_REDIS_HOST deve essere un host senza schema."
    if [[ ${WORDPRESS_REDIS_SCHEME} == tls && -n ${WORDPRESS_REDIS_TLS_CA:-} && ! -r ${WORDPRESS_REDIS_TLS_CA} ]]; then
        die "WORDPRESS_REDIS_TLS_CA non è leggibile."
    fi
    validate_php_size WORDPRESS_MEMORY_LIMIT "${WORDPRESS_MEMORY_LIMIT}"
    validate_php_size WORDPRESS_MAX_MEMORY_LIMIT "${WORDPRESS_MAX_MEMORY_LIMIT}"
    validate_integer_range WORDPRESS_SMTP_TIMEOUT_SECONDS "${WORDPRESS_SMTP_TIMEOUT_SECONDS}" 1 120
    validate_integer_range WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES \
        "${WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES}" 1 100
    if [[ -n ${WORDPRESS_S3_CACHE_CONTROL_SECONDS:-} ]]; then
        validate_integer_range WORDPRESS_S3_CACHE_CONTROL_SECONDS "${WORDPRESS_S3_CACHE_CONTROL_SECONDS}" 0 315360000
    fi
    [[ ${WORDPRESS_S3_OBJECT_ACL:-private} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || \
        die "WORDPRESS_S3_OBJECT_ACL contiene caratteri non validi."
    [[ ${WORDPRESS_SMTP_FROM_NAME:-} != *$'\n'* && ${WORDPRESS_SMTP_FROM_NAME:-} != *$'\r'* ]] || \
        die "WORDPRESS_SMTP_FROM_NAME non può contenere ritorni a capo."
    resolve_manifest
    validate_optional_modules \
        "${smtp_mode}" "${smtp_auth}" "${media_storage}" "${s3_instance_profile}" \
        "${search_mode}" "${search_activation}"

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
    repair_ownership_if_needed "${filesystem_mode}"
    wait_for_mariadb

    if [[ ${enable_redis} == true ]]; then
        if wait_for_redis; then
            redis_available=true
        else
            warn "Redis non è disponibile durante il bootstrap; proseguo senza rendere fallita un'installazione WordPress valida."
        fi
    fi

    ensure_wordpress_core "${filesystem_mode}"

    if [[ ! -f ${WORDPRESS_ROOT}/wp-config.php ]]; then
        create_wp_config
    else
        log "wp-config.php è già presente: non viene ricreato."
    fi

    sync_database_config
    manage_wp_config

    if [[ ${enable_redis} != true || ${redis_available} != true ]]; then
        set_raw_constant WP_REDIS_DISABLED true
    elif wp_cli config has WP_REDIS_DISABLED >/dev/null 2>&1; then
        wp_cli config delete WP_REDIS_DISABLED --type=constant --quiet
    fi

    was_fresh=false
    if ! wp_cli core is-installed >/dev/null 2>&1; then
        was_fresh=true
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
        "${multisite_enabled}" \
        "${multisite_mode}" \
        "${filesystem_mode}"
    install_managed_runtime_files
    configure_manifest_plugins "${install_plugins}" "${filesystem_mode}" "${multisite_enabled}"
    configure_manifest_themes "${install_themes}" "${filesystem_mode}" "${multisite_enabled}"
    configure_redis "${enable_redis}" "${redis_available}" "${filesystem_mode}" "${multisite_enabled}"
    configure_search "${search_mode}" "${filesystem_mode}" "${multisite_enabled}" "${search_activation}" "${search_verify}"
    configure_cache_constant "${multisite_enabled}"
    configure_multisite_https "${multisite_enabled}" "${multisite_mode}"
    apply_manifest "${was_fresh}" "${reapply_manifest}" "${multisite_enabled}"
    manage_htaccess "${multisite_enabled}" "${multisite_mode}"
    chmod 0640 "${WORDPRESS_ROOT}/wp-config.php"

    log "Bootstrap completato; area amministrativa: ${admin_url}."
}

main "$@"
