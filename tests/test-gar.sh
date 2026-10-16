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
echo "[MOCK DDEV] Executed: ddev $*" >&2
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

if [ "$1" = "export-db" ]; then
    if [[ "$*" != *"--file"* ]]; then
        if [[ "$*" != *"--gzip=false"* ]]; then
            printf '\x1f\x8b\x08\x00'
        else
            echo "CREATE TABLE test (id INT);"
        fi
    fi
    exit 0
fi

if [ "$1" = "import-db" ]; then
    if [[ "$*" != *"--file"* ]]; then
        if python3 -c "import sys; sys.exit(0 if b'\x00' in sys.stdin.buffer.read() else 1)" 2>/dev/null; then
            echo "ERROR: ASCII '\0' appeared in the statement, but this is not allowed unless option --binary-mode is enabled and mysql is run in non-interactive mode. Set --binary-mode to 1 if ASCII '\0' is expected. Query: ''." >&2
            exit 1
        fi
    fi
    exit 0
fi
EOF
chmod +x "$TEST_DIR/bin/ddev"

cat << 'EOF' > "$TEST_DIR/bin/drush"
#!/bin/bash
echo "[MOCK DRUSH] ${FEATURE_API_KEY:+KEY=$FEATURE_API_KEY }$*"
EOF
chmod +x "$TEST_DIR/bin/drush"
chmod +x "$TEST_DIR/bin/ddev"
echo "db" > "$TEST_DIR/mock-dbs.txt"
ln -sf "$GAR_BIN" "$TEST_DIR/bin/gar"
ln -sf "$GAR_BIN" "$TEST_DIR/bin/arborist"

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


# 8.6 Test: Provisioning strategy overrides (--clone)
"$GAR_BIN" switch -c --clone feature-clone-test 3>/dev/null
if ! grep -q "export-db --gzip=false --database=db" "$TEST_DIR/ddev.log"; then
    echo "❌ DB switch --clone failed: did not clone via export-db"
    exit 1
fi
if ! grep -q "import-db --database=db_feature_clone_test" "$TEST_DIR/ddev.log"; then
    echo "❌ DB switch --clone failed: did not import into db_feature_clone_test"
    exit 1
fi

# 8.7 Test: Standalone PATH binary invocation with -y (agent simulation)
GAR_AUTO_YES=false gar switch -c -y feature-agent-test 3>/dev/null
if ! grep -q "import-db --database=db_feature_agent_test" "$TEST_DIR/ddev.log"; then
    echo "❌ Standalone PATH binary gar switch -c -y failed"
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

# 10.2b Test: 'gar switch' unfetched remote branch without prior manual fetch
git -C "$REMOTE_REPO" branch feature-unfetched-remote develop
UNFETCHED_TARGET=$("$GAR_BIN" switch feature-unfetched-remote)
if [ "$UNFETCHED_TARGET" != "$HUB_DIR/feature-unfetched-remote" ] || [ ! -d "$HUB_DIR/feature-unfetched-remote" ]; then
    echo "❌ gar switch unfetched remote branch failed: worktree not created"
    exit 1
fi
UNFETCHED_UPSTREAM=$(git -C "$HUB_DIR/feature-unfetched-remote" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
if [ "$UNFETCHED_UPSTREAM" != "origin/feature-unfetched-remote" ]; then
    echo "❌ gar switch unfetched remote branch failed: expected upstream 'origin/feature-unfetched-remote', got '$UNFETCHED_UPSTREAM'"
    exit 1
fi
"$GAR_BIN" remove -f feature-unfetched-remote

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
SLASH_DIR="bsph-dwc-27-test-feature"
SLASH_TARGET=$("$GAR_BIN" switch -c "$SLASH_BRANCH")
if [ "$SLASH_TARGET" != "$HUB_DIR/$SLASH_DIR" ] || [ ! -d "$HUB_DIR/$SLASH_DIR" ]; then
    echo "❌ Slashed branch switch failed: expected $HUB_DIR/$SLASH_DIR, got $SLASH_TARGET"
    exit 1
fi

if [ -d "$HUB_DIR/bsph" ]; then
    echo "❌ Slashed branch switch created nested directory 'bsph'"
    exit 1
fi

# Verify Drupal files were provisioned in worktree
if [ ! -f "$HUB_DIR/$SLASH_DIR/docroot/sites/default/settings.workspace.php" ]; then
    echo "❌ settings.workspace.php not provisioned in $SLASH_DIR"
    exit 1
fi
if [ ! -f "$HUB_DIR/$SLASH_DIR/docroot/sites/development.services.yml" ]; then
    echo "❌ development.services.yml not provisioned in $SLASH_DIR"
    exit 1
fi

# Test gar info from inside the worktree root
cd "$HUB_DIR/$SLASH_DIR"
INFO_OUT=$("$GAR_BIN" info 2>&1)
if ! echo "$INFO_OUT" | grep -q "Current Branch: $SLASH_BRANCH"; then
    echo "❌ gar info failed to detect current branch for slashed branch. Got:"
    echo "$INFO_OUT"
    exit 1
fi
if ! echo "$INFO_OUT" | grep -q "DB Name:        db_bsph_dwc_27_test_feature"; then
    echo "❌ gar info resolved incorrect database for slashed branch. Got:"
    echo "$INFO_OUT"
    exit 1
fi
if ! echo "$INFO_OUT" | grep -q "URL:            https://bsph-dwc-27-test-feature.test-project.ddev.site"; then
    echo "❌ gar info resolved incorrect URL for slashed branch. Got:"
    echo "$INFO_OUT"
    exit 1
fi

# Test gar info from inside worktree subfolder (docroot/sites/default)
cd "$HUB_DIR/$SLASH_DIR/docroot/sites/default"
INFO_SUB=$("$GAR_BIN" info 2>&1)
if ! echo "$INFO_SUB" | grep -q "DB Name:        db_bsph_dwc_27_test_feature"; then
    echo "❌ gar info from subfolder resolved incorrect database. Got:"
    echo "$INFO_SUB"
    exit 1
fi

# Test gar info from hub root
cd "$HUB_DIR"
INFO_HUB=$("$GAR_BIN" info 2>&1)
if ! echo "$INFO_HUB" | grep -q "Current Branch: develop"; then
    echo "❌ gar info from hub root failed to detect default branch. Got:"
    echo "$INFO_HUB"
    exit 1
fi
if ! echo "$INFO_HUB" | grep -q "URL:            https://test-project.ddev.site"; then
    echo "❌ gar info from hub root resolved incorrect URL. Got:"
    echo "$INFO_HUB"
    exit 1
fi

# Verify environment_indicator recipe in settings.workspace.php
if ! grep -q "environment_indicator.indicator" "$HUB_DIR/$SLASH_DIR/docroot/sites/default/settings.workspace.php"; then
    echo "❌ environment_indicator recipe not injected in settings.workspace.php"
    exit 1
fi

if command -v php >/dev/null 2>&1; then
    mkdir -p "$HUB_DIR/$SLASH_DIR/docroot/modules/contrib/environment_indicator"
    ENV_NAME_OUT=$(php -r "
        chdir('$HUB_DIR/$SLASH_DIR/docroot/sites/default');
        require 'settings.workspace.php';
        echo isset(\$config['environment_indicator.indicator']['name']) ? \$config['environment_indicator.indicator']['name'] : 'none';
    ")
    if [ "$ENV_NAME_OUT" != "$SLASH_BRANCH" ]; then
        echo "❌ environment_indicator name override failed! Expected '$SLASH_BRANCH', got '$ENV_NAME_OUT'"
        exit 1
    fi
fi

# Verify Drush wrapper URI generation for feature worktree
cd "$HUB_DIR/$SLASH_DIR"
DRUSH_WT_OUT=$(DDEV_PRIMARY_URL="https://test-project.ddev.site" DDEV_SCHEME="https" "$HUB_DIR/.ddev/commands/web/drush" status 2>&1)
if ! echo "$DRUSH_WT_OUT" | grep -q -- "--uri=https://bsph-dwc-27-test-feature.test-project.ddev.site"; then
    echo "❌ Drush wrapper failed to pass isolated URI for feature worktree! Got:"
    echo "$DRUSH_WT_OUT"
    exit 1
fi

# Verify Drush wrapper URI generation for default branch worktree
cd "$HUB_DIR/develop"
DRUSH_DEV_OUT=$(DDEV_PRIMARY_URL="https://test-project.ddev.site" DDEV_SCHEME="https" "$HUB_DIR/.ddev/commands/web/drush" status 2>&1)
if ! echo "$DRUSH_DEV_OUT" | grep -q -- "--uri=https://test-project.ddev.site"; then
    echo "❌ Drush wrapper failed to pass primary URI for develop worktree! Got:"
    echo "$DRUSH_DEV_OUT"
    exit 1
fi

cd "$HUB_DIR"
"$GAR_BIN" remove -f "$SLASH_BRANCH"
if [ -d "$HUB_DIR/$SLASH_DIR" ]; then
    echo "❌ Slashed branch worktree was not removed"
    exit 1
fi

echo "✅ Slashed Branch Resolution and Drush Wrapper passed!"

# 11.5 Test: Branch Names with Capitals and Case-Insensitive Routing
echo ""
echo "=> Testing: Branch Names with Capitals and Case-Insensitive Routing"
CAPS_BRANCH="Feature/CAPS-99-Test"
CAPS_DIR="feature-caps-99-test"
CAPS_DB="db_feature_caps_99_test"

"$GAR_BIN" switch -c "$CAPS_BRANCH" 3>/dev/null

if [ ! -d "$HUB_DIR/$CAPS_DIR" ]; then
    echo "❌ Capital branch worktree directory was not normalized to lowercase! Expected $CAPS_DIR"
    exit 1
fi

CURRENT_GIT_BRANCH=$(git -C "$HUB_DIR/$CAPS_DIR" rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_GIT_BRANCH" != "$CAPS_BRANCH" ]; then
    echo "❌ Git branch casing was not preserved! Expected '$CAPS_BRANCH', got '$CURRENT_GIT_BRANCH'"
    exit 1
fi

if ! grep -q "CREATE DATABASE IF NOT EXISTS \`$CAPS_DB\`" "$TEST_DIR/ddev.log"; then
    echo "❌ Database name for capital branch was not normalized to lowercase! Expected $CAPS_DB"
    exit 1
fi

# Verify gar info output
cd "$HUB_DIR/$CAPS_DIR"
INFO_CAPS=$("$GAR_BIN" info 2>&1)
if ! echo "$INFO_CAPS" | grep -q "Current Branch: $CAPS_BRANCH"; then
    echo "❌ gar info did not display preserved branch casing! Got:"
    echo "$INFO_CAPS"
    exit 1
fi
if ! echo "$INFO_CAPS" | grep -q "DB Name:        $CAPS_DB"; then
    echo "❌ gar info did not display lowercase DB name! Got:"
    echo "$INFO_CAPS"
    exit 1
fi
if ! echo "$INFO_CAPS" | grep -q "URL:            https://$CAPS_DIR.test-project.ddev.site"; then
    echo "❌ gar info did not display lowercase URL! Got:"
    echo "$INFO_CAPS"
    exit 1
fi

# Verify environment indicator recipe resolves branch casing
if command -v php >/dev/null 2>&1; then
    mkdir -p "$HUB_DIR/$CAPS_DIR/docroot/modules/contrib/environment_indicator"
    ENV_NAME_OUT=$(php -r "
        chdir('$HUB_DIR/$CAPS_DIR/docroot/sites/default');
        require 'settings.workspace.php';
        echo isset(\$config['environment_indicator.indicator']['name']) ? \$config['environment_indicator.indicator']['name'] : 'none';
    ")
    if [ "$ENV_NAME_OUT" != "$CAPS_BRANCH" ]; then
        echo "❌ environment_indicator name override for capital branch failed! Expected '$CAPS_BRANCH', got '$ENV_NAME_OUT'"
        exit 1
    fi
fi

# Verify Drush wrapper URI is lowercase
DRUSH_CAPS_OUT=$(DDEV_PRIMARY_URL="https://test-project.ddev.site" DDEV_SCHEME="https" "$HUB_DIR/.ddev/commands/web/drush" status 2>&1)
if ! echo "$DRUSH_CAPS_OUT" | grep -q -- "--uri=https://$CAPS_DIR.test-project.ddev.site"; then
    echo "❌ Drush wrapper failed to generate lowercase URI for capital branch! Got:"
    echo "$DRUSH_CAPS_OUT"
    exit 1
fi

# Verify switching back to develop then switching to capital branch using lowercase
cd "$HUB_DIR"
"$GAR_BIN" switch develop 3>/dev/null
SWITCH_LOWER_OUT=$("$GAR_BIN" switch "$CAPS_DIR" 3>/dev/null)
if [ ! -d "$HUB_DIR/$CAPS_DIR" ]; then
    echo "❌ Failed to switch to capital branch using lowercase name"
    exit 1
fi

# Test auto-healing: manually create worktree with capitals, then switch to it
cd "$HUB_DIR"
"$GAR_BIN" remove -f "$CAPS_BRANCH"

git worktree add Legacy-Capital-Branch -b Legacy-Capital-Branch 2>/dev/null
if [ -d "$HUB_DIR/Legacy-Capital-Branch" ]; then
    HEAL_SWITCH_OUT=$("$GAR_BIN" switch Legacy-Capital-Branch 2>&1)
    if [ ! -d "$HUB_DIR/legacy-capital-branch" ]; then
        echo "❌ Switch did not auto-heal uppercase worktree directory to lowercase!"
        exit 1
    fi
    cd "$HUB_DIR"
    "$GAR_BIN" remove -f legacy-capital-branch
fi

echo "✅ Branch Names with Capitals and Case-Insensitive Routing passed!"

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

if ! grep -q "/var/www/nonexistent" "$HUB_DIR/.ddev/nginx_full/workspace-nginx.conf"; then
    echo "❌ gar sync did not update .ddev/nginx_full/workspace-nginx.conf with guarded nested logic!"
    exit 1
fi

if ! grep -q 'if ($branch = "develop")' "$HUB_DIR/.ddev/nginx_full/workspace-nginx.conf"; then
    echo "❌ gar sync did not configure default branch redirect in workspace-nginx.conf!"
    exit 1
fi

echo "✅ gar sync passed!"

# 14. Test: Mutagen sync daemon flush
echo ""
echo "=> Testing: Mutagen sync daemon flush"
if ! grep -q "^mutagen sync" "/tmp/gar-test-env/ddev.log"; then
    echo "❌ flush_env_sync did not call 'ddev mutagen sync'! Check ddev.log:"
    cat "/tmp/gar-test-env/ddev.log"
    exit 1
fi
echo "✅ Mutagen sync daemon flush passed!"

# 15. Test: Worktree .env Isolation, Seeding, and Runtime Evaluation
echo ""
echo "=> Testing: Worktree .env Isolation, Seeding, and Runtime Evaluation"

# 15a. Verify .env and .env.local are excluded in git info exclude
if ! grep -q "^\.env$" "$HUB_DIR/.git/info/exclude" 2>/dev/null; then
    echo "❌ .env is not in $HUB_DIR/.git/info/exclude!"
    exit 1
fi
if ! grep -q "^\.env\.local$" "$HUB_DIR/.git/info/exclude" 2>/dev/null; then
    echo "❌ .env.local is not in $HUB_DIR/.git/info/exclude!"
    exit 1
fi

# 15b. Create .env in develop to test automatic seeding on switch -c
cat << 'EOF' > "$HUB_DIR/develop/.env"
GLOBAL_TEST_VAR="seeded_from_develop"
OVERRIDE_VAR="base_develop"
EOF

"$GAR_BIN" switch -c feature-env-test
if [ ! -f "$HUB_DIR/feature-env-test/.env" ]; then
    echo "❌ feature-env-test/.env was not seeded from develop!"
    exit 1
fi
if ! grep -q 'GLOBAL_TEST_VAR="seeded_from_develop"' "$HUB_DIR/feature-env-test/.env"; then
    echo "❌ feature-env-test/.env does not contain seeded content from develop!"
    exit 1
fi

# 15c. Add branch-specific overrides, quotes, comments, and local overrides
cat << 'EOF' >> "$HUB_DIR/feature-env-test/.env"
FEATURE_API_KEY="feature_isolated_key_123"
QUOTED_HASH='secret#with#hash'
COMMENT_VAR=hello # unquoted comment
EOF

cat << 'EOF' > "$HUB_DIR/feature-env-test/.env.local"
OVERRIDE_VAR="local_override_active"
EOF

# 15d. Verify PHP evaluation via settings.workspace.php
if command -v php >/dev/null 2>&1; then
    ENV_EVAL_OUT=$(php -r "
        chdir('$HUB_DIR/feature-env-test/docroot/sites/default');
        require 'settings.workspace.php';
        \$k1 = getenv('FEATURE_API_KEY');
        \$k2 = getenv('QUOTED_HASH');
        \$k3 = getenv('COMMENT_VAR');
        \$k4 = getenv('OVERRIDE_VAR');
        \$k5 = isset(\$_ENV['FEATURE_API_KEY']) ? \$_ENV['FEATURE_API_KEY'] : '';
        \$k6 = isset(\$_SERVER['FEATURE_API_KEY']) ? \$_SERVER['FEATURE_API_KEY'] : '';
        if (\$k1 === 'feature_isolated_key_123' &&
            \$k2 === 'secret#with#hash' &&
            \$k3 === 'hello' &&
            \$k4 === 'local_override_active' &&
            \$k5 === 'feature_isolated_key_123' &&
            \$k6 === 'feature_isolated_key_123') {
            echo 'ENV_OK';
        } else {
            echo \"FAIL: k1=\$k1 k2=\$k2 k3=\$k3 k4=\$k4 k5=\$k5 k6=\$k6\";
        }
    ")
    if [ "$ENV_EVAL_OUT" != "ENV_OK" ]; then
        echo "❌ settings.workspace.php failed to evaluate worktree .env! Output: $ENV_EVAL_OUT"
        exit 1
    fi
fi

# 15e. Verify DDEV drush command wrapper sources .env
DRUSH_WRAPPER_OUT=$(cd "$HUB_DIR/feature-env-test" && "$HUB_DIR/.ddev/commands/web/drush" status 2>/dev/null)
if ! echo "$DRUSH_WRAPPER_OUT" | grep -q "KEY=feature_isolated_key_123"; then
    echo "❌ drush command wrapper did not source feature-env-test/.env! Output:"
    echo "$DRUSH_WRAPPER_OUT"
    exit 1
fi

# Clean up test worktree
"$GAR_BIN" remove -f feature-env-test
rm -f "$HUB_DIR/develop/.env"

echo "✅ Worktree .env Isolation, Seeding, and Runtime Evaluation passed!"

echo ""
echo "🎉 All tests passed successfully!"

