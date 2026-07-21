<?php

declare(strict_types=1);

if ($argc !== 2) {
    fwrite(STDERR, "Uso: manage-wp-config.php WP_CONFIG\n");
    exit(2);
}

$target = $argv[1];
$current = file_get_contents($target);
if ($current === false) {
    throw new RuntimeException('Impossibile leggere wp-config.php.');
}

$managedBlock = <<<'PHP'
/* BEGIN Coolify reverse proxy HTTPS */
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO'])) {
    $forwarded_protocol = strtolower(trim(explode(',', (string) $_SERVER['HTTP_X_FORWARDED_PROTO'])[0]));
    if ($forwarded_protocol === 'https') {
        $_SERVER['HTTPS'] = 'on';
        $_SERVER['SERVER_PORT'] = 443;
    }
}
/* END Coolify reverse proxy HTTPS */
PHP;
$managedBlock .= "\n\n";

$pattern = '/\/\* BEGIN Coolify reverse proxy HTTPS \*\/.*?\/\* END Coolify reverse proxy HTTPS \*\/\R*/s';
if (preg_match($pattern, $current) === 1) {
    $updated = preg_replace($pattern, $managedBlock, $current, 1);
    if ($updated === null) {
        throw new RuntimeException('Impossibile aggiornare il blocco proxy gestito.');
    }
} else {
    $stopEditingPosition = strpos($current, "/* That's all, stop editing!");
    if ($stopEditingPosition === false) {
        $stopEditingPosition = strpos($current, 'require_once ABSPATH');
    }
    if ($stopEditingPosition === false) {
        throw new RuntimeException('Punto di inserimento sicuro non trovato in wp-config.php.');
    }
    $updated = substr($current, 0, $stopEditingPosition)
        . $managedBlock
        . substr($current, $stopEditingPosition);
}

if ($updated !== $current) {
    $permissions = fileperms($target);
    $temporary = $target . '.tmp';
    if (file_put_contents($temporary, $updated, LOCK_EX) === false) {
        throw new RuntimeException('Impossibile creare il file wp-config.php temporaneo.');
    }
    if ($permissions !== false) {
        chmod($temporary, $permissions & 0777);
    }
    if (!rename($temporary, $target)) {
        @unlink($temporary);
        throw new RuntimeException('Impossibile sostituire wp-config.php in modo atomico.');
    }
}
