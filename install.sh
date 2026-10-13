#!/usr/bin/env bash
# Installer for Git Arborist Shell Integration
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="$REPO_DIR/bin/arborist"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: bin/arborist not found."
    exit 1
fi

FORCE=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  -f, --force     Force install / overwrite existing integration without prompting"
            echo "  --uninstall     Remove Git Arborist shell integration from profile"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: ./install.sh [-f|--force] [--uninstall]"
            exit 1
            ;;
    esac
done

# Detect Shell Profile
PROFILE=""
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    PROFILE="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ] || [ -f "$HOME/.bashrc" ]; then
    PROFILE="$HOME/.bashrc"
else
    PROFILE="$HOME/.profile"
fi

DISPLAY_PROFILE="${PROFILE/#$HOME/~}"

# Detect standard PATH directory for standalone executable (agents, scripts, subshells)
CANDIDATE_DIRS=("/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin")
STANDALONE_DIR=""
for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
        STANDALONE_DIR="$d"
        break
    fi
done

if [ -z "$STANDALONE_DIR" ]; then
    mkdir -p "$HOME/.local/bin" 2>/dev/null || true
    if [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
        STANDALONE_DIR="$HOME/.local/bin"
    fi
fi

if [ "$UNINSTALL" = true ]; then
    echo "🌳 Git Arborist Shell Integration"
    echo "Target profile: $DISPLAY_PROFILE"
    echo ""
    for d in "${CANDIDATE_DIRS[@]}"; do
        if [ -L "$d/gar" ] || [ -f "$d/gar" ]; then
            rm -f "$d/gar"
        fi
        if [ -L "$d/arborist" ] || [ -f "$d/arborist" ]; then
            rm -f "$d/arborist"
        fi
    done
    if [ -f "$PROFILE" ] && grep -q "arborist.*hook\|gar.*hook\|wrapper\.sh" "$PROFILE" 2>/dev/null; then
        sed -i.bak '/# Git Arborist/d; /arborist.*hook/d; /gar.*hook/d; /wrapper\.sh/d' "$PROFILE" && rm -f "$PROFILE.bak"
        echo "Successfully removed from $DISPLAY_PROFILE and PATH!"
        echo ""
        echo "To apply changes immediately, run:"
        echo "  source $DISPLAY_PROFILE"
    else
        echo "Git Arborist integration removed."
    fi
    exit 0
fi

HOOK_LINE="eval \"\$(\"$BIN_PATH\" hook)\""

echo "🌳 Git Arborist Shell Integration"
echo "Target profile: $DISPLAY_PROFILE"
echo ""

ALREADY_INSTALLED=false
if [ -f "$PROFILE" ] && grep -q "arborist.*hook\|gar.*hook\|wrapper\.sh" "$PROFILE" 2>/dev/null; then
    ALREADY_INSTALLED=true
fi

if [ "$ALREADY_INSTALLED" = true ]; then
    if [ "$FORCE" = false ]; then
        read -p "Shell integration already detected in $DISPLAY_PROFILE. Reinstall / update? [Y/n]: " update_confirm || true
        update_confirm=${update_confirm:-Y}
        if [[ ! "$update_confirm" =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    fi
    sed -i.bak '/# Git Arborist/d; /arborist.*hook/d; /gar.*hook/d; /wrapper\.sh/d' "$PROFILE" && rm -f "$PROFILE.bak"
    echo "" >> "$PROFILE"
    echo "# Git Arborist" >> "$PROFILE"
    echo "$HOOK_LINE" >> "$PROFILE"
    echo "Successfully updated in $DISPLAY_PROFILE!"
else
    echo "" >> "$PROFILE"
    echo "# Git Arborist" >> "$PROFILE"
    echo "$HOOK_LINE" >> "$PROFILE"
    echo "Successfully appended to $DISPLAY_PROFILE!"
fi

if [ -n "$STANDALONE_DIR" ]; then
    ln -sf "$BIN_PATH" "$STANDALONE_DIR/gar"
    ln -sf "$BIN_PATH" "$STANDALONE_DIR/arborist"
    echo ""
    echo "Installed standalone binary symlinks in $STANDALONE_DIR (for agents, scripts, and subshells):"
    echo "  $STANDALONE_DIR/gar -> $BIN_PATH"
    echo "  $STANDALONE_DIR/arborist -> $BIN_PATH"
fi

echo ""
echo "To activate immediately, run:"
echo "  source $DISPLAY_PROFILE"
