<?php

/**
 * Plugin Name: Coolify S3 Uploads Loader
 * Description: Loads the pinned S3 Uploads bundle when remote media storage is enabled.
 */

declare(strict_types=1);

$mediaStorage = strtolower((string) getenv('WORDPRESS_MEDIA_STORAGE'));
if ($mediaStorage !== 's3') {
    return;
}

$env = static function (string $name, string $default = ''): string {
    $value = getenv($name);

    return is_string($value) && $value !== '' ? $value : $default;
};
$envBool = static function (string $name, bool $default = false) use ($env): bool {
    return in_array(strtolower($env($name, $default ? 'true' : 'false')), ['true', '1', 'yes', 'on'], true);
};

defined('S3_UPLOADS_BUCKET') || define('S3_UPLOADS_BUCKET', $env('WORDPRESS_S3_BUCKET'));
defined('S3_UPLOADS_REGION') || define('S3_UPLOADS_REGION', $env('WORDPRESS_S3_REGION'));
defined('S3_UPLOADS_AUTOENABLE') || define('S3_UPLOADS_AUTOENABLE', $envBool('WORDPRESS_S3_AUTOENABLE', true));
defined('S3_UPLOADS_OBJECT_ACL') || define('S3_UPLOADS_OBJECT_ACL', $env('WORDPRESS_S3_OBJECT_ACL', 'private'));

if ($envBool('WORDPRESS_S3_USE_INSTANCE_PROFILE')) {
    defined('S3_UPLOADS_USE_INSTANCE_PROFILE') || define('S3_UPLOADS_USE_INSTANCE_PROFILE', true);
} else {
    defined('S3_UPLOADS_KEY') || define('S3_UPLOADS_KEY', $env('WORDPRESS_S3_ACCESS_KEY'));
    defined('S3_UPLOADS_SECRET') || define('S3_UPLOADS_SECRET', $env('WORDPRESS_S3_SECRET_KEY'));
}

if ($env('WORDPRESS_S3_BUCKET_URL') !== '') {
    defined('S3_UPLOADS_BUCKET_URL') || define('S3_UPLOADS_BUCKET_URL', rtrim($env('WORDPRESS_S3_BUCKET_URL'), '/'));
}
if ($envBool('WORDPRESS_S3_USE_LOCAL')) {
    defined('S3_UPLOADS_USE_LOCAL') || define('S3_UPLOADS_USE_LOCAL', true);
}
if ($env('WORDPRESS_S3_CACHE_CONTROL_SECONDS') !== '') {
    defined('S3_UPLOADS_HTTP_CACHE_CONTROL')
        || define('S3_UPLOADS_HTTP_CACHE_CONTROL', (int) $env('WORDPRESS_S3_CACHE_CONTROL_SECONDS'));
}

add_filter(
    's3_uploads_s3_client_params',
    static function (array $parameters) use ($env, $envBool): array {
        if ($env('WORDPRESS_S3_ENDPOINT') !== '') {
            $parameters['endpoint'] = $env('WORDPRESS_S3_ENDPOINT');
            $parameters['use_path_style_endpoint'] = $envBool('WORDPRESS_S3_PATH_STYLE', true);
        }
        if ($env('WORDPRESS_S3_SESSION_TOKEN') !== '') {
            $parameters['credentials']['token'] = $env('WORDPRESS_S3_SESSION_TOKEN');
        }
        if ($envBool('WORDPRESS_S3_CHECKSUM_WHEN_REQUIRED', true)) {
            $parameters['request_checksum_calculation'] = 'when_required';
            $parameters['response_checksum_validation'] = 'when_required';
        }

        return $parameters;
    }
);

$bundleRoot = '/usr/local/share/wordpress-stack/s3-module';
$autoload = $bundleRoot . '/vendor/autoload.php';
$pluginCandidates = [
    $bundleRoot . '/wp-content/plugins/s3-uploads/s3-uploads.php',
    $bundleRoot . '/vendor/humanmade/s3-uploads/s3-uploads.php',
];

if (! is_readable($autoload)) {
    throw new RuntimeException('Bundle Composer S3 Uploads assente: usare un profilo immagine con il modulo S3.');
}
require_once $autoload;

foreach ($pluginCandidates as $pluginFile) {
    if (is_readable($pluginFile)) {
        require_once $pluginFile;
        return;
    }
}

throw new RuntimeException('File principale S3 Uploads non trovato nel bundle Composer.');
