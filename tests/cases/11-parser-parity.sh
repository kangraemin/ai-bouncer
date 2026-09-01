#!/usr/bin/env bash
# 케이스 11 — pyyaml이 없는 머신에서도 같은 결과가 나와야 한다 (조용한 가드 소실 방지)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 실제 홈을 건드리지 않는다 (install 이 $HOME/.local/bin 에, worktree 가
# $HOME/.ai-bouncer/ 에 쓴다)
if [ -z "${BOUNCER_TEST_HOME:-}" ]; then
  BOUNCER_TEST_HOME="$(mktemp -d)"; export BOUNCER_TEST_HOME HOME="$BOUNCER_TEST_HOME"
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
for f in "$R"/config/default.yaml "$R"/examples/*.yaml "$R"/tests/fixtures/*.yaml; do
  n=$(basename "$f")
  python3 "$R/engine/compile.py" "$f" "$T/a.json" >/dev/null 2>&1 || { no "$n pyyaml"; continue; }
  python3 "$R/engine/compile.py" "$f" "$T/b.json" --builtin-parser >/dev/null 2>&1 || { no "$n 내장"; continue; }
  jq -S 'del(.compiled_at,.parser)' "$T/a.json" > "$T/a2"; jq -S 'del(.compiled_at,.parser)' "$T/b.json" > "$T/b2"
  diff -q "$T/a2" "$T/b2" >/dev/null && ok "$n 두 파서 결과 일치" || no "$n 파서 불일치"
done
# 모르는 이스케이프를 조용히 통과시키면 pyyaml과 결과가 갈린다 — 거부해야 한다.
printf 'version: 1\nworkflows:\n  s: {label: t, stages: [a]}\nstages:\n  a:\n    steps: [{label: l, inject: "bad \\q"}]\n' > "$T/bad.yaml"
for parser in "" "--builtin-parser"; do
  # shellcheck disable=SC2086
  if python3 "$R/engine/compile.py" "$T/bad.yaml" "$T/x.json" $parser >/dev/null 2>&1; then
    no "잘못된 이스케이프 거부 (${parser:-pyyaml})" "통과됨"
  else
    ok "잘못된 이스케이프 거부 (${parser:-pyyaml})"
  fi
done

finish
