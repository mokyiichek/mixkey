#!/bin/zsh
# Downloads third-party dictionary data (not committed to git; see README "Data & licenses").
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data/raw
cd data/raw
RIME=https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts
OPENCC=https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/dictionary
FREQ=https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
for f in 8105.dict.yaml base.dict.yaml; do [[ -s $f ]] || curl -fL# -o $f "$RIME/$f"; done
for f in STPhrases.txt STCharacters.txt; do [[ -s $f ]] || curl -fL# -o $f "$OPENCC/$f"; done
[[ -s en_50k.txt ]] || curl -fL# -o en_50k.txt "$FREQ"
echo "Data ready in data/raw"
