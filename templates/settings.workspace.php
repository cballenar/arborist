<?php
/**
 * DDEV Workspace Database Routing
 * 
 * Include this at the bottom of settings.local.php:
 * require __DIR__ . '/settings.workspace.php';
 */

$workspace_branch = 'develop';

// 1. Check if Nginx passed the branch in the environment (Web Context)
if (!empty($_SERVER['DDEV_WORKSPACE_BRANCH'])) {
    $workspace_branch = $_SERVER['DDEV_WORKSPACE_BRANCH'];
} 
// 2. Check CLI Context (e.g. running Drush from inside a worktree)
elseif (PHP_SAPI === 'cli') {
    // __DIR__ is always /var/www/html/<branch_path>/<webroot>/sites/default (or /sites/default)
    if (preg_match('#^/var/www/html/(.+?)(?:/(?:docroot|web|html|public_html|public))?/sites/#', __DIR__, $matches)) {
        $workspace_branch = $matches[1];
    } elseif (preg_match('#^/var/www/html/(.+?)(?:/(?:docroot|web|html|public_html|public))?(?:/|$)#', getcwd(), $matches)) {
        $workspace_branch = $matches[1];
    }
}

// 3. Resolve actual Git branch name (from worktree HEAD ref or fallback to folder name)
$display_branch = $workspace_branch;
$head_file = '/var/www/html/.git/worktrees/' . $workspace_branch . '/HEAD';
if (!file_exists($head_file)) {
    $hub_dir = dirname(__DIR__, 4);
    if (file_exists($hub_dir . '/.git/worktrees/' . $workspace_branch . '/HEAD')) {
        $head_file = $hub_dir . '/.git/worktrees/' . $workspace_branch . '/HEAD';
    }
}
if (file_exists($head_file)) {
    $head_content = trim((string) @file_get_contents($head_file));
    if (preg_match('#^ref: refs/heads/(.+)#', $head_content, $ref_matches)) {
        $display_branch = $ref_matches[1];
    }
}

// 4. Environment Indicator override (if module is installed/present)
$has_env_indicator = isset($config['environment_indicator.indicator']);
if (!$has_env_indicator) {
    $app_root = isset($app_root) ? $app_root : (defined('DRUPAL_ROOT') ? DRUPAL_ROOT : dirname(__DIR__, 2));
    if (is_dir($app_root . '/modules/contrib/environment_indicator') ||
        is_dir($app_root . '/modules/environment_indicator') ||
        is_dir(dirname($app_root) . '/modules/contrib/environment_indicator')) {
        $has_env_indicator = true;
    } else {
        foreach ([$app_root . '/../config', $app_root . '/config'] as $cfg_dir) {
            if (is_dir($cfg_dir)) {
                $ext_files = glob($cfg_dir . '/*/core.extension.yml');
                if ($ext_files) {
                    foreach ($ext_files as $ext_file) {
                        if (strpos((string) @file_get_contents($ext_file), 'environment_indicator:') !== false) {
                            $has_env_indicator = true;
                            break 2;
                        }
                    }
                }
            }
        }
    }
}

if ($has_env_indicator) {
    $config['environment_indicator.indicator']['name'] = $display_branch;
}

// 5. Modify the database array if we are in a non-default branch
if (!empty($workspace_branch) && $workspace_branch !== 'develop') {
    $db_name = 'db_' . preg_replace('/[^a-zA-Z0-9_]/', '_', $workspace_branch);
    
    // Check if the isolated database actually exists (so we can fallback to the main db if it doesn't)
    $db_exists = false;
    try {
        // We use the default DDEV db credentials to query the mysql server directly
        $pdo = new PDO('mysql:host=db;port=3306', 'db', 'db', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $result = $pdo->query("SHOW DATABASES LIKE '$db_name'")->fetch();
        if ($result) {
            $db_exists = true;
        }
    } catch (Exception $e) {
        // Silently fail connection checks, fallback to default db
    }

    if ($db_exists) {
        if (!isset($databases['default']['default'])) {
            $databases['default']['default'] = [
                'database' => $db_name,
                'username' => 'db',
                'password' => 'db',
                'host' => 'db',
                'port' => 3306,
                'driver' => 'mysql',
            ];
        } else {
            $databases['default']['default']['database'] = $db_name;
        }
    }
}
