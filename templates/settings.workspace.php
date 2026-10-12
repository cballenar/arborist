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

// Modify the database array if we are in a non-default branch
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
