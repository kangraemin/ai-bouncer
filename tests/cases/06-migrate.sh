#!/usr/bin/env bash
# 케이스 06 — 옛 형식 workflow.yaml 변환 (run 만 살리고 나머지는 기본값에 맡긴다)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/w.yaml" <<'Y'
version: 1
settings: {max_continue: 5}
workflows:
  simple: {label: 옛 모드, stages: [implement, verify, done]}
stages:
  verify:
    forbid: [push]
    steps:
      - {label: 테스트, run: "npm test {scope}"}
      - {label: 린트, run: "npm run lint"}
      - {label: 보고, inject: "보고해라"}
  done:
    steps: [{label: 완료, inject: 끝}]
Y
python3 "$R/engine/migrate-workflow.py" "$T/w.yaml" >/dev/null 2>&1
O="$(python3 "$R/engine/compile.py" "$T/w.yaml" 2>&1)" && ok "변환 결과가 컴파일된다" || no "컴파일" "$O"
[ "$(jq -c '.stages.verify.run' <<<"$O")" = '["npm test","npm run lint"]' ] && ok "run 은 단계 run 으로 ({scope} 제거)" || no "run" "$(jq -c .stages.verify.run <<<"$O")"
[ -f "$T/w.yaml.bak" ] && ok "원본은 .bak 로 남긴다" || no ".bak"
grep -q 'settings\|forbid\|steps' "$T/w.yaml" && no "옛 키 잔존" "$(cat "$T/w.yaml")" || ok "옛 키는 버린다"
cp "$T/w.yaml" "$T/once"; python3 "$R/engine/migrate-workflow.py" "$T/w.yaml" >/dev/null 2>&1
cmp -s "$T/w.yaml" "$T/once" && ok "두 번 돌려도 그대로(멱등)" || no "멱등"
printf 'stages:\n  verify: {run: make}\n' > "$T/n.yaml"; cp "$T/n.yaml" "$T/n0"
python3 "$R/engine/migrate-workflow.py" "$T/n.yaml" >/dev/null 2>&1; cmp -s "$T/n.yaml" "$T/n0" && ok "새 형식은 건드리지 않는다" || no "새 형식 변경"
finish
