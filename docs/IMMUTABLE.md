# Modalità immutabile

## Obiettivo

`compose/immutable.yml` separa codice e dati:

- core WordPress, plugin gestiti, WP-CLI e moduli sono inclusi nell'immagine;
- il container applicativo è ricreabile;
- persiste soltanto `wp-content/uploads`;
- database e Redis restano volumi dedicati;
- `DISALLOW_FILE_EDIT` e `DISALLOW_FILE_MODS` sono sempre `true`;
- OPcache non verifica timestamp.

“Immutabile” descrive il modello di deploy: il layer scrivibile effimero del container può contenere `wp-config.php`, file cache e MU-plugin generati al bootstrap, ma viene eliminato alla sostituzione del container. Il codice applicativo non è affidato a un volume persistente né agli updater WordPress.

## Build args come contratto

L'immagine include:

```text
WORDPRESS_VERSION
WORDPRESS_LOCALE
LITESPEED_CACHE_VERSION
REDIS_CACHE_VERSION
ELASTICPRESS_VERSION
```

I tre plugin WordPress.org vengono scaricati da URL versionati e verificati anche con i build arg `*_SHA256`. Quando si cambia una versione, aggiornare intenzionalmente il relativo checksum dopo aver verificato l'archivio; un mismatch interrompe la build.

`compose/immutable.yml` inoltra sia le versioni sia i checksum come build arg, quindi possono essere gestiti come variabili Coolify. Versione, checksum e manifest devono essere aggiornati nella stessa revisione.

Il preset `immutable` richiede LiteSpeed Cache e Redis Object Cache. ElasticPress è incluso per consentire il modulo di ricerca senza download runtime. Un manifest personalizzato può richiedere altri plugin o temi soltanto se il Dockerfile viene esteso per includerli.

Se una versione richiesta non coincide, il bootstrap fallisce con un messaggio di rebuild. Non tenta di “riparare” l'immagine scaricando codice.

## Aggiornamento

1. Creare una nuova branch/revisione.
2. Aggiornare i build arg e, se necessario, il manifest.
3. Eseguire build e test statici.
4. Distribuire in staging con una copia del database/upload.
5. Eseguire eventuali `core update-db` o migrazioni plugin.
6. Verificare frontend, admin, cron, Redis e media.
7. Creare un backup recuperabile.
8. Distribuire la stessa immagine/revisione in produzione.

Il rollback consiste nel ridistribuire l'immagine precedente e, se una migrazione DB non è retrocompatibile, ripristinare anche il database.

## Plugin o tema personalizzato

Estendere il target immutabile nel Dockerfile o aggiungere uno stage controllato che:

- scarichi da una fonte autenticata durante la build;
- verifichi checksum/firma;
- copi l'artefatto nella directory WordPress;
- assegni `nobody:nogroup` e permessi 0755/0644;
- esegua lint/scanner pertinenti;
- aggiorni il manifest con versione esatta.

Non inserire token privati nel layer finale. Usare BuildKit secrets per repository privati.

## Cron e worker

I sidecar immutabili usano la stessa immagine ma non condividono il root WordPress. Dopo che `wordpress` è healthy, eseguono un bootstrap CLI locale con `WORDPRESS_CLI_BOOTSTRAP=true`, ricreano il proprio `wp-config.php` effimero e accedono allo stesso database/upload.

Questo evita un volume di codice condiviso. La dipendenza dall'health del container principale impedisce che più container tentino la prima installazione contemporaneamente.

## Backup

Nel profilo immutabile Restic salva:

- dump del database;
- volume upload.

Non salva core/plugin/temi perché devono essere ripristinati dalla stessa revisione immagine. Conservare quindi insieme a ogni backup:

- digest/tag immagine;
- commit Git;
- manifest e hash;
- valori non segreti delle variabili di configurazione.

## Limiti

- Aggiornamenti e installazioni dal pannello WordPress sono intenzionalmente bloccati.
- Temi/plugin che scrivono nella propria directory non sono compatibili senza una directory runtime dedicata.
- Un plugin che usa file persistenti fuori da `uploads` richiede un volume esplicito e una valutazione di sicurezza.
- Il passaggio da mutabile a immutabile non copia automaticamente upload o plugin personalizzati.
