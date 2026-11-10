#!/bin/zsh
# Builds MixKey and installs it for the current user (~/Library/Input Methods).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
DEST="$HOME/Library/Input Methods/MixKey.app"
mkdir -p "$HOME/Library/Input Methods"
pkill -x MixKey 2>/dev/null || true
rm -rf "$DEST"
cp -R build/MixKey.app "$DEST"
"$DEST/Contents/MacOS/MixKey" --install --select
echo
echo "Installed. Pick 混 MixKey from the input menu in the menu bar (or press Ctrl+Space / Fn to cycle)."
echo "If it doesn't appear: System Settings › Keyboard › Input Sources › Edit… › + › Chinese, Simplified › MixKey."
echo
echo "After an UPDATE: apps that were already open may not reach the new MixKey (you can't type there)."
echo "Switch to another app and back; if that app still can't type, quit and reopen it."
