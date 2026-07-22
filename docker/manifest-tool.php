<?php

declare(strict_types=1);

function fail(string $message): never
{
    fwrite(STDERR, "Manifest non valido: {$message}\n");
    exit(1);
}

function assertAllowedKeys(array $value, array $allowed, string $context): void
{
    $unknown = array_diff(array_keys($value), $allowed);
    if ($unknown !== []) {
        fail($context . ' contiene chiavi sconosciute: ' . implode(', ', $unknown));
    }
}

function assertBoolean(array $value, string $key, string $context): void
{
    if (array_key_exists($key, $value) && ! is_bool($value[$key])) {
        fail("{$context}.{$key} deve essere booleano");
    }
}

function validateManifest(array $manifest): void
{
    assertAllowedKeys($manifest, ['schema', 'name', 'wordpress', 'plugins', 'themes', 'multisite'], 'root');

    if (($manifest['schema'] ?? null) !== 1) {
        fail('schema deve essere esattamente 1');
    }
    if (! is_string($manifest['name'] ?? null) || preg_match('/^[a-z0-9][a-z0-9-]{0,63}$/', $manifest['name']) !== 1) {
        fail('name deve essere uno slug di massimo 64 caratteri');
    }

    $wordpress = $manifest['wordpress'] ?? null;
    if (! is_array($wordpress) || array_is_list($wordpress)) {
        fail('wordpress deve essere un oggetto');
    }
    assertAllowedKeys(
        $wordpress,
        [
            'environment',
            'permalink_structure',
            'search_engine_visibility',
            'delete_default_content',
            'update_policy',
            'disallow_file_edit',
            'disallow_file_mods',
        ],
        'wordpress'
    );
    if (! in_array($wordpress['environment'] ?? null, ['local', 'development', 'staging', 'production'], true)) {
        fail('wordpress.environment non e valido');
    }
    $permalink = $wordpress['permalink_structure'] ?? null;
    if (! is_string($permalink) || strlen($permalink) > 200 || ($permalink !== '' && $permalink[0] !== '/')) {
        fail('wordpress.permalink_structure deve essere vuoto o iniziare con / e non superare 200 caratteri');
    }
    if (! in_array($wordpress['update_policy'] ?? null, ['default', 'minor', 'all', 'disabled'], true)) {
        fail('wordpress.update_policy non e valido');
    }
    foreach (['search_engine_visibility', 'delete_default_content', 'disallow_file_edit', 'disallow_file_mods'] as $key) {
        assertBoolean($wordpress, $key, 'wordpress');
    }

    $plugins = $manifest['plugins'] ?? null;
    if (! is_array($plugins) || ! array_is_list($plugins) || count($plugins) > 50) {
        fail('plugins deve essere una lista di massimo 50 elementi');
    }
    $pluginSlugs = [];
    foreach ($plugins as $index => $plugin) {
        if (! is_array($plugin) || array_is_list($plugin)) {
            fail("plugins.{$index} deve essere un oggetto");
        }
        assertAllowedKeys($plugin, ['slug', 'version', 'activation', 'required'], "plugins.{$index}");
        $slug = $plugin['slug'] ?? null;
        $version = $plugin['version'] ?? null;
        if (! is_string($slug) || preg_match('/^[a-z0-9][a-z0-9-]{0,63}$/', $slug) !== 1) {
            fail("plugins.{$index}.slug non e valido");
        }
        if (isset($pluginSlugs[$slug])) {
            fail("plugin duplicato: {$slug}");
        }
        $pluginSlugs[$slug] = true;
        if (! is_string($version) || preg_match('/^[0-9]+(?:\.[0-9]+){1,3}(?:[-.][A-Za-z0-9]+)?$/', $version) !== 1) {
            fail("plugins.{$index}.version deve essere pinata");
        }
        if (! in_array($plugin['activation'] ?? null, ['auto', 'site', 'network', 'none'], true)) {
            fail("plugins.{$index}.activation non e valida");
        }
        assertBoolean($plugin, 'required', "plugins.{$index}");
    }

    $themes = $manifest['themes'] ?? null;
    if (! is_array($themes) || ! array_is_list($themes) || count($themes) > 20) {
        fail('themes deve essere una lista di massimo 20 elementi');
    }
    $activeThemes = 0;
    $themeSlugs = [];
    foreach ($themes as $index => $theme) {
        if (! is_array($theme) || array_is_list($theme)) {
            fail("themes.{$index} deve essere un oggetto");
        }
        assertAllowedKeys($theme, ['slug', 'version', 'activate', 'required'], "themes.{$index}");
        if (! is_string($theme['slug'] ?? null) || preg_match('/^[a-z0-9][a-z0-9-]{0,63}$/', $theme['slug']) !== 1) {
            fail("themes.{$index}.slug non e valido");
        }
        if (isset($themeSlugs[$theme['slug']])) {
            fail('tema duplicato: ' . $theme['slug']);
        }
        $themeSlugs[$theme['slug']] = true;
        if (! is_string($theme['version'] ?? null) || preg_match('/^[0-9]+(?:\.[0-9]+){1,3}(?:[-.][A-Za-z0-9]+)?$/', $theme['version']) !== 1) {
            fail("themes.{$index}.version deve essere pinata");
        }
        foreach (['activate', 'required'] as $key) {
            assertBoolean($theme, $key, "themes.{$index}");
        }
        if (($theme['activate'] ?? false) === true) {
            ++$activeThemes;
        }
    }
    if ($activeThemes > 1) {
        fail('un solo tema puo avere activate=true');
    }

    $multisite = $manifest['multisite'] ?? null;
    if (! is_array($multisite) || array_is_list($multisite)) {
        fail('multisite deve essere un oggetto');
    }
    assertAllowedKeys($multisite, ['registration', 'upload_space_mb', 'upload_filetypes', 'apply_to_existing_sites'], 'multisite');
    if (! in_array($multisite['registration'] ?? null, ['none', 'all', 'blog', 'user'], true)) {
        fail('multisite.registration non e valido');
    }
    $uploadSpace = $multisite['upload_space_mb'] ?? null;
    if (! is_int($uploadSpace) || $uploadSpace < 1 || $uploadSpace > 1048576) {
        fail('multisite.upload_space_mb deve essere tra 1 e 1048576');
    }
    if (! is_string($multisite['upload_filetypes'] ?? null)
        || strlen($multisite['upload_filetypes']) > 512
        || preg_match('/^[A-Za-z0-9 ]+$/', $multisite['upload_filetypes']) !== 1
    ) {
        fail('multisite.upload_filetypes non e valido');
    }
    assertBoolean($multisite, 'apply_to_existing_sites', 'multisite');
}

if ($argc < 3) {
    fwrite(STDERR, "Uso: manifest-tool.php validate|get|plugins|themes|hash FILE [PATH] [DEFAULT]\n");
    exit(2);
}

$command = $argv[1];
$path = $argv[2];
$raw = @file_get_contents($path);
if ($raw === false || strlen($raw) > 131072) {
    fail('file assente, illeggibile o superiore a 128 KiB');
}

try {
    $manifest = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
} catch (JsonException $exception) {
    fail('JSON non valido: ' . $exception->getMessage());
}
if (! is_array($manifest) || array_is_list($manifest)) {
    fail('la radice JSON deve essere un oggetto');
}
validateManifest($manifest);

switch ($command) {
    case 'validate':
        echo "ok\n";
        break;

    case 'hash':
        echo hash('sha256', $raw), "\n";
        break;

    case 'get':
        $keyPath = $argv[3] ?? '';
        $default = $argv[4] ?? '';
        $value = $manifest;
        foreach (explode('.', $keyPath) as $part) {
            if ($part === '' || ! is_array($value) || ! array_key_exists($part, $value)) {
                echo $default;
                exit(0);
            }
            $value = $value[$part];
        }
        if (is_bool($value)) {
            echo $value ? 'true' : 'false';
        } elseif (is_scalar($value)) {
            echo (string) $value;
        } else {
            fail("{$keyPath} non e un valore scalare");
        }
        break;

    case 'plugins':
        foreach ($manifest['plugins'] as $plugin) {
            echo implode("\t", [
                $plugin['slug'],
                $plugin['version'],
                $plugin['activation'],
                ($plugin['required'] ?? true) ? 'true' : 'false',
            ]), "\n";
        }
        break;

    case 'themes':
        foreach ($manifest['themes'] as $theme) {
            echo implode("\t", [
                $theme['slug'],
                $theme['version'],
                ($theme['activate'] ?? false) ? 'true' : 'false',
                ($theme['required'] ?? true) ? 'true' : 'false',
            ]), "\n";
        }
        break;

    default:
        fwrite(STDERR, "Comando manifest sconosciuto: {$command}\n");
        exit(2);
}
