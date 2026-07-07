#!/bin/bash
# One-time installer for macOS/Linux: clones/updates eas-local-builder to a
# fixed location and registers a `ssheas` shell function in your
# ~/.bashrc / ~/.zshrc, so you can run `ssheas build ...` from any
# directory instead of typing the full path to the script every time.
#
# Usage (run once):
#   git clone https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git
#   cd eas-local-builder
#   ./install.sh
#
# Safe to re-run later to pick up updates (git pull) -- it won't duplicate
# the rc file entry.
set -euo pipefail

REPO_URL="https://github.com/DEXA-IT-Solutions-Pvt-LTD/eas-local-builder.git"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/eas-local-builder"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required." >&2
  exit 1
fi

# If this script is already being run from inside a real clone (not a
# stray copy), install in place instead of re-cloning elsewhere.
if [ -d "$SCRIPT_DIR/.git" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
  echo "==> Running from an existing clone at $INSTALL_DIR -- installing in place"
elif [ -d "$INSTALL_DIR/.git" ]; then
  echo "==> Updating existing install at $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo "==> Cloning to $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

SCRIPT_PATH="$INSTALL_DIR/ssheas"
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "error: ssheas not found at $SCRIPT_PATH -- something's wrong with the clone." >&2
  exit 1
fi
chmod +x "$SCRIPT_PATH"

# --- Pick which rc file(s) to register the function in ---
RC_FILES=()
[ -f "$HOME/.bashrc" ] && RC_FILES+=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ] && RC_FILES+=("$HOME/.zshrc")
if [ "${#RC_FILES[@]}" -eq 0 ]; then
  # Neither exists yet -- default to .bashrc so there's somewhere to look.
  RC_FILES+=("$HOME/.bashrc")
fi

MARKER_START="# >>> ssheas (eas-local-builder) >>>"
MARKER_END="# <<< ssheas (eas-local-builder) <<<"

for rc in "${RC_FILES[@]}"; do
  touch "$rc"
  if grep -qF "$MARKER_START" "$rc" 2>/dev/null; then
    echo "==> $rc already has a ssheas function -- leaving it as-is."
    echo "    (If the install path changed, edit $rc manually.)"
  else
    {
      echo ""
      echo "$MARKER_START"
      echo "ssheas() { \"$SCRIPT_PATH\" \"\$@\"; }"
      echo "$MARKER_END"
    } >> "$rc"
    echo "==> Added 'ssheas' function to $rc"
  fi
done

# --- .env scaffold ---
ENV_FILE="$INSTALL_DIR/.env"
ENV_EXAMPLE="$INSTALL_DIR/.env.example"
if [ ! -f "$ENV_FILE" ] && [ -f "$ENV_EXAMPLE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "==> Created $ENV_FILE from .env.example"
  echo "    Fill in via: ssheas config set EXPO_TOKEN <value> (etc.), or edit $ENV_FILE directly."
fi

echo ""
echo "==> Done. This only takes effect in NEW shell sessions."
echo "    Either open a new terminal, or run: source ~/.bashrc  (or ~/.zshrc)"
echo "    Then, from inside any Expo project directory:"
echo "        ssheas build --platform android --profile preview"
