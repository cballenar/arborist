#!/usr/bin/env bash
# Installer for Git Arborist Shell Integration
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="$REPO_DIR/bin/arborist"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: bin/arborist not found."
    exit 1
fi

# Detect Shell Profile
PROFILE=""
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    PROFILE="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ] || [ -f "$HOME/.bashrc" ]; then
    PROFILE="$HOME/.bashrc"
else
    PROFILE="$HOME/.profile"
fi

HOOK_LINE="eval \"\$(\"$BIN_PATH\" hook)\""

DISPLAY_PROFILE="${PROFILE/#$HOME/~}"

echo "🌳 Git Arborist Shell Integration"
echo "Target profile: $DISPLAY_PROFILE"
echo ""

if grep -q "arborist.*hook\|gar.*hook\|wrapper\.sh" "$PROFILE" 2>/dev/null; then
    echo "Shell integration already detected in $DISPLAY_PROFILE."
else
    echo "" >> "$PROFILE"
    echo "# Git Arborist" >> "$PROFILE"
    echo "$HOOK_LINE" >> "$PROFILE"
    echo "Successfully appended to $DISPLAY_PROFILE!"
fi

echo ""
echo "To activate immediately, run:"
echo "  source $DISPLAY_PROFILE"
