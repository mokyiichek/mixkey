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
# Sign with a real certificate when there is one. Apps that are already open only keep talking to an input
# method whose signature they recognise: an ad-hoc signature changes with every build, so after an update
# those apps silently stop typing. A certificate (or a fixed requirement) keeps it the same across builds.
IDENTITY="${MIXKEY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDS=$(security find-identity -p codesigning -v 2>/dev/null || true)
  IDENTITY=$( (grep -m1 '"Developer ID Application' <<<"$IDS" || grep -m1 '"Apple Development' <<<"$IDS" || true) | sed -E 's/.*"(.*)"/\1/')
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  codesign --force --sign - --timestamp=none -r='designated => identifier "com.mixkey.inputmethod.MixKey"' "$APP"
fi
echo "Built $ROOT/$APP"
