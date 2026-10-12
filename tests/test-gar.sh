#!/usr/bin/env bash
# E2E Test Suite for Git Arborist (gar)
set -e

# Setup paths
TEST_DIR="/tmp/gar-test-env"
REMOTE_REPO="$TEST_DIR/remote"
HUB_DIR="$TEST_DIR/hub"
GAR_BIN="$(pwd)/bin/arborist"

echo "=== Git Arborist (gar) Test Suite ==="

# Cleanup old test environment
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# 1. Setup a dummy remote repository
echo "=> Setting up dummy remote..."
mkdir -p "$REMOTE_REPO"
cd "$REMOTE_REPO"
git init --initial-branch=develop >/dev/null
mkdir .ddev docroot docroot/sites docroot/sites/default
cat << 'EOF' > .ddev/config.yaml
name: test-project
type: drupal10
docroot: docroot
EOF
echo "<?php // Settings file" > docroot/sites/default/settings.php
git add .
git commit -m "Initial commit" >/dev/null
cd - >/dev/null

# 2. Mock DDEV command to prevent actual container execution
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"
cat << 'EOF' > "$TEST_DIR/bin/ddev"
#!/bin/bash
echo "[MOCK DDEV] Executed: ddev $*"
echo "$*" >> "/tmp/gar-test-env/ddev.log"

if [ "$1" = "describe" ]; then
    echo "OK"
    exit 0
fi

MOCK_DB_FILE="/tmp/gar-test-env/mock-dbs.txt"
if [ "$1" = "mysql" ]; then
    if [[ "$*" == *"SHOW DATABASES"* ]]; then
        if [ -f "$MOCK_DB_FILE" ]; then
            cat "$MOCK_DB_FILE"
        else
            echo "db"
        fi
        exit 0
    fi
    if [[ "$*" == *"CREATE DATABASE"* ]]; then
        dbname=$(echo "$*" | sed -E 's/.*CREATE DATABASE IF NOT EXISTS [`]?([^` ;]+)[`]?;.*/\1/')
        if [ -n "$dbname" ]; then
            echo "$dbname" >> "$MOCK_DB_FILE"
            sort -u "$MOCK_DB_FILE" -o "$MOCK_DB_FILE" 2>/dev/null || true
        fi
        exit 0
    fi
    if [[ "$*" == *"DROP DATABASE"* ]]; then
        dbname=$(echo "$*" | sed -E 's/.*DROP DATABASE (IF EXISTS )?[`]?([^` ;]+)[`]?;.*/\2/')
        if [ -n "$dbname" ] && [ -f "$MOCK_DB_FILE" ]; then
            grep -v "^$dbname$" "$MOCK_DB_FILE" > "$MOCK_DB_FILE.tmp" 2>/dev/null || true
            mv "$MOCK_DB_FILE.tmp" "$MOCK_DB_FILE"
        fi
        exit 0
    fi
fi
EOF
chmod +x "$TEST_DIR/bin/ddev"
echo "db" > "$TEST_DIR/mock-dbs.txt"

# Setup auto-confirm for interactive prompts
export GAR_AUTO_YES=true

# 3. Test: Init
echo ""
echo "=> Testing: gar init"
"$GAR_BIN" init "$REMOTE_REPO" "$HUB_DIR"
cd "$HUB_DIR"

if [ ! -d ".git" ] || [ ! -d ".ddev" ]; then
    echo "❌ Init failed: Hub not setup correctly"
    exit 1
fi

if [ ! -d "develop" ]; then
    echo "❌ Init failed: develop worktree not created"
    exit 1
fi

if [ -f "develop/.ddev/config.yaml" ]; then
    echo "❌ Sparse-checkout failed: .ddev exists in develop worktree"
    exit 1
fi

if [ ! -f "develop/docroot/sites/default/settings.local.php" ]; then
    echo "❌ Config injection failed: settings.local.php not created"
    exit 1
fi

if [ ! -f "develop/docroot/sites/default/settings.workspace.php" ] || ! grep -q "\$workspace_branch = 'develop';" "develop/docroot/sites/default/settings.workspace.php"; then
    echo "❌ Config injection failed: settings.workspace.php not properly injected with develop"
    exit 1
fi

if ! grep -q "\*\.test-project" ".ddev/config.yaml" 2>/dev/null; then
    echo "❌ Wildcard routing failed: additional_hostnames (*.test-project) not found in .ddev/config.yaml"
    exit 1
fi

if ! grep -q "^docroot: develop/docroot" ".ddev/config.yaml" 2>/dev/null; then
    echo "❌ Hub docroot failed: docroot not updated to develop/docroot in .ddev/config.yaml"
    exit 1
fi

if [ ! -x ".git/hooks/post-merge" ] || [ ! -x ".git/hooks/reference-transaction" ]; then
    echo "❌ Git hooks installation failed: post-merge or reference-transaction hook missing/not executable"
    exit 1
fi

if [ "$(git config fetch.prune 2>/dev/null)" != "true" ]; then
    echo "❌ Git config failed: fetch.prune is not true"
    exit 1
fi

if ! grep -q "PROTECTED_BRANCHES=" ".arborist" 2>/dev/null; then
    echo "❌ Config failed: PROTECTED_BRANCHES not set in .arborist"
    exit 1
fi

echo "✅ Init passed!"

# 4. Test: Switch (Create New Branch)
echo ""
echo "=> Testing: gar switch -c feature-1"
# Redirect fd 3 to /dev/null since wrapper isn't running
"$GAR_BIN" switch -c feature-1 3>/dev/null

if [ ! -d "feature-1" ]; then
    echo "❌ Switch failed: feature-1 worktree not created"
    exit 1
fi

if [ -d "feature-1/.ddev" ]; then
    echo "❌ Sparse-checkout failed: .ddev exists in feature-1"
    exit 1
fi

if ! grep -q "CREATE DATABASE IF NOT EXISTS \`db_feature_1\`" "$TEST_DIR/ddev.log"; then
    echo "❌ Database naming failed: sanitized db_feature_1 not found in ddev commands"
    exit 1
fi

echo "✅ Switch passed!"

# 5. Test: Move (-m)
echo ""
echo "=> Testing: gar -m feature-1 feature-2"
"$GAR_BIN" -m feature-1 feature-2 3>/dev/null

if [ -d "feature-1" ] || [ ! -d "feature-2" ]; then
    echo "❌ Move failed: Directory not renamed"
    exit 1
fi

# Verify git worktree repair worked
if ! git worktree list | grep -q "feature-2"; then
    echo "❌ Move failed: Git worktree not repaired"
    exit 1
fi

if ! grep -q "CREATE DATABASE IF NOT EXISTS \`db_feature_2\`" "$TEST_DIR/ddev.log" || ! grep -q "DROP DATABASE \`db_feature_1\`" "$TEST_DIR/ddev.log"; then
    echo "❌ Database migration failed: sanitized db_feature_2 or drop of db_feature_1 not found"
    exit 1
fi

echo "✅ Move passed!"

# 6. Test: Remove
echo ""
echo "=> Testing: gar remove feature-2"
"$GAR_BIN" remove feature-2

if [ -d "feature-2" ]; then
    echo "❌ Remove failed: Directory still exists"
    exit 1
fi

if ! grep -q "DROP DATABASE IF EXISTS \`db_feature_2\`" "$TEST_DIR/ddev.log"; then
    echo "❌ Database drop failed: sanitized db_feature_2 not found in ddev commands"
    exit 1
fi

echo "✅ Remove passed!"

# 7. Test: Init with custom tracking branch (main)
echo ""
echo "=> Testing: gar init with tracking branch 'main'"
REMOTE_MAIN_REPO="$TEST_DIR/remote-main"
HUB_MAIN_DIR="$TEST_DIR/hub-main"
mkdir -p "$REMOTE_MAIN_REPO"
cd "$REMOTE_MAIN_REPO"
git init --initial-branch=main >/dev/null
mkdir .ddev docroot docroot/sites docroot/sites/default
cat << 'EOF' > .ddev/config.yaml
name: test-main-project
type: drupal10
docroot: docroot
EOF
echo "<?php // Settings file" > docroot/sites/default/settings.php
git add .
git commit -m "Initial commit" >/dev/null
cd - >/dev/null

"$GAR_BIN" init "$REMOTE_MAIN_REPO" "$HUB_MAIN_DIR"
cd "$HUB_MAIN_DIR"

if ! grep -q "\$workspace_branch = 'main';" "main/docroot/sites/default/settings.workspace.php"; then
    echo "❌ Dynamic tracking branch failed: settings.workspace.php does not reference main"
    exit 1
fi
if grep -q "'develop'" "main/docroot/sites/default/settings.workspace.php"; then
    echo "❌ Dynamic tracking branch failed: develop was not replaced in settings.workspace.php"
    exit 1
fi
if ! grep -q "^docroot: main/docroot" ".ddev/config.yaml" 2>/dev/null; then
    echo "❌ Hub docroot failed: docroot not updated to main/docroot in .ddev/config.yaml"
    exit 1
fi
if ! grep -q "\*\.test-main-project" ".ddev/config.yaml" 2>/dev/null; then
    echo "❌ Wildcard routing failed: additional_hostnames (*.test-main-project) not found in .ddev/config.yaml"
    exit 1
fi
echo "✅ Dynamic tracking branch test passed!"

# 8. Test: Database commands (import, export, aliases, relative paths, latest file resolution)
echo ""
echo "=> Testing: gar db import/export"
cd "$HUB_DIR"

# 8.1 Create backup directory and dump files with different timestamps
mkdir -p "$HUB_DIR/backups"
touch -t 202610121000 "$HUB_DIR/backups/dump_old.sql.gz"
touch -t 202610121100 "$HUB_DIR/backups/dump_latest.sql.gz"

# 8.2 Test: Default import from Hub root (should pick dump_latest.sql.gz and target default db)
"$GAR_BIN" db import
if ! grep -q "import-db --database=db --file=$HUB_DIR/backups/dump_latest.sql.gz" "$TEST_DIR/ddev.log"; then
    echo "❌ DB import failed: did not import latest file into default db"
    exit 1
fi

# 8.3 Test: Alias 'dbi' from inside a worktree with relative --file
"$GAR_BIN" switch -c feature-db 3>/dev/null
cd "$HUB_DIR/feature-db"
echo "custom" > "$HUB_DIR/feature-db/custom.sql"

"$GAR_BIN" dbi --file custom.sql
if ! grep -q "import-db --database=db_feature_db --file=$HUB_DIR/feature-db/custom.sql" "$TEST_DIR/ddev.log"; then
    echo "❌ DB import with relative --file failed: did not resolve relative to invocation directory"
    exit 1
fi

# 8.4 Test: Import targeting another branch via --target
"$GAR_BIN" dbi --target feature-target
if ! grep -q "import-db --database=db_feature_target --file=$HUB_DIR/backups/dump_latest.sql.gz" "$TEST_DIR/ddev.log"; then
    echo "❌ DB import --target failed: did not target db_feature_target"
    exit 1
fi

# 8.5 Test: Export via 'gar dbe' with custom relative file
"$GAR_BIN" dbe --file ../backups/exported.sql.gz
if ! grep -q "export-db --database=db_feature_db --file=$HUB_DIR/backups/exported.sql.gz" "$TEST_DIR/ddev.log"; then
    echo "❌ DB export failed: did not export to relative path"
    exit 1
fi


echo "✅ DB commands passed!"

# 9. Test: List and Prune commands with Git hooks
echo ""
echo "=> Testing: gar list and gar prune"
cd "$HUB_DIR"

# 9.1 Verify 'gar list' output from hub root
LIST_OUTPUT=$("$GAR_BIN" list 2>&1)
if ! echo "$LIST_OUTPUT" | grep -q "develop"; then
    echo "❌ gar list failed: develop worktree not listed"
    exit 1
fi
if ! echo "$LIST_OUTPUT" | grep -q "🟡 Protect"; then
    echo "❌ gar list failed: develop not marked protected"
    exit 1
fi

# 9.2 Create an orphaned remote branch scenario
cd "$REMOTE_REPO"
git branch feature-prune-clean develop
git branch feature-prune-dirty develop
cd "$HUB_DIR"
git -C "$HUB_DIR/develop" fetch origin >/dev/null 2>&1

# Switch into feature-prune-clean worktree and set upstream
"$GAR_BIN" switch -c feature-prune-clean 3>/dev/null
git -C "$HUB_DIR/feature-prune-clean" branch --set-upstream-to=origin/feature-prune-clean

# Switch into feature-prune-dirty worktree, set upstream, and leave dirty file
"$GAR_BIN" switch -c feature-prune-dirty 3>/dev/null
git -C "$HUB_DIR/feature-prune-dirty" branch --set-upstream-to=origin/feature-prune-dirty
echo "uncommitted change" > "$HUB_DIR/feature-prune-dirty/dirty.txt"

# Switch back to hub root
cd "$HUB_DIR"

# Simulate remote branch deletion (merged PRs)
git -C "$REMOTE_REPO" branch -D feature-prune-clean >/dev/null 2>&1
git -C "$REMOTE_REPO" branch -D feature-prune-dirty >/dev/null 2>&1

# Fetch with prune to update upstream track to [gone]
git -C "$HUB_DIR/develop" fetch -p >/dev/null 2>&1 || true

# Add an orphaned database with no branch
echo "db_stale_ghost" >> "$TEST_DIR/mock-dbs.txt"

# 9.3 Verify 'gar list' detects [gone] branches and orphaned databases
LIST_OUTPUT=$("$GAR_BIN" list 2>&1)
if ! echo "$LIST_OUTPUT" | grep -q "🔴 Orphaned.*feature-prune-clean"; then
    echo "❌ gar list failed: feature-prune-clean not marked orphaned"
    exit 1
fi
if ! echo "$LIST_OUTPUT" | grep -q "🔴 Orphaned.*db_stale_ghost"; then
    echo "❌ gar list failed: db_stale_ghost not marked orphaned"
    exit 1
fi

# 9.4 Test 'gar prune --dry-run'
DRY_OUTPUT=$("$GAR_BIN" prune --dry-run 2>&1)
if ! echo "$DRY_OUTPUT" | grep -q "Dry-run mode"; then
    echo "❌ gar prune --dry-run failed"
    exit 1
fi
if [ ! -d "$HUB_DIR/feature-prune-clean" ]; then
    echo "❌ gar prune --dry-run deleted clean worktree"
    exit 1
fi

# 9.5 Test 'gar prune -f':
# Must SKIP dirty worktree and report warning
PRUNE_OUTPUT=$("$GAR_BIN" prune -f 2>&1)
if ! echo "$PRUNE_OUTPUT" | grep -q "Skipping dirty worktree 'feature-prune-dirty'"; then
    echo "❌ gar prune failed: did not skip dirty worktree"
    exit 1
fi
if [ ! -d "$HUB_DIR/feature-prune-dirty" ]; then
    echo "❌ gar prune failed: dirty worktree was deleted!"
    exit 1
fi

# Clean worktree MUST have been removed
if [ -d "$HUB_DIR/feature-prune-clean" ]; then
    echo "❌ gar prune failed: clean worktree was not removed"
    exit 1
fi

# Orphaned DB db_stale_ghost MUST have been dropped
if grep -q "db_stale_ghost" "$TEST_DIR/mock-dbs.txt" 2>/dev/null; then
    echo "❌ gar prune failed: db_stale_ghost was not dropped"
    exit 1
fi

# 9.6 Test hook execution
# Run .git/hooks/post-merge directly to verify it executes cleanly
"$HUB_DIR/.git/hooks/post-merge"
echo "✅ List and Prune commands passed!"

echo ""
echo "🎉 All tests passed successfully!"
