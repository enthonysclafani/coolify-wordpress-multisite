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

$proxyBlock = <<<'PHP'
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

$runtimeBlock = <<<'PHP'
/* BEGIN Coolify suite runtime */
$coolify_env_bool = static function (string $name, bool $default = false): bool {
    $value = getenv($name);
    if (! is_string($value) || $value === '') {
        return $default;
    }
    return in_array(strtolower($value), ['true', '1', 'yes', 'on'], true);
};

$coolify_redis_password = getenv('WORDPRESS_REDIS_PASSWORD');
$coolify_redis_username = getenv('WORDPRESS_REDIS_USERNAME');
if (! defined('WP_REDIS_PASSWORD') && is_string($coolify_redis_password) && $coolify_redis_password !== '') {
    define(
        'WP_REDIS_PASSWORD',
        is_string($coolify_redis_username) && $coolify_redis_username !== ''
            ? [$coolify_redis_username, $coolify_redis_password]
            : $coolify_redis_password
    );
}

$coolify_redis_ca = getenv('WORDPRESS_REDIS_TLS_CA');
if (! defined('WP_REDIS_SSL_CONTEXT') && is_string($coolify_redis_ca) && $coolify_redis_ca !== '') {
    define(
        'WP_REDIS_SSL_CONTEXT',
        [
            'cafile' => $coolify_redis_ca,
            'verify_peer' => true,
            'verify_peer_name' => true,
        ]
    );
}

if ($coolify_env_bool('WORDPRESS_DB_SSL') && ! defined('MYSQL_CLIENT_FLAGS') && defined('MYSQLI_CLIENT_SSL')) {
    define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);
}

if (getenv('WORDPRESS_SEARCH_MODE') === 'elasticpress') {
    $coolify_search_host = getenv('WORDPRESS_SEARCH_HOST');
    $coolify_search_credentials = getenv('WORDPRESS_SEARCH_CREDENTIALS');
    $coolify_search_index_prefix = getenv('WORDPRESS_SEARCH_INDEX_PREFIX');
    if (! defined('EP_HOST') && is_string($coolify_search_host) && $coolify_search_host !== '') {
        define('EP_HOST', $coolify_search_host);
    }
    if (! defined('EP_CREDENTIALS') && is_string($coolify_search_credentials) && $coolify_search_credentials !== '') {
        define('EP_CREDENTIALS', $coolify_search_credentials);
    }
    if (! defined('EP_INDEX_PREFIX') && is_string($coolify_search_index_prefix) && $coolify_search_index_prefix !== '') {
        define('EP_INDEX_PREFIX', $coolify_search_index_prefix);
    }
}

unset(
    $coolify_env_bool,
    $coolify_redis_password,
    $coolify_redis_username,
    $coolify_redis_ca,
    $coolify_search_host,
    $coolify_search_credentials,
    $coolify_search_index_prefix
);
/* END Coolify suite runtime */
PHP;

$blocks = [
    [
        'pattern' => '/\/\* BEGIN Coolify reverse proxy HTTPS \*\/.*?\/\* END Coolify reverse proxy HTTPS \*\/\R*/s',
        'block' => $proxyBlock,
    ],
    [
        'pattern' => '/\/\* BEGIN Coolify suite runtime \*\/.*?\/\* END Coolify suite runtime \*\/\R*/s',
        'block' => $runtimeBlock,
    ],
];

$updated = $current;
foreach ($blocks as $managed) {
    $block = rtrim($managed['block']) . "\n\n";
    if (preg_match($managed['pattern'], $updated) === 1) {
        $replacement = preg_replace($managed['pattern'], $block, $updated, 1);
        if ($replacement === null) {
            throw new RuntimeException('Impossibile aggiornare un blocco gestito in wp-config.php.');
        }
        $updated = $replacement;
        continue;
    }

    $stopEditingPosition = strpos($updated, "/* That's all, stop editing!");
    if ($stopEditingPosition === false) {
        $stopEditingPosition = strpos($updated, 'require_once ABSPATH');
    }
    if ($stopEditingPosition === false) {
        throw new RuntimeException('Punto di inserimento sicuro non trovato in wp-config.php.');
    }
    $updated = substr($updated, 0, $stopEditingPosition)
        . $block
        . substr($updated, $stopEditingPosition);
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
    if (! rename($temporary, $target)) {
        @unlink($temporary);
        throw new RuntimeException('Impossibile sostituire wp-config.php in modo atomico.');
    }
}
