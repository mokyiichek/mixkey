#!/bin/zsh
# Checks the engine's best guess for each case in tools/engine_cases.tsv.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build --product mixkey-cli >/dev/null || exit 1
pass=0; fail=0
while IFS=$'\t' read -r input expected; do
  [[ -z "$input" || "$input" == \#* ]] && continue
  got=$(.build/debug/mixkey-cli "$input" | head -1 | sed -E 's/^.*  =>  (.*)   \[.*$/\1/')
  if [[ "$got" == "$expected" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: '$input' => '$got' (expected '$expected')"; fi
done < tools/engine_cases.tsv
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
