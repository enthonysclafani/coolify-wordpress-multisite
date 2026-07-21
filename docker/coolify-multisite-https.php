<?php

/**
 * Plugin Name: Coolify Multisite HTTPS
 * Description: Ensures new subdomain-network sites use HTTPS behind the Coolify proxy.
 */

declare(strict_types=1);

add_filter(
    'wp_initialize_site_args',
    static function (array $arguments, WP_Site $site): array {
        if (! is_multisite() || ! is_subdomain_install()) {
            return $arguments;
        }

        $canonicalUrl = untrailingslashit('https://' . $site->domain . $site->path);
        $arguments['options']['home'] = $canonicalUrl;
        $arguments['options']['siteurl'] = $canonicalUrl;

        return $arguments;
    },
    10,
    2
);
