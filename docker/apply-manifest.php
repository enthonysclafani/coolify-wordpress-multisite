<?php

// Eseguito da `wp eval-file`: una declare strict_types non sarebbe la prima istruzione del codice valutato.

$manifestPath = getenv('WORDPRESS_RESOLVED_MANIFEST');
$manifestHash = getenv('WORDPRESS_RESOLVED_MANIFEST_HASH');
$applyMode = getenv('WORDPRESS_MANIFEST_APPLY_MODE') ?: 'fresh';

if (! is_string($manifestPath) || $manifestPath === '' || ! is_readable($manifestPath)) {
    throw new RuntimeException('Manifest WordPress non disponibile.');
}

$raw = file_get_contents($manifestPath);
if ($raw === false) {
    throw new RuntimeException('Impossibile leggere il manifest WordPress.');
}

$manifest = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
if (! is_array($manifest)) {
    throw new RuntimeException('Manifest WordPress non valido.');
}

$wordpress = $manifest['wordpress'];
$multisite = $manifest['multisite'];
$applyExistingSites = ($multisite['apply_to_existing_sites'] ?? false) === true;
$siteIds = [get_current_blog_id()];

if (is_multisite() && $applyMode === 'reapply' && $applyExistingSites) {
    $siteIds = get_sites([
        'fields' => 'ids',
        'number' => 0,
    ]);
}

foreach ($siteIds as $siteId) {
    if (is_multisite()) {
        switch_to_blog((int) $siteId);
    }

    update_option('permalink_structure', (string) $wordpress['permalink_structure']);
    update_option('blog_public', $wordpress['search_engine_visibility'] ? '1' : '0');

    if ($applyMode === 'fresh' && ($wordpress['delete_default_content'] ?? false)) {
        foreach (['hello-world', 'sample-page'] as $slug) {
            $posts = get_posts([
                'name' => $slug,
                'post_type' => 'any',
                'post_status' => 'any',
                'numberposts' => -1,
            ]);
            foreach ($posts as $post) {
                wp_delete_post((int) $post->ID, true);
            }
        }
    }

    flush_rewrite_rules(false);

    if (is_multisite()) {
        restore_current_blog();
    }
}

if (is_multisite()) {
    update_site_option('registration', (string) $multisite['registration']);
    update_site_option('blog_upload_space', (int) $multisite['upload_space_mb']);
    update_site_option('upload_space_check_disabled', 0);
    update_site_option('upload_filetypes', (string) $multisite['upload_filetypes']);
}

$record = [
    'schema' => 1,
    'name' => (string) $manifest['name'],
    'hash' => is_string($manifestHash) ? $manifestHash : hash('sha256', $raw),
    'mode' => $applyMode,
    'applied_at' => gmdate('c'),
];

if (is_multisite()) {
    update_site_option('_coolify_suite_manifest_v1', $record);
} else {
    update_option('_coolify_suite_manifest_v1', $record, false);
}
