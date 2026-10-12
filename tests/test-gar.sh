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
EOF
chmod +x "$TEST_DIR/bin/ddev"

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

echo ""
echo "🎉 All tests passed successfully!"
