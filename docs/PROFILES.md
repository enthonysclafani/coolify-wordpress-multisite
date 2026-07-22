# Profili, target e stack

## Matrice di scelta

| Variante | Compose | Database | Redis | Filesystem WordPress | Cron | Profili opzionali |
| --- | --- | --- | --- | --- | --- | --- |
| Standard | `/docker-compose.yml` | MariaDB interno | interno | volume completo, mutabile | sidecar | `worker`, `backup` |
| Minimal | `/compose/minimal.yml` | MariaDB interno | assente | volume completo, mutabile | nativo WordPress | nessuno |
| External | `/compose/external.yml` | MySQL/MariaDB esterno | esterno | volume completo, mutabile | sidecar | `worker`, `backup` |
| MySQL | `/compose/mysql.yml` | MySQL 8.4 interno | interno | volume completo, mutabile | sidecar | `worker` |
| Immutable | `/compose/immutable.yml` | MariaDB interno | interno | core baked, solo upload persistenti | sidecar | `worker`, `backup` |

Cambiare Compose Location crea una diversa architettura di volumi e servizi. Non farlo su una risorsa esistente senza seguire [MIGRATION.md](MIGRATION.md).

## Preset WordPress

I preset non decidono quali container avviare; decidono policy WordPress, plugin/temi e default del network.

| Preset | Plugin gestiti | Policy update | File editor/mods | Caso d'uso |
| --- | --- | --- | --- | --- |
| `minimal` | LiteSpeed Cache | WordPress default | consentiti | footprint minimo |
| `standard` | LiteSpeed Cache, Redis Object Cache | WordPress default | consentiti | stack predefinito |
| `high-traffic` | LiteSpeed Cache, Redis Object Cache | solo minor core | editor disabilitato | servizi esterni e worker |
| `immutable` | LiteSpeed Cache, Redis Object Cache | disabilitati | entrambi disabilitati | artefatto riproducibile |

Un preset non sovrascrive contenuti esistenti a ogni riavvio. Per riapplicare le opzioni non distruttive usare temporaneamente `WORDPRESS_MANIFEST_REAPPLY=true` e rimetterlo a `false` dopo un deploy riuscito.

## Target Docker

| Target | Core nel volume/runtime | Bundle S3 | Uso |
| --- | --- | --- | --- |
| `final` | scaricato al primo bootstrap | no | default leggero |
| `wordpress-suite` | scaricato al primo bootstrap | sì | S3/S3-compatible |
| `wordpress-immutable` | baked nell'immagine | no | immutabile senza S3 |
| `wordpress-immutable-suite` | baked nell'immagine | sì | immutabile completo |

Nel Compose standard, minimal, external e MySQL il target si seleziona con `WORDPRESS_IMAGE_TARGET`. `compose/immutable.yml` fissa intenzionalmente `wordpress-immutable-suite`.

Il target immutabile incorpora le versioni definite dai build args. Se manifest, `WORDPRESS_VERSION` o `WORDPRESS_LOCALE` non corrispondono all'artefatto, il bootstrap fallisce invece di scaricare codice a runtime.

## Versione PHP/OpenLiteSpeed

`OPENLITESPEED_IMAGE` è un riferimento completo all'immagine base. Il default è:

```text
litespeedtech/openlitespeed:1.8.5-lsphp83
```

È possibile usare una variante ufficiale compatibile, ad esempio la stessa release con `lsphp84`. Il Dockerfile:

1. verifica che esista un solo runtime `/usr/local/lsws/lsphp*/bin/php`;
2. crea il collegamento stabile `/usr/local/bin/stack-php`;
3. verifica estensioni PHP e configurazione OpenLiteSpeed;
4. fallisce la build se il contratto dell'immagine non è rispettato.

Ogni cambio di immagine base va validato con build e smoke test in staging.

## Profilo high-traffic

Non esiste una soglia universale di “alto traffico”. Usare `compose/external.yml` con database e Redis gestiti, quindi applicare i valori di `env/high-traffic.example` e attivare `COMPOSE_PROFILES=worker`.

Il profilo `large` aumenta i limiti del runtime, ma non sostituisce:

- limiti CPU/RAM adeguati in Coolify;
- misurazioni di memoria per processo PHP;
- query profiling e indici database;
- CDN/cache edge;
- test di carico e osservazione di p95/p99;
- backup e restore testati.

## Profili Compose opzionali

`worker` e `backup` non vengono creati senza `COMPOSE_PROFILES`.

```dotenv
COMPOSE_PROFILES=worker
```

oppure:

```dotenv
COMPOSE_PROFILES=worker,backup
```

Il profilo backup deve essere configurato prima dell'attivazione; con `BACKUP_AUTO_INIT=false` un repository Restic inesistente provoca un arresto intenzionale.

## Regole di compatibilità

- La topologia single/Multisite e il tipo Multisite sono decisioni installative.
- Il prefisso tabelle non viene cambiato su un `wp-config.php` esistente.
- MariaDB e MySQL usano volumi diversi; non montare un datadir MariaDB in MySQL o viceversa.
- Passare dal volume completo al target immutabile richiede separare gli upload dal codice.
- S3 non è abilitato dal solo target: serve anche `WORDPRESS_MEDIA_STORAGE=s3`.
- Il worker non installa Action Scheduler; elabora le code quando un plugin/tema lo fornisce.
