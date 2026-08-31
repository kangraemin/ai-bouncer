#!/usr/bin/env bash
# 케이스 11 — pyyaml이 없는 머신에서도 같은 결과가 나와야 한다 (조용한 가드 소실 방지)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
for f in "$R"/config/default.yaml "$R"/examples/*.yaml "$R"/tests/fixtures/*.yaml; do
  n=$(basename "$f")
  python3 "$R/engine/compile.py" "$f" "$T/a.json" >/dev/null 2>&1 || { no "$n pyyaml"; continue; }
  python3 "$R/engine/compile.py" "$f" "$T/b.json" --builtin-parser >/dev/null 2>&1 || { no "$n 내장"; continue; }
  jq -S 'del(.compiled_at,.parser)' "$T/a.json" > "$T/a2"; jq -S 'del(.compiled_at,.parser)' "$T/b.json" > "$T/b2"
  diff -q "$T/a2" "$T/b2" >/dev/null && ok "$n 두 파서 결과 일치" || no "$n 파서 불일치"
done
finish
