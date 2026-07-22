# Configurazione dichiarativa

## Precedenza

La configurazione viene risolta in questo ordine:

1. valori espliciti delle variabili d'ambiente;
2. manifest personalizzato (`WORDPRESS_BOOTSTRAP_MANIFEST` o `WORDPRESS_BOOTSTRAP_MANIFEST_JSON`);
3. preset scelto con `WORDPRESS_BOOTSTRAP_PRESET`;
4. default del Compose selezionato.

Le variabili di topologia, servizi e runtime non appartengono al manifest perché determinano infrastruttura o segreti. Il manifest contiene soltanto policy WordPress e artefatti applicativi.

## Variabili principali

| Variabile | Default standard | Valori/effetto |
| --- | --- | --- |
| `WORDPRESS_ENABLE_MULTISITE` | `true` | booleano |
| `WORDPRESS_MULTISITE_MODE` | `subdirectory` | `subdirectory`, `subdomain` |
| `WORDPRESS_FILESYSTEM_MODE` | `mutable` | `mutable`, `immutable` |
| `WORDPRESS_BOOTSTRAP_PRESET` | `standard` | nome preset incluso |
| `WORDPRESS_MANIFEST_REAPPLY` | `false` | riapplica opzioni del manifest a installazione esistente |
| `WORDPRESS_INSTALL_PLUGINS` | `true` | provisiona la lista plugin del manifest |
| `WORDPRESS_INSTALL_THEMES` | `true` | provisiona la lista temi del manifest |
| `WORDPRESS_VERSION` | `7.0.2` | download iniziale o contratto immagine immutabile |
| `REDIS_CACHE_VERSION` | `2.8.0` | fallback pinato se il manifest non elenca `redis-cache` |
| `ELASTICPRESS_VERSION` | `5.3.3` | fallback pinato se il manifest non elenca `elasticpress` |
| `WORDPRESS_LOCALE` | `it_IT` | locale core |
| `WORDPRESS_TIMEZONE` | `Europe/Rome` | timezone PHP e WordPress |
| `WORDPRESS_DEBUG` | `false` | abilita log debug, mai output a schermo |
| `WORDPRESS_TABLE_PREFIX` | `wp_` | immutabile dopo la creazione config |

I booleani accettano `true/false`, `1/0`, `yes/no`, `on/off` senza distinzione tra maiuscole e minuscole.

## Database

| Variabile | Default standard | Note |
| --- | --- | --- |
| `WORDPRESS_DB_HOST` | `mariadb:3306` | supporta host IPv4/DNS e `[IPv6]:porta` |
| `WORDPRESS_DB_NAME` | `wordpress` | sincronizzato in `wp-config.php` |
| `WORDPRESS_DB_USER` | `wordpress` | sincronizzato in `wp-config.php` |
| `SERVICE_PASSWORD_WORDPRESS` | obbligatoria | password DB negli stack interni |
| `WORDPRESS_DB_PASSWORD` | obbligatoria external | usata direttamente solo nello stack esterno |
| `WORDPRESS_DB_SSL` | `false` interno, `true` external | abilita `MYSQLI_CLIENT_SSL` |
| `MARIADB_MAX_CONNECTIONS` | `200` (`100` minimal) | limite connessioni degli stack MariaDB interni |
| `MARIADB_INNODB_BUFFER_POOL_SIZE` | `256M` (`128M` minimal) | buffer pool degli stack MariaDB interni |
| `MYSQL_MAX_CONNECTIONS` | `200` | limite della variante MySQL 8.4 |
| `MYSQL_INNODB_BUFFER_POOL_SIZE` | `256M` | buffer pool della variante MySQL 8.4 |

Il bootstrap aggiorna le costanti database se le credenziali ruotano. Non aggiorna il prefisso tabelle.

Negli stack con Redis interno, `REDIS_MAXMEMORY` (default `0`, nessun limite Redis) e `REDIS_MAXMEMORY_POLICY` (default `allkeys-lru`) controllano la cache. In produzione impostare un limite coerente con la memoria assegnata al servizio.

## Runtime

| Variabile | Default | Range/nota |
| --- | --- | --- |
| `WORDPRESS_RUNTIME_PROFILE` | `balanced` | `small`, `balanced`, `large` |
| `PHP_UPLOAD_MAX_FILESIZE` | `1024M` | dimensione PHP |
| `PHP_POST_MAX_SIZE` | `1024M` | dimensione PHP |
| `PHP_MEMORY_LIMIT` | `512M` | limite per processo |
| `PHP_MAX_EXECUTION_TIME` | `300` | 1–86400 secondi |
| `PHP_MAX_INPUT_TIME` | `300` | 1–86400 secondi |
| `PHP_MAX_INPUT_VARS` | `5000` | 100–1.000.000 |
| `PHP_LSAPI_CHILDREN` | dal profilo | 1–256 |
| `LSAPI_AVOID_FORK` | dal profilo | dimensione memoria |
| `PHP_OPCACHE_MEMORY_CONSUMPTION` | dal profilo | 32–4096 MiB |
| `PHP_OPCACHE_INTERNED_STRINGS_BUFFER` | dal profilo | 4–256 MiB |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | dal profilo | 1.000–1.000.000 |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `1` | `0` o `1` |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `2` | secondi |
| `OLS_MAX_CONNECTIONS` | dal profilo | 100–1.000.000 |
| `OLS_KEEP_ALIVE_TIMEOUT` | `5` | 1–300 secondi |
| `OLS_MAX_REQUEST_BODY_SIZE` | `2047M` | dimensione PHP-style |
| `WORDPRESS_HEALTHCHECK_MODE` | `readiness` | `readiness` o `liveness` nello stack standard |

Gli override granulari prevalgono sul profilo. `PHP_POST_MAX_SIZE` dovrebbe essere almeno pari a `PHP_UPLOAD_MAX_FILESIZE`; il limite pubblico può essere ulteriormente ridotto dal proxy Coolify.

## Manifest JSON

Esempio completo:

```json
{
  "schema": 1,
  "name": "agency-standard",
  "wordpress": {
    "environment": "production",
    "permalink_structure": "/%postname%/",
    "search_engine_visibility": true,
    "delete_default_content": true,
    "update_policy": "minor",
    "disallow_file_edit": true,
    "disallow_file_mods": false
  },
  "plugins": [
    {
      "slug": "litespeed-cache",
      "version": "7.8.1",
      "activation": "auto",
      "required": true
    }
  ],
  "themes": [
    {
      "slug": "twentytwentyfive",
      "version": "1.3",
      "activate": true,
      "required": true
    }
  ],
  "multisite": {
    "registration": "none",
    "upload_space_mb": 512,
    "upload_filetypes": "jpg jpeg png gif webp avif pdf zip",
    "apply_to_existing_sites": false
  }
}
```

### Contratto

- `schema` deve essere `1`.
- `name` e gli slug accettano minuscole, numeri e trattini.
- `environment`: `local`, `development`, `staging`, `production`.
- `update_policy`: `default`, `minor`, `all`, `disabled`.
- `activation`: `auto`, `site`, `network`, `none`. `auto` significa network-wide su Multisite e site-wide su single-site.
- Versioni plugin/tema devono essere pin esatti; non sono ammessi `latest`, range o wildcard.
- `required=false` converte un errore di download/allineamento in warning.
- Può essere attivo un solo tema nel manifest.
- `registration`: `none`, `all`, `blog`, `user`.
- `apply_to_existing_sites=true` permette alla modalità `reapply` di aggiornare permalink/visibilità di tutti i siti del network.

Il validatore rifiuta chiavi sconosciute, duplicati, tipi errati, liste eccessive e file oltre 128 KiB.

Quando `redis-cache` o `elasticpress` è presente nel manifest, la sua versione ha precedenza sul rispettivo fallback d'ambiente. In modalità immutabile la stessa versione deve essere baked nell'immagine; una divergenza interrompe il bootstrap.

## Ciclo di applicazione

Sul primo bootstrap vengono applicati permalink, visibilità motori, policy network e, se richiesto, rimozione dei contenuti predefiniti. Il manifest viene copiato tra i MU-plugin e ne viene registrato nome, hash e timestamp nel database.

Su avvii successivi:

- plugin e temi richiesti vengono controllati/allineati;
- costanti e moduli runtime vengono sincronizzati;
- contenuti e opzioni sito non vengono riapplicati, salvo `WORDPRESS_MANIFEST_REAPPLY=true`.

Il flag di reapply deve essere temporaneo e versionato come una migrazione di configurazione.
