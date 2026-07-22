# Moduli opzionali

## Redis

Lo stack standard usa Redis interno senza porta pubblica. Lo stack external supporta servizi Redis gestiti, ACL e TLS.

```dotenv
WORDPRESS_ENABLE_REDIS=true
WORDPRESS_REDIS_HOST=redis.example.internal
WORDPRESS_REDIS_PORT=6380
WORDPRESS_REDIS_SCHEME=tls
WORDPRESS_REDIS_DATABASE=0
WORDPRESS_REDIS_USERNAME=default
WORDPRESS_REDIS_PASSWORD=secret
WORDPRESS_REDIS_TLS_CA=/run/secrets/redis-ca.pem
```

`WORDPRESS_REDIS_TLS_CA` è opzionale, ma se valorizzato deve essere un file leggibile nel container. Le credenziali restano variabili runtime e non vengono scritte in chiaro dal blocco gestito di `wp-config.php`.

Il bootstrap attende Redis per un massimo di circa 60 secondi. Se Redis non risponde, WordPress viene avviato con `WP_REDIS_DISABLED=true`; il database rimane il requisito hard. Al redeploy successivo, Redis viene riabilitato automaticamente se torna disponibile.

## SMTP

L'integrazione SMTP è un MU-plugin e configura l'istanza PHPMailer di WordPress. Non include un server mail.

```dotenv
WORDPRESS_SMTP_MODE=smtp
WORDPRESS_SMTP_HOST=smtp.example.com
WORDPRESS_SMTP_PORT=587
WORDPRESS_SMTP_ENCRYPTION=tls
WORDPRESS_SMTP_AUTH=true
WORDPRESS_SMTP_USERNAME=apikey
WORDPRESS_SMTP_PASSWORD=secret
WORDPRESS_SMTP_FROM_EMAIL=no-reply@example.com
WORDPRESS_SMTP_FROM_NAME=Example Network
WORDPRESS_SMTP_VERIFY_TLS=true
WORDPRESS_SMTP_TIMEOUT_SECONDS=15
```

Valori di encryption: `none`, `tls`, `ssl`. Disattivare `WORDPRESS_SMTP_VERIFY_TLS` solo per staging controllato con certificati privati; in produzione lasciare `true`.

L'integrazione registra soltanto il messaggio sanitizzato degli errori `wp_mail`, non username o password. Dopo la configurazione, inviare una mail di test da staging e verificare SPF, DKIM e DMARC nel provider.

## Media S3/S3-compatible

Il modulo usa il pacchetto Human Made S3 Uploads incluso con Composer nel target `wordpress-suite` e `wordpress-immutable-suite`.

Per il Compose standard:

```dotenv
WORDPRESS_IMAGE_TARGET=wordpress-suite
WORDPRESS_MEDIA_STORAGE=s3
WORDPRESS_S3_BUCKET=example-media
WORDPRESS_S3_REGION=eu-south-1
WORDPRESS_S3_ACCESS_KEY=secret-id
WORDPRESS_S3_SECRET_KEY=secret-key
WORDPRESS_S3_OBJECT_ACL=private
```

Per un servizio S3-compatible:

```dotenv
WORDPRESS_S3_ENDPOINT=https://s3.example.com
WORDPRESS_S3_PATH_STYLE=true
WORDPRESS_S3_BUCKET_URL=https://cdn.example.com
WORDPRESS_S3_CHECKSUM_WHEN_REQUIRED=true
```

Su infrastruttura AWS con ruolo associato:

```dotenv
WORDPRESS_S3_USE_INSTANCE_PROFILE=true
WORDPRESS_S3_ACCESS_KEY=
WORDPRESS_S3_SECRET_KEY=
```

Opzioni aggiuntive:

- `WORDPRESS_S3_SESSION_TOKEN` per credenziali temporanee;
- `WORDPRESS_S3_AUTOENABLE=true` per usare S3 automaticamente;
- `WORDPRESS_S3_USE_LOCAL=true` per conservare anche la copia locale;
- `WORDPRESS_S3_CACHE_CONTROL_SECONDS=31536000`;
- `WORDPRESS_S3_OBJECT_ACL=private` o ACL supportata dal provider.

Prima di abilitare S3 su un sito esistente:

1. eseguire un backup del volume upload e del database;
2. testare endpoint, CORS, ACL e URL CDN in staging;
3. migrare gli oggetti esistenti con gli strumenti del plugin/provider;
4. verificare immagini originali, thumbnail, PDF e cancellazioni;
5. mantenere il backup locale finché il restore non è provato.

L'attivazione non trasferisce automaticamente i media storici.

## Ricerca esterna

La suite installa ElasticPress e lo collega a un cluster Elasticsearch esterno:

```dotenv
WORDPRESS_SEARCH_MODE=elasticpress
WORDPRESS_SEARCH_HOST=https://elasticsearch.example.com:9200
WORDPRESS_SEARCH_CREDENTIALS=user:password
WORDPRESS_SEARCH_INDEX_PREFIX=coolifywp
WORDPRESS_SEARCH_MULTISITE_ACTIVATION=per-site
WORDPRESS_SEARCH_VERIFY=true
```

Su Multisite, `per-site` attiva ElasticPress in ciascun sito esistente e il MU-plugin lo attiva sui nuovi siti. `network` usa l'attivazione network-wide.

`WORDPRESS_SEARCH_VERIFY=true` esegue `wp elasticpress health-check` durante il bootstrap e rende l'endpoint un requisito di deploy. Lasciarlo `false` se si preferisce che WordPress si avvii anche durante una manutenzione del cluster.

Dopo la prima attivazione, avviare l'indicizzazione da una sessione operativa controllata:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html elasticpress index --setup
```

Per Multisite per-site, eseguire il comando per ogni URL con `--url=...`.

ElasticPress dichiara supporto per Elasticsearch. OpenSearch non viene configurato automaticamente perché non è un backend ufficialmente supportato dal progetto ElasticPress; usarlo richiede una validazione separata e resta fuori dal contratto della suite.

## Worker Action Scheduler

Attivazione:

```dotenv
COMPOSE_PROFILES=worker
WORDPRESS_WORKER_INTERVAL_SECONDS=30
WORDPRESS_ACTION_SCHEDULER_BATCH_SIZE=100
WORDPRESS_ACTION_SCHEDULER_BATCHES=1
WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES=1
```

Filtri opzionali:

```dotenv
WORDPRESS_ACTION_SCHEDULER_GROUP=woocommerce
WORDPRESS_ACTION_SCHEDULER_HOOKS=hook_one,hook_two
```

Il worker:

- usa un lock locale contro cicli sovrapposti;
- itera tutti i siti su Multisite;
- esegue il comando solo se `action-scheduler` è disponibile;
- non sostituisce WP-Cron per plugin che non usano Action Scheduler;
- non crea code e non installa Action Scheduler autonomamente.

Scalare prima batch e concorrenza in staging. Più worker possono creare competizione sul database anche quando il numero di processi PHP è elevato.

## Backup Restic

Il profilo `backup` esegue un dump consistente del database e salva dump più volume WordPress/upload in Restic. Sono supportati repository locali, SFTP e S3 secondo i backend Restic.

Il dump eredita `WORDPRESS_DB_SSL`: nello stack external forza TLS quando il database applicativo è configurato con TLS.

Configurazione minima:

```dotenv
COMPOSE_PROFILES=backup
RESTIC_REPOSITORY=/repository
RESTIC_PASSWORD=a-long-independent-secret
BACKUP_AUTO_INIT=true
```

`BACKUP_AUTO_INIT=true` è comodo solo al primo avvio. Dopo che il repository esiste, riportarlo a `false`.

Retention:

```dotenv
BACKUP_INTERVAL_SECONDS=86400
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
BACKUP_CHECK_INTERVAL_RUNS=7
```

Per un backend S3 Restic usare `RESTIC_REPOSITORY=s3:https://.../bucket/path` e le variabili `BACKUP_AWS_ACCESS_KEY_ID`, `BACKUP_AWS_SECRET_ACCESS_KEY`, `BACKUP_AWS_DEFAULT_REGION`.

Il backup non è considerato operativo finché un restore completo in staging non è riuscito.
