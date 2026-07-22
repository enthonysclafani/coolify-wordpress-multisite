# Migrazioni tra profili

## Principio

La scelta di un altro file Compose non è un semplice redeploy. Nomi e contenuto dei volumi, database e responsabilità operative possono cambiare. Creare una nuova risorsa Coolify o un progetto staging, migrare, verificare e poi spostare il traffico.

## Preflight comune

1. Congelare modifiche contenuti o definire una finestra di manutenzione.
2. Registrare commit, Compose Location, variabili non segrete e versioni.
3. Eseguire backup database + file/upload.
4. Verificare il backup con `restic check` o checksum.
5. Creare la destinazione con dominio staging.
6. Validare compatibilità PHP, WordPress, plugin e database.
7. Eseguire un restore completo e test funzionali.
8. Pianificare DNS/proxy e rollback.

## Standard → minimal

Il volume WordPress e MariaDB sono concettualmente compatibili, ma una nuova risorsa genera nuovi volumi.

- ripristinare DB e volume completo;
- impostare `WORDPRESS_ENABLE_REDIS=false`;
- disabilitare/rimuovere il drop-in Redis prima del cutover;
- impostare `WORDPRESS_DISABLE_WP_CRON=false`;
- verificare che WP-Cron riceva traffico sufficiente o predisporre un trigger esterno.

Non copiare il volume Redis: è cache ricostruibile.

## Standard → external

- creare database esterno vuoto con charset/collation compatibili;
- importare il dump e creare l'utente con privilegi limitati al database;
- abilitare TLS e allowlist di rete;
- migrare Redis solo se serve preservare dati non-cache, situazione sconsigliata; normalmente partire vuoto;
- ripristinare il volume WordPress;
- impostare le credenziali esterne e verificare readiness;
- configurare backup nel provider e/o sidecar Restic.

Eseguire un test di latenza: un database esterno distante può peggiorare drasticamente WordPress.

## MariaDB → MySQL 8.4

Non riutilizzare il datadir. Usare dump logico:

1. controllare engine, charset, collation, view, trigger e routine;
2. esportare con transazione consistente;
3. importare in MySQL staging;
4. eseguire `wp core is-installed`, query applicative e test plugin;
5. confrontare conteggio tabelle, utenti, post, opzioni e siti Multisite;
6. correggere incompatibilità SQL nel plugin/app, non nel datadir.

Il rollback usa MariaDB e il suo volume originale, mantenuti intatti fino all'accettazione.

## Mutabile → immutabile

Inventariare prima:

- plugin e temi attivi con versioni;
- MU-plugin personalizzati;
- file persistenti fuori `uploads`;
- modifiche manuali a core/plugin/tema;
- cron e dipendenze Action Scheduler.

Poi:

1. includere ogni artefatto richiesto nell'immagine immutabile e nel manifest;
2. eliminare modifiche manuali o trasformarle in build versionata;
3. copiare soltanto `wp-content/uploads` nel volume destinazione;
4. importare il database;
5. verificare che plugin/tema attivo esista nell'immagine;
6. eseguire test frontend/admin/media/cron;
7. conservare volume completo e immagine precedente per rollback.

## Locale → S3

Abilitare S3 non migra i media storici.

1. costruire target suite e testare credenziali/endpoint;
2. fare backup upload + DB;
3. copiare gli oggetti preservando path e metadata;
4. usare gli strumenti S3 Uploads per upload/verify secondo il provider;
5. verificare URL, thumbnail, private ACL e CDN;
6. solo dopo l'accettazione valutare la rimozione delle copie locali.

Per tornare a locale, ripristinare prima tutti gli oggetti nel path upload corretto e poi impostare `WORDPRESS_MEDIA_STORAGE=local`.

## Cambio dominio

Il bootstrap rifiuta il cambio per evitare sostituzioni parziali. In staging:

```bash
runuser -u nobody -- wp --path=/var/www/vhosts/localhost/html search-replace 'https://old.example.com' 'https://new.example.com' --all-tables-with-prefix --precise --recurse-objects --dry-run
```

Dopo il dry-run, ripetere senza `--dry-run`, aggiornare dominio/network (`wp site`/tabelle Multisite secondo la topologia), DNS, wildcard e Coolify. Fare un backup prima perché le sostituzioni serializzate sono invasive.

## Conversioni Multisite

Single-site → Multisite è supportato dal bootstrap, ma va comunque provato in staging. Multisite → single-site e subdirectory ↔ subdomain non sono automatizzati: richiedono una migrazione WordPress consapevole di tabelle network, mapping siti, upload e URL.

## Cutover e rollback

Prima del cutover:

- ridurre TTL DNS;
- completare un ultimo delta di DB/upload in manutenzione;
- verificare health e checklist nella destinazione;
- spostare dominio/proxy;
- monitorare errori, mail, code e backup.

Rollback:

- ripristinare proxy/DNS verso origine;
- riaprire l'origine soltanto dopo aver gestito eventuali scritture avvenute sulla destinazione;
- non unire database divergenti senza una procedura applicativa specifica.
