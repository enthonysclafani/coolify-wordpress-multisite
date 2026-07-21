# WordPress single-site o Multisite su OpenLiteSpeed per Coolify

Stack Docker completo per distribuire con un solo deploy **WordPress single-site** oppure **WordPress Multisite**, in sottocartelle o sottodomini, dietro il reverse proxy HTTPS di **Coolify**. L'installazione iniziale è automatica e idempotente: due variabili scelgono la topologia e non servono procedura guidata nel browser, modifiche manuali a `wp-config.php` o `.htaccess`, SSH o comandi post-deploy.

> Eseguire sempre il primo deploy e le procedure di backup/ripristino in staging prima di usare lo stack in produzione.

## Componenti e versioni

| Componente | Versione/immagine | Note |
| --- | --- | --- |
| OpenLiteSpeed + LSPHP | `litespeedtech/openlitespeed:1.8.5-lsphp83` | Immagine mantenuta da LiteSpeed, PHP 8.3 |
| WordPress | `7.0.2` | Versione iniziale pinata e modificabile con `WORDPRESS_VERSION` |
| WP-CLI | `2.12.0` | PHAR scaricato in build e verificato con SHA-512 |
| MariaDB | `mariadb:11.8.8` | Immagine Docker ufficiale |
| Redis | `redis:7.4.9-bookworm` | Immagine Docker ufficiale, AOF attivo |
| Plugin | LiteSpeed Cache `7.8.1`, Redis Object Cache `2.8.0` | Installati da WordPress.org e attivati sul sito o sull'intero network |

L'immagine OpenLiteSpeed scelta contiene già `mysqli`, `pdo_mysql`, `curl`, `gd`, `intl`, `mbstring`, `zip`, `exif`, OPcache, PhpRedis e Imagick. Il Dockerfile ne verifica la presenza durante la build.

## Architettura

- `wordpress`: OpenLiteSpeed sulla porta interna **7080**, LSPHP 8.3, WP-CLI e bootstrap.
- `mariadb`: database privato, senza porte host pubblicate.
- `redis`: object cache privata, senza porte host pubblicate, persistenza AOF e policy `allkeys-lru`.
- `cron`: esegue `wp cron event run --due-now` ogni cinque minuti quando WP-Cron nativo è disabilitato, con lock contro esecuzioni concorrenti.

I volumi nominati persistono esclusivamente i file WordPress, il database e i dati Redis. La configurazione OpenLiteSpeed resta nell'immagine: nessun volume può nascondere i file forniti dal vendor. La WebAdmin è disabilitata. La sua porta dichiarata dall'immagine base, `7080`, viene riutilizzata dal listener frontend WordPress, così l'immagine espone una sola porta interna e nessuna console amministrativa; TLS termina nel proxy di Coolify.

## Requisiti

- Coolify con supporto alle magic environment variables per repository Git (`v4.0.0-beta.411` o successivo).
- Un server Coolify con Docker Compose e spazio sufficiente per file, database e backup.
- Un dominio con accesso alla gestione DNS.
- SMTP esterno se WordPress deve spedire email: lo stack non include un MTA.

## Deploy esatto su Coolify

1. In un progetto Coolify, scegliere **Create New Resource** → **Public Repository**.
2. Inserire `https://github.com/enthonysclafani/coolify-wordpress-multisite`.
3. Lasciare il branch `main`.
4. Scegliere il build pack **Docker Compose**.
5. Impostare **Base Directory** su `/` e **Docker Compose Location** su `/docker-compose.yml`.
6. Continuare e compilare le variabili obbligatorie mostrate da Coolify. Le due variabili `SERVICE_PASSWORD_*` sono magic variables: Coolify genera valori casuali persistenti; non sostituirli con gli esempi di `.env.example`.
7. Nella sezione Domains del solo servizio **`wordpress`**, assegnare `https://example.com:7080`, sostituendo il dominio. Il suffisso `:7080` indica a Coolify la porta interna; il sito pubblico resta sulla normale porta HTTPS 443. Su questa porta risponde WordPress, non la WebAdmin.
8. Non assegnare domini né port mapping a `mariadb`, `redis` o `cron`.
9. Premere **Deploy**. Il primo avvio può richiedere alcuni minuti; l'healthcheck concede fino a cinque minuti al bootstrap.

Con i default viene creato un Multisite in sottocartelle. Per un single-site impostare `WORDPRESS_ENABLE_MULTISITE=false`; per un network a sottodomini lasciare Multisite attivo e impostare `WORDPRESS_MULTISITE_MODE=subdomain`. In quest'ultimo caso configurare prima anche DNS e dominio wildcard come descritto nella sezione successiva.

Al termine aprire `/wp-admin/`. Per Multisite il Network Admin è:

```text
https://example.com/wp-admin/network/
```

Accedere con `WORDPRESS_ADMIN_USER` e `WORDPRESS_ADMIN_PASSWORD`. Non compare alcuna procedura guidata WordPress in nessuna delle tre modalità.

## DNS

Creare un record `A` del dominio verso l'IPv4 pubblica del server Coolify e, solo se il server è raggiungibile correttamente via IPv6, un record `AAAA`. Per `www` scegliere un ulteriore record e una strategia di redirect in Coolify; `WORDPRESS_DOMAIN` deve contenere l'host canonico effettivamente usato dal sito o network.

La modalità `subdomain` richiede inoltre:

- un record DNS wildcard `*.example.com` verso lo stesso server;
- un dominio wildcard `https://*.example.com:7080` assegnato al servizio `wordpress` in Coolify, oltre al dominio principale;
- un certificato TLS valido per il wildcard. Coolify può richiederne l'emissione tramite challenge DNS, secondo il provider e la configurazione usati.

Questi elementi infrastrutturali non possono essere creati dal bootstrap WordPress. Senza wildcard DNS/proxy, il network viene configurato correttamente ma i siti secondari non sono raggiungibili.

Attendere la propagazione DNS, quindi lasciare che Coolify emetta e rinnovi il certificato. Non configurare certificati o redirect HTTPS dentro OpenLiteSpeed.

## Variabili d'ambiente

### Obbligatorie

| Variabile | Esempio | Descrizione |
| --- | --- | --- |
| `WORDPRESS_DOMAIN` | `example.com` | Dominio canonico. Accetta anche `https://example.com/` o `http://example.com/`; rifiuta path, query, credenziali e porte. |
| `WORDPRESS_TITLE` | `Example Network` | Titolo iniziale del sito o network. |
| `WORDPRESS_ADMIN_USER` | `networkadmin` | Username amministratore, massimo 60 caratteri. |
| `WORDPRESS_ADMIN_EMAIL` | `admin@example.com` | Email valida dell'amministratore. |
| `WORDPRESS_ADMIN_PASSWORD` | valore segreto | Almeno 12 caratteri; non viene scritto nei log. |
| `SERVICE_PASSWORD_MARIADB` | generata da Coolify | Password root MariaDB. |
| `SERVICE_PASSWORD_WORDPRESS` | generata da Coolify | Password dell'utente DB `wordpress`. |

Le credenziali amministrative sono richieste dal Compose a ogni deploy, ma vengono usate per creare l'utente soltanto quando WordPress non è già installato.

### Opzionali

| Variabile | Default | Effetto |
| --- | --- | --- |
| `WORDPRESS_LOCALE` | `it_IT` | Locale scaricato e attivato. |
| `WORDPRESS_TIMEZONE` | `Europe/Rome` | Timezone WordPress e PHP. |
| `WORDPRESS_DEBUG` | `false` | Controlla `WP_DEBUG` e `WP_DEBUG_LOG`; l'output a schermo resta disattivato. |
| `WORDPRESS_TABLE_PREFIX` | `wp_` | Prefisso tabelle, usato solo quando viene creato `wp-config.php`. |
| `WORDPRESS_SKIP_EMAIL` | `true` | Evita l'email durante l'installazione iniziale. |
| `WORDPRESS_ENABLE_MULTISITE` | `true` | `false` installa un single-site; `true` installa o converte automaticamente a Multisite. |
| `WORDPRESS_MULTISITE_MODE` | `subdirectory` | Accetta `subdirectory` o `subdomain`; viene applicata quando Multisite è attivo. |
| `WORDPRESS_INSTALL_PLUGINS` | `true` | Installa e attiva i due plugin sul sito oppure sull'intero network. |
| `WORDPRESS_ENABLE_REDIS` | `true` | Abilita il drop-in Redis dopo i controlli di connettività. |
| `WORDPRESS_DISABLE_WP_CRON` | `true` | Imposta `DISABLE_WP_CRON` e abilita il runner separato. |
| `WORDPRESS_CRON_INTERVAL_SECONDS` | `300` | Intervallo cron; minimo 60 secondi. |
| `WORDPRESS_MEMORY_LIMIT` | `256M` | `WP_MEMORY_LIMIT`. |
| `WORDPRESS_MAX_MEMORY_LIMIT` | `512M` | `WP_MAX_MEMORY_LIMIT`. |
| `WORDPRESS_VERSION` | `7.0.2` | Versione scaricata soltanto quando i file core sono assenti. |
| `PHP_UPLOAD_MAX_FILESIZE` | `1024M` | `upload_max_filesize`. |
| `PHP_POST_MAX_SIZE` | `1024M` | `post_max_size`. |
| `PHP_MEMORY_LIMIT` | `512M` | `memory_limit` di PHP. |

I booleani accettano `true/false`, `1/0`, `yes/no` oppure `on/off`.

### Scelta della modalità

| Risultato | `WORDPRESS_ENABLE_MULTISITE` | `WORDPRESS_MULTISITE_MODE` |
| --- | --- | --- |
| WordPress single-site | `false` | ignorata, lasciare `subdirectory` |
| Multisite in sottocartelle (`example.com/demo/`) | `true` | `subdirectory` |
| Multisite in sottodomini (`demo.example.com`) | `true` | `subdomain` |

Il default resta `true` + `subdirectory`, quindi i deploy esistenti mantengono il comportamento precedente senza aggiungere variabili.

La topologia non è un interruttore distruttivo su dati esistenti: un single-site può essere convertito automaticamente in Multisite, ma un network esistente non viene mai ridotto automaticamente a single-site e non viene convertito tra sottodomini e sottocartelle. In questi due casi il bootstrap si ferma prima di alterare la topologia e richiede una migrazione esplicita.

## Cosa fa il bootstrap

Ad ogni avvio lo script:

1. valida e normalizza il dominio in host pulito e URL `https://`;
2. genera la configurazione PHP dai valori runtime;
3. attende MariaDB e, quando richiesto, Redis;
4. scarica WordPress soltanto se i file core sono assenti;
5. crea `wp-config.php` soltanto se assente;
6. installa WordPress single-site oppure installa/converte Multisite con la topologia richiesta;
7. sincronizza o rimuove in sicurezza le costanti Multisite e configura memoria, cron, cache, debug e Redis;
8. inserisce un blocco gestito per `HTTP_X_FORWARDED_PROTO=https` prima del caricamento di WordPress;
9. aggiorna esclusivamente il blocco rewrite gestito in `.htaccess`, conservando le regole esterne;
10. nei network a sottodomini installa un MU-plugin gestito che forza HTTPS sui nuovi siti e riallinea quelli esistenti;
11. installa e attiva i plugin in modo idempotente;
12. avvia LSPHP come utente `nobody` e OpenLiteSpeed in modalità foreground.

Se un volume contiene un dominio o una topologia diversi da quelli richiesti, il bootstrap fallisce chiaramente invece di alterare parzialmente URL o struttura del database. Un cambio dominio, un downgrade da Multisite o un passaggio tra sottodomini e sottocartelle richiedono una migrazione WordPress esplicita.

## HTTPS dietro Coolify

WordPress conserva URL HTTPS, mentre OpenLiteSpeed riceve HTTP sulla rete Docker. Il blocco gestito in `wp-config.php` considera soltanto il primo valore di `HTTP_X_FORWARDED_PROTO` e imposta `$_SERVER['HTTPS'] = 'on'` e la porta 443 quando vale esattamente `https`. Non viene considerato `HTTP_X_FORWARDED_HOST`, così un header Host inoltrato non può modificare il dominio canonico.

Non aggiungere redirect HTTPS nel virtual host: sarebbe facile creare un loop con il proxy. L'healthcheck usa `127.0.0.1`, un header Host locale e una route PHP dedicata, senza dipendere dal DNS pubblico.

## WP-CLI dalla console Coolify

Aprire **Terminal** sul servizio `wordpress` ed eseguire WP-CLI come l'utente che possiede i file:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html plugin status litespeed-cache
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html redis status
```

Solo su Multisite, per verificare il network ed elencare i siti:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed --network
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html site list
```

Nei network `subdomain` il MU-plugin gestito corregge automaticamente anche gli URL dei siti creati da WP-CLI:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html site create --slug=demo --title="Demo" --email=admin@example.com
```

In alternativa, come root, aggiungere `--allow-root` a ogni comando. Evitare aggiornamenti eseguiti come root per non cambiare l'ownership dei file.

## Aggiornamenti

### Stack e immagini

Aggiornare il repository/branch in Coolify e premere **Redeploy**. Le immagini sono pinate: l'aggiornamento intenzionale di OpenLiteSpeed, MariaDB, Redis o WP-CLI richiede una modifica versionata del repository e un test in staging.

### WordPress e plugin già persistenti

`WORDPRESS_VERSION` non forza downgrade o reinstallazioni su un volume esistente. Dalla console `wordpress`:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core update
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core update-db
# Solo Multisite:
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core update-db --network
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html plugin update --all
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core verify-checksums
```

Eseguire backup e staging prima. Dopo impostazioni LiteSpeed Cache che modificano `.htaccess`, riavviare il servizio `wordpress`: OpenLiteSpeed rilegge `.htaccess` al riavvio.

## Backup

Un backup recuperabile deve includere almeno **database MariaDB** e **volume WordPress**, deve essere copiato fuori dal server e deve essere testato con un ripristino. Redis è una cache ricostruibile; il suo backup è facoltativo.

Da una macchina con il checkout e accesso Docker allo stack:

```bash
mkdir -p backups
docker compose exec -T mariadb sh -c 'mariadb-dump --user=root --password="$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' > backups/wordpress.sql
docker compose exec -T wordpress tar -C /var/www/vhosts/localhost/html -czf - . > backups/wordpress-files.tar.gz
```

Con Coolify i nomi reali dei container includono l'UUID della risorsa. Se i comandi `docker compose` non sono disponibili dalla UI, eseguire gli equivalenti sul server usando i container della risorsa oppure integrare un job di backup esterno. Conservare le copie cifrate in storage remoto con retention e controllo periodico.

## Ripristino

Provare prima in staging. Fermare il traffico o mettere il sito in manutenzione, verificare che le variabili e il dominio corrispondano al backup, quindi:

```bash
docker compose stop cron wordpress
docker compose exec -T mariadb sh -c 'mariadb --user=root --password="$MARIADB_ROOT_PASSWORD" wordpress' < backups/wordpress.sql
docker compose run --rm --no-deps --entrypoint tar wordpress -C /var/www/vhosts/localhost/html -xzf - < backups/wordpress-files.tar.gz
docker compose start wordpress cron
```

Controllare poi `wp core is-installed`, il frontend e l'area amministrativa. Su Multisite controllare anche `wp core is-installed --network`, `wp site list` e il Network Admin. Non usare `docker compose down --volumes`: elimina i dati persistenti.

## Log

In Coolify aprire **Logs** per ciascun servizio:

- `wordpress`: bootstrap, error log e access log OpenLiteSpeed;
- `cron`: esecuzioni WP-Cron e lock;
- `mariadb`: inizializzazione, upgrade e query critiche;
- `redis`: caricamento AOF e stato del server.

Da terminale locale:

```bash
docker compose logs -f wordpress cron mariadb redis
```

## Disabilitare Redis

Impostare `WORDPRESS_ENABLE_REDIS=false` e fare redeploy. Il bootstrap rimuove il drop-in con `wp redis disable` e disattiva `redis-cache` sul sito o network; eventuali errori vengono segnalati senza distruggere WordPress. Il servizio Redis resta privato e disponibile nello stack per consentire una riattivazione reversibile.

## Impedire reinstallazioni

Il comportamento normale è già idempotente. Per conservare l'installazione:

- non eliminare i volumi `wordpress_data` e `mariadb_data`;
- non usare `docker compose down --volumes`;
- non cambiare `WORDPRESS_DOMAIN` senza una migrazione completa;
- non cambiare `WORDPRESS_ENABLE_MULTISITE` da `true` a `false` su un network esistente;
- non cambiare `WORDPRESS_MULTISITE_MODE` dopo la creazione del network;
- mantenere stabili le password database già usate dal volume MariaDB.

Riavvio e redeploy riusano `wp-config.php`, file e tabelle esistenti. Titolo, utente e password admin non vengono riapplicati a WordPress già installato.

## Troubleshooting

### Il servizio `wordpress` non diventa healthy

Leggere prima i log del bootstrap. Controllare variabili obbligatorie, validità del dominio, health di MariaDB/Redis e spazio disco. La route locale è `http://127.0.0.1:7080/healthz.php` dentro il container.

### Redirect loop o URL HTTP

Verificare che il dominio Coolify punti a `wordpress:7080`, che il proxy invii `X-Forwarded-Proto: https` e che `WORDPRESS_DOMAIN` non contenga un dominio diverso. Non aggiungere redirect HTTPS in OpenLiteSpeed.

### Siti secondari Multisite restituiscono 404

In modalità `subdirectory`, controllare che `SUBDOMAIN_INSTALL` sia `false` e provare `/demo/`. In modalità `subdomain`, controllare che sia `true`, verificare DNS e dominio wildcard e provare `demo.example.com`. In entrambi i casi `.htaccess` deve contenere un solo blocco `Coolify WordPress Managed`; riavviare `wordpress` dopo modifiche alle rewrite.

### Il bootstrap rifiuta un cambio di modalità

È una protezione intenzionale. `WORDPRESS_ENABLE_MULTISITE=false` non trasforma un network esistente in single-site e `WORDPRESS_MULTISITE_MODE` non converte un network tra sottodomini e sottocartelle. Ripristinare le variabili originali oppure migrare database e contenuti verso una nuova installazione con la topologia desiderata.

### Redis non è connesso

Eseguire `wp redis status`, controllare il servizio `redis` e verificare che l'estensione `redis` sia caricata con `php -m`. Il bootstrap emette un warning e lascia WordPress operativo se l'abilitazione Redis fallisce.

### Le email non partono

`WORDPRESS_SKIP_EMAIL=true` sopprime soltanto l'email di installazione. Configurare un provider SMTP affidabile tramite plugin o MU-plugin; il container non include `sendmail`.

### Permessi

File WordPress e processi PHP appartengono a `nobody:nogroup`; il bootstrap corregge ricorsivamente l'ownership solo quando rileva una discrepanza. Non usare `chmod -R 777`.

## Limiti e compromessi

- Redis non richiede password perché è raggiungibile soltanto dalla rete Docker privata e non pubblica alcuna porta. Se altri workload non fidati condividono forzatamente la stessa rete, introdurre autenticazione prima della produzione.
- OpenLiteSpeed Community rilegge cambi `.htaccess` al riavvio; alcune opzioni LiteSpeed Cache richiedono quindi un restart del servizio web.
- La cache pagina risiede nel backend OpenLiteSpeed. HTTP/3 pubblico dipende dal proxy di Coolify, non dal listener HTTP interno; il listener QUIC interno è disabilitato.
- Lo stack non include SMTP, backup remoto, antivirus o WAF: sono responsabilità operative esterne.

## Sviluppo e validazione locale

```bash
cp .env.example .env
# Sostituire tutti i placeholder prima di proseguire.
docker compose config
docker compose build --pull
docker compose up -d --wait --wait-timeout 600
docker compose exec --user 65534:65534 wordpress wp --path=/var/www/vhosts/localhost/html core is-installed
# Solo quando WORDPRESS_ENABLE_MULTISITE=true:
docker compose exec --user 65534:65534 wordpress wp --path=/var/www/vhosts/localhost/html core is-installed --network
```

`.env` è ignorato da Git. Al termine del test, `docker compose down --volumes` elimina **irreversibilmente** soltanto i volumi locali di quello stack di prova.

## Riferimenti tecnici

- [Immagine OpenLiteSpeed ufficiale](https://hub.docker.com/r/litespeedtech/openlitespeed/tags)
- [Docker con OpenLiteSpeed](https://docs.openlitespeed.org/installation/docker/)
- [Rewrite e AutoLoad `.htaccess`](https://docs.openlitespeed.org/config/rewriterules/)
- [Docker Compose su Coolify](https://coolify.io/docs/applications/build-packs/docker-compose)
- [Networking e magic variables Compose in Coolify](https://coolify.io/docs/knowledge-base/docker/compose)
- [Verifica dei download WP-CLI](https://make.wordpress.org/cli/handbook/guides/verifying-downloads/)
