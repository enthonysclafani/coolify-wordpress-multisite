# Coolify WordPress Suite

Suite Docker Compose dichiarativa per distribuire su Coolify WordPress single-site o Multisite con OpenLiteSpeed, scegliendo in modo esplicito database, cache, filesystem, moduli applicativi e profilo runtime.

Il percorso predefinito resta compatibile con lo stack originario: `docker-compose.yml` avvia WordPress, MariaDB, Redis e il runner WP-Cron, con Multisite in sottocartelle. Worker, backup, storage S3, ricerca esterna e immutabilità sono opt-in.

> Prima di un deploy di produzione, provare build, migrazione e ripristino in staging. Cambiare Compose o modalità filesystem non migra automaticamente dati esistenti.

## Funzionalità

- single-site, Multisite `subdirectory` e Multisite `subdomain`;
- preset dichiarativi `minimal`, `standard`, `high-traffic` e `immutable`;
- manifest JSON personalizzati con plugin e temi versionati;
- OpenLiteSpeed/LSPHP selezionabile tramite immagine base e tuning `small`, `balanced` o `large`;
- MariaDB 11.8, MySQL 8.4 oppure database MySQL/MariaDB esterno;
- Redis interno o esterno, con ACL, password, database logico e TLS;
- SMTP senza plugin amministrativo aggiuntivo;
- media su AWS S3 o endpoint S3-compatible tramite un target immagine dedicato;
- ElasticPress verso Elasticsearch esterno;
- runner WP-Cron, worker Action Scheduler e backup Restic;
- target immutabile con core e plugin inclusi nell'immagine, persistendo solo gli upload;
- endpoint distinti di liveness e readiness, entrambi accessibili solo da loopback;
- bootstrap idempotente e fail-closed per cambi pericolosi di dominio, prefisso o topologia.

## Stack disponibili

| Compose Location in Coolify | Uso | Servizi persistenti |
| --- | --- | --- |
| `/docker-compose.yml` | Standard, retrocompatibile | WordPress, MariaDB, Redis |
| `/compose/minimal.yml` | Sito leggero, WP-Cron nativo, niente Redis | WordPress, MariaDB |
| `/compose/external.yml` | Database e Redis gestiti esternamente | WordPress |
| `/compose/mysql.yml` | Variante con MySQL 8.4 | WordPress, MySQL, Redis |
| `/compose/immutable.yml` | Codice baked nell'immagine | Upload, MariaDB, Redis |

Nel Compose standard, esterno e immutabile sono disponibili i profili opzionali `worker` e `backup`. Attivarli in Coolify con `COMPOSE_PROFILES=worker`, `backup` oppure `worker,backup`. La variante MySQL espone il solo profilo `worker`.

La matrice completa e i criteri di scelta sono in [docs/PROFILES.md](docs/PROFILES.md).

## Componenti pinati

| Componente | Default |
| --- | --- |
| OpenLiteSpeed + PHP | `litespeedtech/openlitespeed:1.8.5-lsphp83` |
| WordPress | `7.0.2` |
| WP-CLI | `2.12.0`, download verificato SHA-512 |
| MariaDB | `11.8.8` |
| MySQL | `8.4.10` |
| Redis | `7.4.9-bookworm` |
| LiteSpeed Cache | `7.8.1` |
| Redis Object Cache | `2.8.0` |
| ElasticPress | `5.3.3` |
| S3 Uploads | `3.0.13`, dipendenze Composer bloccate |
| Restic | `0.18.1` |

Il Dockerfile individua dinamicamente il runtime LSPHP dell'immagine base e verifica in build tutte le estensioni richieste. Per cambiare PHP si cambia `OPENLITESPEED_IMAGE`, non il codice del bootstrap.

## Deploy rapido su Coolify

1. Creare una risorsa da repository Git e scegliere il build pack **Docker Compose**.
2. Impostare **Base Directory** su `/`.
3. Scegliere una delle Compose Location della tabella precedente.
4. Configurare almeno:

   - `WORDPRESS_DOMAIN` senza path o porta;
   - `WORDPRESS_TITLE`;
   - `WORDPRESS_ADMIN_USER`;
   - `WORDPRESS_ADMIN_EMAIL`;
   - `WORDPRESS_ADMIN_PASSWORD`, almeno 12 caratteri;
   - le password `SERVICE_PASSWORD_*` richieste dal Compose scelto.

5. Sul solo servizio `wordpress`, assegnare il dominio Coolify come `https://example.com:7080`.
6. Per Multisite a sottodomini, aggiungere anche `https://*.example.com:7080` e configurare DNS/certificato wildcard.
7. Eseguire il deploy e attendere l'healthcheck; il primo bootstrap può richiedere alcuni minuti.

Per `compose/external.yml` servono anche `WORDPRESS_DB_HOST`, `WORDPRESS_DB_NAME`, `WORDPRESS_DB_USER`, `WORDPRESS_DB_PASSWORD` e `WORDPRESS_REDIS_HOST`.

Le credenziali amministrative restano obbligatorie nel modello Compose, ma sono usate solo per la prima installazione. Non vengono riapplicate a un sito già esistente.

## Scelta della topologia

| Risultato | `WORDPRESS_ENABLE_MULTISITE` | `WORDPRESS_MULTISITE_MODE` |
| --- | --- | --- |
| Single-site | `false` | ignorata |
| Multisite in sottocartelle | `true` | `subdirectory` |
| Multisite in sottodomini | `true` | `subdomain` |

Il bootstrap può convertire un single-site esistente in Multisite. Non effettua invece downgrade da Multisite, conversioni tra sottocartelle e sottodomini, cambio dominio o cambio prefisso tabelle: in questi casi si ferma e richiede una migrazione esplicita.

## Preset e manifest

Il preset si sceglie con `WORDPRESS_BOOTSTRAP_PRESET`. `standard` conserva il comportamento predefinito; `minimal` rimuove Redis dal provisioning; `high-traffic` applica policy più conservative; `immutable` disabilita editor e aggiornamenti del filesystem.

Un manifest personalizzato può essere fornito con:

- `WORDPRESS_BOOTSTRAP_MANIFEST`, percorso leggibile nel container; oppure
- `WORDPRESS_BOOTSTRAP_MANIFEST_JSON`, JSON inline gestito come secret/variabile Coolify.

Il manifest viene validato prima di toccare WordPress. Plugin e temi devono avere versione pinata; in modalità immutabile un artefatto richiesto non presente nell'immagine provoca un errore esplicito. Le opzioni che possono modificare contenuti vengono applicate al primo bootstrap e solo nuovamente con `WORDPRESS_MANIFEST_REAPPLY=true`.

Schema, campi ed esempi: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Moduli opt-in

- SMTP: `WORDPRESS_SMTP_MODE=smtp` più host, porta e credenziali.
- S3: target `wordpress-suite` o Compose immutabile, poi `WORDPRESS_MEDIA_STORAGE=s3`.
- Ricerca: `WORDPRESS_SEARCH_MODE=elasticpress` e un endpoint Elasticsearch esterno.
- Worker: `COMPOSE_PROFILES=worker`; processa code Action Scheduler se il plugin applicativo espone il comando WP-CLI.
- Backup: `COMPOSE_PROFILES=backup`; richiede repository e password Restic.

Configurazione completa e limiti: [docs/MODULES.md](docs/MODULES.md).

## Runtime e capacità

`WORDPRESS_RUNTIME_PROFILE` fornisce tre baseline:

| Profilo | LSPHP children | OPcache | Connessioni OLS | Uso indicativo |
| --- | ---: | ---: | ---: | --- |
| `small` | 4 | 128 MiB | 2.000 | sito piccolo |
| `balanced` | 10 | 192 MiB | 10.000 | default |
| `large` | 24 | 384 MiB | 20.000 | traffico elevato, dopo capacity test |

Gli override granulari hanno precedenza. Aumentare processi e buffer senza aumentare RAM/CPU del servizio può peggiorare stabilità e latenza; usare `env/high-traffic.example` come punto di partenza, non come garanzia di capacità.

## Health e osservabilità

Il container `wordpress` espone internamente:

- `/healthz-live.php`: processo web/PHP vivo;
- `/healthz.php`: database raggiungibile, file/config presenti, WordPress installato e topologia coerente.

Le route rispondono soltanto a `127.0.0.1`/`::1`; il proxy pubblico riceve `404`. L'healthcheck Compose usa readiness. I log non stampano password SMTP, S3, Redis o database.

## Aggiornamenti e immutabilità

Nel target mutabile il volume conserva core, plugin e temi. Le versioni del manifest vengono riallineate al bootstrap, ma `WORDPRESS_VERSION` non forza un aggiornamento del core già persistente.

Nel target immutabile core e plugin gestiti sono inclusi nell'immagine, OPcache non controlla timestamp e `DISALLOW_FILE_EDIT`/`DISALLOW_FILE_MODS` sono forzati. Per aggiornare si modifica una versione di build, si ricostruisce e si ridistribuisce; non si aggiorna dal pannello WordPress.

Dettagli e procedura: [docs/IMMUTABLE.md](docs/IMMUTABLE.md).

## Operazioni

Le procedure per backup, inizializzazione Restic, restore, WP-CLI, DNS, troubleshooting e verifica post-deploy sono in [docs/OPERATIONS.md](docs/OPERATIONS.md). Le migrazioni tra stack sono in [docs/MIGRATION.md](docs/MIGRATION.md).

Comandi di controllo rapidi dalla console Coolify del servizio `wordpress`:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html option get home
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html plugin status
```

Per Multisite:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed --network
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html site list
```

## Validazione locale

```bash
cp .env.example .env
# Sostituire tutti i placeholder.
./tests/validate.sh
docker compose build wordpress
docker compose up -d --wait --wait-timeout 600
```

`.env` è ignorato da Git. Non usare `docker compose down --volumes` su una risorsa con dati da conservare.

## Documentazione

- [Profili, target e stack](docs/PROFILES.md)
- [Variabili, preset e manifest](docs/CONFIGURATION.md)
- [SMTP, S3, Redis, ricerca e worker](docs/MODULES.md)
- [Backup, restore, health e troubleshooting](docs/OPERATIONS.md)
- [Modalità immutabile](docs/IMMUTABLE.md)
- [Migrazioni tra profili](docs/MIGRATION.md)
