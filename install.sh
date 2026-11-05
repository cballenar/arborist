#!/usr/bin/env bash
# Installer for Git Arborist (gar) Binary & Shell Integration
set -e

GAR_GITHUB_REPO="${GAR_GITHUB_REPO:-cballenar/arborist}"
GAR_INSTALL_DIR="${GAR_INSTALL_DIR:-$HOME/.arborist/bin}"
GAR_VERSION="${GAR_VERSION:-latest}"

REPO_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi

FORCE=false
UNINSTALL=false
FROM_SOURCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;
        --from-source)
            FROM_SOURCE=true
            shift
            ;;
        --version)
            GAR_VERSION="$2"
            shift 2
            ;;
        --version=*)
            GAR_VERSION="${1#*=}"
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
            echo "  -f, --force          Force install / overwrite existing integration without prompting"
            echo "  --from-source        Compile binary locally with 'zig build' instead of downloading a release"
            echo "  --version <tag>      Install a specific GitHub Release tag (default: latest)"
            echo "  --uninstall          Remove Git Arborist binary and shell integration from profile"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: ./install.sh [-f|--force] [--from-source] [--version <tag>] [--uninstall]"
            exit 1
            ;;
    esac
done

# Detect Shell Profile
PROFILE=""
if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    PROFILE="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ] || [ -f "$HOME/.bashrc" ]; then
    PROFILE="$HOME/.bashrc"
else
    PROFILE="$HOME/.profile"
fi

DISPLAY_PROFILE="${PROFILE/#$HOME/~}"

# Resolve symlink to real profile file if needed (e.g. dotfiles repository symlinks)
TARGET_FILE="$PROFILE"
while [ -L "$TARGET_FILE" ]; do
    TARGET_DIR="$(cd "$(dirname "$TARGET_FILE")" >/dev/null 2>&1 && pwd -P)"
    TARGET_FILE="$(readlink "$TARGET_FILE")"
    [[ "$TARGET_FILE" != /* ]] && TARGET_FILE="$TARGET_DIR/$TARGET_FILE"
done

# Detect standard PATH directory for standalone executable (agents, scripts, subshells)
CANDIDATE_DIRS=("/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin")
STANDALONE_DIR="${GAR_STANDALONE_DIR:-}"
if [ -z "$STANDALONE_DIR" ]; then
    for d in "${CANDIDATE_DIRS[@]}"; do
        if [ -d "$d" ] && [ -w "$d" ]; then
            STANDALONE_DIR="$d"
            break
        fi
    done
fi

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
            rm -f "$d/gar" 2>/dev/null || true
        fi
        if [ -L "$d/arborist" ] || [ -f "$d/arborist" ]; then
            rm -f "$d/arborist" 2>/dev/null || true
        fi
    done
    if [ -f "$GAR_INSTALL_DIR/arborist" ]; then
        rm -f "$GAR_INSTALL_DIR/arborist"
        rmdir "$GAR_INSTALL_DIR" 2>/dev/null || true
    fi
    if [ -f "$TARGET_FILE" ] && grep -q "arborist.*hook\|gar.*hook\|wrapper\.sh" "$TARGET_FILE" 2>/dev/null; then
        sed -i.bak '/# Git Arborist/d; /arborist.*hook/d; /gar.*hook/d; /wrapper\.sh/d' "$TARGET_FILE" && rm -f "$TARGET_FILE.bak"
        echo "Successfully removed from $DISPLAY_PROFILE and PATH!"
        echo ""
        echo "To apply changes immediately, run:"
        echo "  source $DISPLAY_PROFILE"
    else
        echo "Git Arborist integration removed."
    fi
    exit 0
fi

detect_platform_asset() {
    local uname_s uname_m os arch
    uname_s="$(uname -s)"
    uname_m="$(uname -m)"

    case "$uname_s" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *)
            echo "Error: Unsupported operating system: $uname_s" >&2
            return 1
            ;;
    esac

    case "$uname_m" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64)  arch="x86_64" ;;
        *)
            echo "Error: Unsupported architecture: $uname_m" >&2
            return 1
            ;;
    esac

    echo "arborist-${os}-${arch}"
}

mkdir -p "$GAR_INSTALL_DIR"
BIN_PATH="$GAR_INSTALL_DIR/arborist"
INSTALLED_BINARY=false

if [ "$FROM_SOURCE" = false ]; then
    ASSET_NAME="$(detect_platform_asset)"
    if [ "$GAR_VERSION" = "latest" ]; then
        DOWNLOAD_URL="https://github.com/${GAR_GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"
    else
        DOWNLOAD_URL="https://github.com/${GAR_GITHUB_REPO}/releases/download/${GAR_VERSION}/${ASSET_NAME}"
    fi

    echo "⬇️  Downloading prebuilt binary ($ASSET_NAME) from GitHub Releases..."
    TMP_BIN="$GAR_INSTALL_DIR/.arborist.download.$$"
    if command -v curl >/dev/null 2>&1 && curl -fsSL "$DOWNLOAD_URL" -o "$TMP_BIN" 2>/dev/null; then
        chmod +x "$TMP_BIN"
        mv "$TMP_BIN" "$BIN_PATH"
        INSTALLED_BINARY=true
        echo "✅ Installed release binary to $BIN_PATH"
    else
        rm -f "$TMP_BIN"
        if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/build.zig" ]; then
            echo "⚠️  Release binary not available at $DOWNLOAD_URL; falling back to local source build..."
        else
            echo "Error: Failed to download release binary from $DOWNLOAD_URL" >&2
            exit 1
        fi
    fi
fi

if [ "$INSTALLED_BINARY" = false ]; then
    if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/build.zig" ]; then
        if command -v zig >/dev/null 2>&1; then
            echo "🔨 Building Git Arborist from source with Zig..."
            (cd "$REPO_DIR" && zig build -Doptimize=ReleaseFast)
            cp "$REPO_DIR/zig-out/bin/arborist" "$BIN_PATH"
            chmod +x "$BIN_PATH"
            INSTALLED_BINARY=true
            echo "✅ Built and installed binary to $BIN_PATH"
        elif [ -x "$REPO_DIR/zig-out/bin/arborist" ]; then
            cp "$REPO_DIR/zig-out/bin/arborist" "$BIN_PATH"
            chmod +x "$BIN_PATH"
            INSTALLED_BINARY=true
            echo "✅ Installed pre-compiled binary to $BIN_PATH"
        else
            echo "Error: Zig toolchain not found. Install Zig (0.17+) or download a GitHub Release." >&2
            exit 1
        fi
    else
        echo "Error: Local source repository not found for building." >&2
        exit 1
    fi
fi

HOOK_LINE="eval \"\$(\"$BIN_PATH\" hook)\""

echo ""
echo "🌳 Git Arborist Shell Integration"
echo "Target profile: $DISPLAY_PROFILE"
echo ""

ALREADY_INSTALLED=false
if [ -f "$TARGET_FILE" ] && grep -q "arborist.*hook\|gar.*hook\|wrapper\.sh" "$TARGET_FILE" 2>/dev/null; then
    ALREADY_INSTALLED=true
fi

if [ "$ALREADY_INSTALLED" = true ]; then
    if [ "$FORCE" = false ] && [ -t 0 ]; then
        read -p "Shell integration already detected in $DISPLAY_PROFILE. Reinstall / update? [Y/n]: " update_confirm || true
        update_confirm=${update_confirm:-Y}
        if [[ ! "$update_confirm" =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    fi
    sed -i.bak '/# Git Arborist/d; /arborist.*hook/d; /gar.*hook/d; /wrapper\.sh/d' "$TARGET_FILE" && rm -f "$TARGET_FILE.bak"
    echo "" >> "$TARGET_FILE"
    echo "# Git Arborist" >> "$TARGET_FILE"
    echo "$HOOK_LINE" >> "$TARGET_FILE"
    echo "Successfully updated in $DISPLAY_PROFILE!"
else
    echo "" >> "$TARGET_FILE"
    echo "# Git Arborist" >> "$TARGET_FILE"
    echo "$HOOK_LINE" >> "$TARGET_FILE"
    echo "Successfully appended to $DISPLAY_PROFILE!"
fi

if [ -n "$STANDALONE_DIR" ]; then
    if ! ln -sf "$BIN_PATH" "$STANDALONE_DIR/gar" 2>/dev/null || ! ln -sf "$BIN_PATH" "$STANDALONE_DIR/arborist" 2>/dev/null; then
        mkdir -p "$HOME/.local/bin" 2>/dev/null || true
        if [ -d "$HOME/.local/bin" ] && [ -w "$HOME/.local/bin" ]; then
            STANDALONE_DIR="$HOME/.local/bin"
            ln -sf "$BIN_PATH" "$STANDALONE_DIR/gar" 2>/dev/null || true
            ln -sf "$BIN_PATH" "$STANDALONE_DIR/arborist" 2>/dev/null || true
        else
            STANDALONE_DIR=""
        fi
    fi
    if [ -n "$STANDALONE_DIR" ]; then
        echo ""
        echo "Installed standalone binary symlinks in $STANDALONE_DIR (for agents, scripts, and subshells):"
        echo "  $STANDALONE_DIR/gar -> $BIN_PATH"
        echo "  $STANDALONE_DIR/arborist -> $BIN_PATH"
    fi
fi

echo ""
echo "To activate immediately, run:"
echo "  source $DISPLAY_PROFILE"
