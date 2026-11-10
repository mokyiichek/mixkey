#!/bin/zsh
set -euo pipefail
DEST="$HOME/Library/Input Methods/MixKey.app"
[[ -d "$DEST" ]] && "$DEST/Contents/MacOS/MixKey" --uninstall || true
pkill -x MixKey 2>/dev/null || true
rm -rf "$DEST"
echo "MixKey removed. (Settings remain in ~/Library/Preferences/com.mixkey.inputmethod.MixKey.plist)"
