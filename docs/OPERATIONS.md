# Operazioni

## DNS e proxy Coolify

Assegnare soltanto al servizio `wordpress` il dominio con porta interna 7080:

```text
https://example.com:7080
```

Per Multisite `subdomain` servono anche:

- record DNS wildcard `*.example.com`;
- dominio Coolify `https://*.example.com:7080`;
- certificato wildcard valido, spesso tramite challenge DNS.

TLS termina nel proxy Coolify. Non aggiungere redirect HTTPS nel virtual host OpenLiteSpeed: il blocco gestito di `wp-config.php` interpreta il primo `X-Forwarded-Proto` e imposta HTTPS internamente.

## Checklist post-deploy

1. Il servizio `wordpress` è healthy.
2. Frontend e `/wp-admin/` rispondono in HTTPS senza loop.
3. `home` e `siteurl` corrispondono a `WORDPRESS_DOMAIN`.
4. La topologia WP-CLI è quella attesa.
5. LiteSpeed Cache è attivo; Redis risulta connected se abilitato.
6. Una mail applicativa di test arriva se SMTP è attivo.
7. Upload, resize e cancellazione funzionano se S3 è attivo.
8. ElasticPress health/index/search funzionano se la ricerca è attiva.
9. Cron e worker non mostrano errori ripetuti.
10. Il repository backup riceve snapshot e un restore staging è pianificato.

Comandi:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html option get home
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html redis status
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html cron event list --due-now
```

Per Multisite:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core is-installed --network
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html site list
```

## Healthcheck

Dentro il container:

```bash
/usr/local/bin/wordpress-healthcheck
WORDPRESS_HEALTHCHECK_MODE=liveness /usr/local/bin/wordpress-healthcheck
```

La readiness controlla database, file/config, installazione e coerenza single/Multisite. Redis, SMTP, S3 ed Elasticsearch non sono requisiti di readiness per evitare che un servizio accessorio tolga dal traffico un WordPress altrimenti valido. La verifica ElasticPress può essere resa bloccante con `WORDPRESS_SEARCH_VERIFY=true` al bootstrap.

## Log

```bash
docker compose logs -f wordpress cron mariadb redis
docker compose --profile worker logs -f worker
docker compose --profile backup logs -f backup
```

In Coolify usare la vista Logs per servizio. Cercare prefissi `[bootstrap]`, `[entrypoint]`, `[cron]`, `[worker]`, `[backup]` e `[coolify-suite]`.

## Backup Restic

### Prima inizializzazione

Configurare un repository e una password indipendente dalle credenziali WordPress. Per un repository locale cifrato nel volume nominato:

```dotenv
RESTIC_REPOSITORY=/repository
RESTIC_PASSWORD=long-independent-secret
BACKUP_AUTO_INIT=true
COMPOSE_PROFILES=backup
```

Dopo il primo log `Repository ... initialized`, impostare `BACKUP_AUTO_INIT=false` e ridistribuire.

Per un repository già inizializzato lasciare sempre `BACKUP_AUTO_INIT=false`.

### Verifica snapshot

Aprire un terminale nel container backup:

```bash
restic snapshots --tag coolify-wordpress-suite
restic check
```

Il sidecar esegue automaticamente `restic check` ogni `BACKUP_CHECK_INTERVAL_RUNS` backup.

### Restore Restic in staging

1. Distribuire lo stesso Compose e la stessa revisione immagine in un progetto staging isolato.
2. Fermare `cron` e `worker`.
3. Nel container backup, scegliere lo snapshot e ripristinare in una directory temporanea:

   ```bash
   restic snapshots --tag coolify-wordpress-suite
   restic restore SNAPSHOT_ID --target /tmp/restore
   ```

4. Importare `wordpress.sql` nel database staging.
5. Per stack mutabile, copiare i file ripristinati nel volume WordPress preservando ownership `nobody:nogroup`.
6. Per stack immutabile, ripristinare solo upload e usare la stessa immagine.
7. Se il dominio staging è diverso, eseguire una sostituzione serializzata con WP-CLI e verificare il network.
8. Avviare WordPress, quindi cron/worker, e completare la checklist post-deploy.

La directory effettiva del dump nello snapshot segue il path `/tmp/wordpress-suite-backup/wordpress.sql`; verificare con `restic ls SNAPSHOT_ID` prima del restore.

## Backup manuale di emergenza

Per lo stack standard:

```bash
docker compose exec -T mariadb sh -c 'mariadb-dump --user=root --password="$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' > wordpress.sql
docker compose exec -T wordpress tar -C /var/www/vhosts/localhost/html -czf - . > wordpress-files.tar.gz
```

Questi file contengono dati sensibili. Cifrarli, trasferirli fuori host e cancellare in modo sicuro le copie temporanee secondo le policy operative.

## Aggiornamenti mutabili

Fare sempre backup e staging. Dalla console `wordpress`:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core update
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core update-db
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html plugin update --all
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html core verify-checksums
```

Su Multisite aggiungere `core update-db --network`. Se il manifest pinna versioni diverse, il bootstrap successivo le riallineerà; aggiornare quindi prima il manifest/versioni versionate.

In modalità immutabile seguire [IMMUTABLE.md](IMMUTABLE.md), non questi comandi.

## Rotazione credenziali

- Database interno: coordinare cambio password nel server DB e `SERVICE_PASSWORD_WORDPRESS`; il bootstrap sincronizza `wp-config.php` solo dopo che le nuove credenziali funzionano.
- Database esterno: ruotare `WORDPRESS_DB_PASSWORD` nel provider e in Coolify con finestra coordinata.
- Redis/SMTP/S3/Elasticsearch: aggiornare le variabili Coolify e ridistribuire; i segreti sono letti a runtime.
- Restic: cambiare password richiede la procedura Restic `key`/repository, non soltanto una variabile.

## Troubleshooting

### Readiness fallisce

Controllare prima i log bootstrap, quindi connettività DB, credenziali, dominio e topologia. La readiness restituisce volutamente un corpo generico; i dettagli rimangono nei log/container per non esporli via HTTP.

### Cambio dominio o topologia rifiutato

È una protezione. Ripristinare il valore originale oppure seguire [MIGRATION.md](MIGRATION.md). Non modificare soltanto le costanti nel database.

### Redis non si abilita

Controllare schema `tcp/tls`, porta, ACL, password, CA montata e `wp redis status`. WordPress resta operativo con cache disabilitata.

### S3 genera errori al bootstrap

Verificare di usare `wordpress-suite`, credenziali, regione, endpoint e path-style. Con `WORDPRESS_MEDIA_STORAGE=local` il loader S3 non carica il bundle.

### Worker non elabora nulla

Il log indica se il comando `action-scheduler` è assente. Verificare che WooCommerce o un altro componente Action Scheduler sia attivo nel sito interessato e che non siano impostati filtri group/hook errati.

### Multisite subdomain 404

Verificare wildcard DNS/proxy/certificato e `SUBDOMAIN_INSTALL=true`. Per subdirectory verificare invece il blocco rewrite gestito in `.htaccess`.

## Azioni da evitare

- `docker compose down --volumes` su ambienti con dati;
- montare un datadir MariaDB nella variante MySQL;
- `chmod -R 777`;
- aggiornare plugin come root;
- pubblicare porte DB/Redis;
- cambiare `WORDPRESS_TABLE_PREFIX` dopo l'installazione;
- lasciare `BACKUP_AUTO_INIT=true` senza una ragione operativa.
