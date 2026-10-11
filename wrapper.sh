# Git Arborist (gar) - Shell Wrapper
# Sourced dynamically or manually in ~/.zshrc or ~/.bashrc

_ARBORIST_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_ARBORIST_WRAPPER_DIR/bin/arborist" ]; then
    eval "$("$_ARBORIST_WRAPPER_DIR/bin/arborist" hook)"
fi
unset _ARBORIST_WRAPPER_DIR
