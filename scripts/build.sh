#!/bin/zsh
# Builds build/MixKey.app (release).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

# Keep big generated folders out of Dropbox sync (harmless elsewhere).
mkdir -p build .build data/raw
for d in build .build data/raw; do xattr -w com.dropbox.ignored 1 "$d" 2>/dev/null || true; done

[[ -s data/raw/base.dict.yaml ]] || scripts/fetch-data.sh
if [[ ! -s build/mixkey.db || tools/build_dict.py -nt build/mixkey.db || data/lexicon/proper_nouns.txt -nt build/mixkey.db ]]; then
  python3 tools/build_dict.py
fi

if [[ ! -s build/icons/MixKey.tiff || tools/make_icon.swift -nt build/icons/MixKey.tiff ]]; then
  mkdir -p build/icons
  swift tools/make_icon.swift build/icons
  iconutil -c icns build/icons/MixKey.iconset -o build/icons/MixKey.icns
fi

swift build -c release --product MixKey

APP=build/MixKey.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MixKey "$APP/Contents/MacOS/MixKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp build/mixkey.db build/icons/MixKey.tiff build/icons/MixKey.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $ROOT/$APP"
