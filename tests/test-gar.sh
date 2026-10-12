#!/usr/bin/env bash
# E2E Test Suite for Git Arborist (gar)
set -e

# Setup paths
TEST_DIR="/tmp/gar-test-env"
REMOTE_REPO="$TEST_DIR/remote"
HUB_DIR="$TEST_DIR/hub"
MOCK_DB_FILE="$TEST_DIR/mock-dbs.txt"
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
mkdir -p .ddev docroot docroot/sites docroot/sites/default docroot/core/assets/scaffold/files
cat << 'EOF' > .ddev/config.yaml
name: test-project
type: drupal10
docroot: docroot
EOF
echo "<?php // Settings file" > docroot/sites/default/settings.php
echo "services: {}" > docroot/core/assets/scaffold/files/development.services.yml
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

if ! grep -q "drush updb -y" "$TEST_DIR/ddev.log" || ! grep -q "drush uli" "$TEST_DIR/ddev.log"; then
    echo "❌ Post-provision commands failed: drush updb/uli not executed"
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

# 10. Test: Switch Ergonomics, Remove -f, and Autocompletion
echo ""
echo "=> Testing: Switch Ergonomics, Remove -f, and Autocompletion"
cd "$HUB_DIR"

# 10.1 Test: 'gar switch' with no arguments returns tracking branch path
NO_ARG_TARGET=$("$GAR_BIN" switch)
if [ "$NO_ARG_TARGET" != "$HUB_DIR/develop" ]; then
    echo "❌ gar switch (no args) failed: expected $HUB_DIR/develop, got $NO_ARG_TARGET"
    exit 1
fi

# 10.2 Test: 'gar switch' remote branch without -c
git -C "$REMOTE_REPO" branch feature-from-remote develop
git -C "$HUB_DIR/develop" fetch origin >/dev/null 2>&1

REMOTE_TARGET=$("$GAR_BIN" switch feature-from-remote)
if [ "$REMOTE_TARGET" != "$HUB_DIR/feature-from-remote" ] || [ ! -d "$HUB_DIR/feature-from-remote" ]; then
    echo "❌ gar switch remote branch failed: worktree not created"
    exit 1
fi

# 10.3 Test: 'gar remove -f' (removes worktree and drops DB without prompt)
"$GAR_BIN" remove -f feature-from-remote
if [ -d "$HUB_DIR/feature-from-remote" ]; then
    echo "❌ gar remove -f failed: worktree still exists"
    exit 1
fi

# 10.4 Test: Autocompletion __complete helper outputs branches
COMPLETE_OUTPUT=$("$GAR_BIN" __complete worktrees)
if ! echo "$COMPLETE_OUTPUT" | grep -q "develop"; then
    echo "❌ __complete worktrees failed: develop not in completion output"
    exit 1
fi

# 10.5 Test: 'gar hook' output contains completion definition
HOOK_OUTPUT=$("$GAR_BIN" hook)
if ! echo "$HOOK_OUTPUT" | grep -q "_gar_zsh_complete" || ! echo "$HOOK_OUTPUT" | grep -q "_gar_bash_complete"; then
    echo "❌ gar hook failed: shell completions missing"
    exit 1
fi

echo "✅ Switch Ergonomics, Remove -f, and Autocompletion passed!"

# 11. Test: Post-Provision Command Error Termination
echo ""
echo "=> Testing: Post-Provision Command Error Termination"
cd "$HUB_DIR"

FAIL_LOG="$TEST_DIR/post-prov-fail.log"
echo "POST_PROVISION_CMD=\"touch '$FAIL_LOG' && false && touch '$TEST_DIR/never-reached.log'\"" >> "$HUB_DIR/.arborist"

FAIL_TARGET=$("$GAR_BIN" switch -c feature-fail-test)
if [ "$FAIL_TARGET" != "$HUB_DIR/feature-fail-test" ] || [ ! -d "$HUB_DIR/feature-fail-test" ]; then
    echo "❌ Post-provision error test failed: worktree was not switched to"
    exit 1
fi

if [ ! -f "$FAIL_LOG" ]; then
    echo "❌ Post-provision error test failed: initial command did not run"
    exit 1
fi

if [ -f "$TEST_DIR/never-reached.log" ]; then
    echo "❌ Post-provision error test failed: subsequent commands were not terminated after failure"
    exit 1
fi

echo "✅ Post-Provision Command Error Termination passed!"

# 12. Test: Branch Names with Slashes and Drush Command Wrapper
echo ""
echo "=> Testing: Branch Names with Slashes and Drush Command Wrapper"
cd "$HUB_DIR"

# Verify DDEV drush command wrapper was installed during init
if [ ! -x "$HUB_DIR/.ddev/commands/web/drush" ]; then
    echo "❌ Drush command wrapper missing or not executable at .ddev/commands/web/drush"
    exit 1
fi

# Reset failing post provision cmd
echo "POST_PROVISION_CMD=\"\"" >> "$HUB_DIR/.arborist"

SLASH_BRANCH="bsph/dwc-27-test-feature"
SLASH_TARGET=$("$GAR_BIN" switch -c "$SLASH_BRANCH")
if [ "$SLASH_TARGET" != "$HUB_DIR/$SLASH_BRANCH" ] || [ ! -d "$HUB_DIR/$SLASH_BRANCH" ]; then
    echo "❌ Slashed branch switch failed: expected $HUB_DIR/$SLASH_BRANCH"
    exit 1
fi

# Verify Drupal files were provisioned in worktree
if [ ! -f "$HUB_DIR/$SLASH_BRANCH/docroot/sites/default/settings.workspace.php" ]; then
    echo "❌ settings.workspace.php not provisioned in $SLASH_BRANCH"
    exit 1
fi
if [ ! -f "$HUB_DIR/$SLASH_BRANCH/docroot/sites/development.services.yml" ]; then
    echo "❌ development.services.yml not provisioned in $SLASH_BRANCH"
    exit 1
fi

# Test gar db info from inside the worktree root
cd "$HUB_DIR/$SLASH_BRANCH"
INFO_OUT=$("$GAR_BIN" db info 2>&1)
if ! echo "$INFO_OUT" | grep -q "Current Worktree:   $SLASH_BRANCH"; then
    echo "❌ gar db info failed to detect current worktree for slashed branch. Got:"
    echo "$INFO_OUT"
    exit 1
fi
if ! echo "$INFO_OUT" | grep -q "Target Database:    db_bsph_dwc_27_test_feature"; then
    echo "❌ gar db info resolved incorrect database for slashed branch. Got:"
    echo "$INFO_OUT"
    exit 1
fi

# Test gar db info from inside worktree subfolder (docroot/sites/default)
cd "$HUB_DIR/$SLASH_BRANCH/docroot/sites/default"
INFO_SUB=$("$GAR_BIN" db info 2>&1)
if ! echo "$INFO_SUB" | grep -q "Target Database:    db_bsph_dwc_27_test_feature"; then
    echo "❌ gar db info from subfolder resolved incorrect database. Got:"
    echo "$INFO_SUB"
    exit 1
fi

cd "$HUB_DIR"
"$GAR_BIN" remove -f "$SLASH_BRANCH"
if [ -d "$HUB_DIR/$SLASH_BRANCH" ]; then
    echo "❌ Slashed branch worktree was not removed"
    exit 1
fi

echo "✅ Slashed Branch Resolution and Drush Wrapper passed!"

# 12. Test: Pre-existing database detection on switch
echo ""
echo "=> Testing: Pre-existing database detection during switch"
echo "db_preexisting_feature" >> "$MOCK_DB_FILE"
EXISTING_SWITCH_OUT=$("$GAR_BIN" switch -c preexisting-feature 2>&1)
if ! echo "$EXISTING_SWITCH_OUT" | grep -q "Found existing isolated database 'db_preexisting_feature'. Using it."; then
    echo "❌ Pre-existing database detection failed! Got:"
    echo "$EXISTING_SWITCH_OUT"
    exit 1
fi
cd "$HUB_DIR"
"$GAR_BIN" remove -f preexisting-feature
echo "✅ Pre-existing database detection passed!"

# 13. Test: gar sync (programmatic project update and healing)
echo ""
echo "=> Testing: gar sync (programmatic project update and healing)"
# Intentionally remove a wrapper and a worktree scaffold file to test healing
rm -f "$HUB_DIR/.ddev/commands/web/drush"
rm -f "$HUB_DIR/develop/docroot/sites/development.services.yml"

SYNC_OUT=$("$GAR_BIN" sync 2>&1)
if ! echo "$SYNC_OUT" | grep -q "Arborist hub synchronized successfully!"; then
    echo "❌ gar sync failed! Got:"
    echo "$SYNC_OUT"
    exit 1
fi

if [ ! -x "$HUB_DIR/.ddev/commands/web/drush" ]; then
    echo "❌ gar sync did not restore .ddev/commands/web/drush!"
    exit 1
fi

if [ ! -f "$HUB_DIR/develop/docroot/sites/development.services.yml" ]; then
    echo "❌ gar sync did not heal development.services.yml in develop worktree!"
    exit 1
fi

echo "✅ gar sync passed!"

echo ""
echo "🎉 All tests passed successfully!"

