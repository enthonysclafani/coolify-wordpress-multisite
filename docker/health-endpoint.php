<?php

declare(strict_types=1);

header('Content-Type: text/plain; charset=utf-8');

$remoteAddress = $_SERVER['REMOTE_ADDR'] ?? '';
if (! in_array($remoteAddress, ['127.0.0.1', '::1'], true)) {
    http_response_code(404);
    echo "not found\n";
    exit;
}

$scriptName = basename((string) ($_SERVER['SCRIPT_NAME'] ?? ''));
if ($scriptName === 'healthz-live.php') {
    echo "live\n";
    exit;
}

try {
    $hostValue = (string) getenv('WORDPRESS_DB_HOST');
    $host = $hostValue;
    $port = 3306;
    if (preg_match('/^\[([^]]+)](?::([0-9]+))?$/', $hostValue, $matches) === 1) {
        $host = $matches[1];
        $port = isset($matches[2]) ? (int) $matches[2] : 3306;
    } elseif (preg_match('/^([^:]+):([0-9]+)$/', $hostValue, $matches) === 1) {
        $host = $matches[1];
        $port = (int) $matches[2];
    }

    mysqli_report(MYSQLI_REPORT_OFF);
    $database = mysqli_init();
    $sslEnabled = in_array(
        strtolower((string) getenv('WORDPRESS_DB_SSL')),
        ['true', '1', 'yes', 'on'],
        true
    );
    $flags = $sslEnabled ? MYSQLI_CLIENT_SSL : 0;
    $connected = @$database->real_connect(
        $host,
        (string) getenv('WORDPRESS_DB_USER'),
        (string) getenv('WORDPRESS_DB_PASSWORD'),
        (string) getenv('WORDPRESS_DB_NAME'),
        $port,
        null,
        $flags
    );
    if (! $connected || $database->connect_errno !== 0) {
        throw new RuntimeException('database unavailable');
    }
    $database->close();

    $root = __DIR__;
    if (! is_readable($root . '/wp-load.php') || ! is_readable($root . '/wp-config.php')) {
        throw new RuntimeException('wordpress unavailable');
    }

    require_once $root . '/wp-load.php';
    if (! function_exists('is_blog_installed') || ! is_blog_installed()) {
        throw new RuntimeException('wordpress not installed');
    }

    $expectsMultisite = in_array(
        strtolower((string) getenv('WORDPRESS_ENABLE_MULTISITE')),
        ['true', '1', 'yes', 'on'],
        true
    );
    if ($expectsMultisite !== is_multisite()) {
        throw new RuntimeException('topology mismatch');
    }

    echo "ready\n";
} catch (Throwable $error) {
    http_response_code(503);
    echo "not ready\n";
}
