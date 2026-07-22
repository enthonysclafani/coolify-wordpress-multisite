<?php

/**
 * Plugin Name: Coolify WordPress Suite
 * Description: Runtime integrations and safe defaults managed by the Coolify WordPress suite.
 */

declare(strict_types=1);

function coolify_suite_env(string $name, string $default = ''): string
{
    $value = getenv($name);

    return is_string($value) && $value !== '' ? $value : $default;
}

function coolify_suite_env_bool(string $name, bool $default = false): bool
{
    $value = strtolower(coolify_suite_env($name, $default ? 'true' : 'false'));

    return in_array($value, ['true', '1', 'yes', 'on'], true);
}

if (coolify_suite_env('WORDPRESS_SMTP_MODE', 'disabled') === 'smtp') {
    add_action(
        'phpmailer_init',
        static function ($mailer): void {
            $mailer->isSMTP();
            $mailer->Host = coolify_suite_env('WORDPRESS_SMTP_HOST');
            $mailer->Port = (int) coolify_suite_env('WORDPRESS_SMTP_PORT', '587');
            $mailer->SMTPAuth = coolify_suite_env_bool('WORDPRESS_SMTP_AUTH', true);
            $mailer->Username = coolify_suite_env('WORDPRESS_SMTP_USERNAME');
            $mailer->Password = coolify_suite_env('WORDPRESS_SMTP_PASSWORD');
            $mailer->Timeout = (int) coolify_suite_env('WORDPRESS_SMTP_TIMEOUT_SECONDS', '15');

            $encryption = coolify_suite_env('WORDPRESS_SMTP_ENCRYPTION', 'tls');
            if ($encryption === 'none') {
                $mailer->SMTPSecure = '';
                $mailer->SMTPAutoTLS = false;
            } else {
                $mailer->SMTPSecure = $encryption;
                $mailer->SMTPAutoTLS = true;
            }

            if (! coolify_suite_env_bool('WORDPRESS_SMTP_VERIFY_TLS', true)) {
                $mailer->SMTPOptions = [
                    'ssl' => [
                        'verify_peer' => false,
                        'verify_peer_name' => false,
                        'allow_self_signed' => true,
                    ],
                ];
            }
        }
    );

    if (coolify_suite_env('WORDPRESS_SMTP_FROM_EMAIL') !== '') {
        add_filter('wp_mail_from', static fn (): string => coolify_suite_env('WORDPRESS_SMTP_FROM_EMAIL'));
    }
    if (coolify_suite_env('WORDPRESS_SMTP_FROM_NAME') !== '') {
        add_filter('wp_mail_from_name', static fn (): string => coolify_suite_env('WORDPRESS_SMTP_FROM_NAME'));
    }

    add_action(
        'wp_mail_failed',
        static function (WP_Error $error): void {
            error_log('[coolify-suite] Invio email fallito: ' . sanitize_text_field($error->get_error_message()));
        }
    );
}

$actionSchedulerConcurrency = (int) coolify_suite_env('WORDPRESS_ACTION_SCHEDULER_CONCURRENT_BATCHES', '1');
if ($actionSchedulerConcurrency > 1) {
    add_filter(
        'action_scheduler_queue_runner_concurrent_batches',
        static fn (): int => $actionSchedulerConcurrency
    );
}

add_action(
    'wp_initialize_site',
    static function (WP_Site $site): void {
        $manifestPath = __DIR__ . '/coolify-suite-manifest.json';
        if (is_readable($manifestPath)) {
            $raw = file_get_contents($manifestPath);
            $manifest = is_string($raw) ? json_decode($raw, true) : null;
            if (is_array($manifest) && isset($manifest['wordpress'])) {
                switch_to_blog((int) $site->blog_id);
                update_option(
                    'blog_public',
                    ($manifest['wordpress']['search_engine_visibility'] ?? true) ? '1' : '0'
                );
                update_option(
                    'permalink_structure',
                    (string) ($manifest['wordpress']['permalink_structure'] ?? '/%postname%/')
                );
                restore_current_blog();
            }
        }

        if (coolify_suite_env('WORDPRESS_SEARCH_MODE', 'disabled') !== 'elasticpress'
            || coolify_suite_env('WORDPRESS_SEARCH_MULTISITE_ACTIVATION', 'per-site') !== 'per-site'
        ) {
            return;
        }

        require_once ABSPATH . 'wp-admin/includes/plugin.php';
        switch_to_blog((int) $site->blog_id);
        activate_plugin('elasticpress/elasticpress.php', '', false, true);
        restore_current_blog();
    },
    200
);
