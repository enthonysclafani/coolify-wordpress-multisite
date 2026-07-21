<?php

declare(strict_types=1);

if ($argc !== 3) {
    fwrite(STDERR, "Uso: manage-htaccess.php TARGET TEMPLATE\n");
    exit(2);
}

[$script, $target, $template] = $argv;
unset($script);

$managedBlock = file_get_contents($template);
if ($managedBlock === false || trim($managedBlock) === '') {
    throw new RuntimeException('Template .htaccess assente o vuoto.');
}
$managedBlock = rtrim($managedBlock) . "\n";

$current = is_file($target) ? file_get_contents($target) : '';
if ($current === false) {
    throw new RuntimeException('Impossibile leggere il file .htaccess esistente.');
}

$pattern = '/# BEGIN Coolify WordPress Multisite\R.*?# END Coolify WordPress Multisite\R?/s';
if (preg_match($pattern, $current) === 1) {
    $updated = preg_replace($pattern, $managedBlock, $current, 1);
    if ($updated === null) {
        throw new RuntimeException('Impossibile aggiornare il blocco .htaccess gestito.');
    }
} else {
    $updated = $managedBlock . ($current === '' ? '' : "\n" . ltrim($current));
}

if ($updated !== $current) {
    $temporary = $target . '.tmp';
    if (file_put_contents($temporary, $updated, LOCK_EX) === false || !rename($temporary, $target)) {
        @unlink($temporary);
        throw new RuntimeException('Impossibile scrivere .htaccess in modo atomico.');
    }
}
