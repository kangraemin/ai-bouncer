#!/usr/bin/env bash
# 케이스 6 — 같은 단계에서 연속 차단이 상한을 넘으면 사용자에게 넘긴다 (무한루프 방지)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cat > /tmp/_loop.yaml <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [work, done]}
stages:
  work:
    steps:
      - label: 절대 통과 못 하는 게이트
        run: 'exit 1'
        by: engine
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup /tmp/_loop.yaml || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "무한루프" >/dev/null   # config: max_continue=3

for i in 1 2 3; do
  out=$(stop)
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
    && ok "${i}회차: 계속 진행시킴" || no "${i}회차 계속" "$(printf '%s' "$out" | head -c 60)"
done
out=$(stop)
printf '%s' "$out" | jq -e '.decision' >/dev/null 2>&1 && no "상한 초과" "계속 밀어붙임" || ok "상한 초과 시 멈춤 허용"
printf '%s' "$out" | grep -q 'AskUserQuestion' && ok "사용자에게 묻도록 지시" || no "질문 지시"
[ "$(state .continue_streak)" = 0 ] && ok "카운터 리셋" || no "카운터 리셋" "$(state .continue_streak)"
finish
