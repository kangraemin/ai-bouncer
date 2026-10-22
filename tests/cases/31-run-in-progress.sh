#!/usr/bin/env bash
# 케이스 31 — `bouncer run` 이 도는 동안 Stop 은 막지 않는다.
#
# 2026-10-22 감사: 백그라운드로 e2e 를 돌려 두고 멈추면 "아직 통과 기록이 없다"로 막혀
# 기다리는 동안 턴을 계속 다시 열었다. 실행 중이면 안내만 하고 단계는 그대로 둔다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_run.yaml" <<'Y'
version: 1
workflows:
  simple: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 검사, run: "sleep 3", blocking: true}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_run.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start simple running >/dev/null

bouncer run "verify/검사" >/dev/null 2>&1 &
RP=$!
for i in $(seq 1 40); do [ -n "$(state '.running["verify/검사"] // ""')" ] && break; sleep 0.1; done
[ -n "$(state '.running["verify/검사"] // ""')" ] && ok "실행 중 표시를 남긴다" || no "실행 중 표시 없음"

r=$(stop)
printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && no "실행 중인데 막았다" "${r:0:100}" || ok "실행 중이면 막지 않는다"
printf '%s' "$r" | jq -r '.systemMessage // ""' | grep -q '실행 중: 검사' \
  && ok "무엇이 도는지 알린다" || no "안내 없음" "${r:0:100}"
# additionalContext 는 턴을 다시 열어, 실행 내내 "아직 실행 중" 응답이 반복됐다 (2026-10-23).
printf '%s' "$r" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && no "턴을 다시 연다" "${r:0:100}" || ok "턴을 다시 열지 않는다"
r=$(stop); [ -z "$r" ] && ok "안내는 한 번만" || no "반복 안내" "${r:0:100}"
[ "$(stage)" = verify ] && ok "단계는 넘기지 않는다" || no "넘어감" "$(stage)"

wait "$RP"
[ -z "$(state '.running["verify/검사"] // ""')" ] && ok "끝나면 표시를 지운다" || no "표시 잔류"
stop >/dev/null
[ "$(stage)" = done ] && ok "끝난 뒤에는 결과로 전이한다" || no "전이" "$(stage)"

# 실행 기록이 없으면 평소대로 통과 기록을 요구한다
bouncer cancel >/dev/null 2>&1
bouncer start simple dead >/dev/null
r=$(stop)
printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "실행 기록 없으면 평소대로 막는다" || no "안 막음" "${r:0:100}"
finish
