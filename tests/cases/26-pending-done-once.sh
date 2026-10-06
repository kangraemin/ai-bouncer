#!/usr/bin/env bash
# 케이스 26 — done 표시만 남았으면 한 번만 막고, 같은 조건이면 이후엔 멈추게 둔다.
#
# 백그라운드 작업을 기다리며 가벼운 도구로 폴링하면 매 Stop 마다
# "아직 완료 표시 안 됨" 차단이 똑같이 반복됐다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 보고A, blocking: done, inject: "보고해라."}
      - {label: 보고B, blocking: done, inject: "또 보고해라."}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

bouncer start plan pd >/dev/null
r=$(stop); isblock "$r" && ok "첫 Stop 은 막는다" || no "첫 차단" "${r:0:80}"
pre Bash '{"command":"ls"}' >/dev/null 2>&1
r=$(stop); isblock "$r" && no "같은 조건인데 또 막았다" "${r:0:80}" || ok "도구를 써도 같은 조건이면 다시 막지 않는다"
printf '%s' "$r" | grep -q "bouncer done" && ok "끝났으면 칠 명령을 알려준다" || no "안내" "${r:0:120}"
bouncer done 'verify/보고A' >/dev/null 2>&1
pre Bash '{"command":"ls"}' >/dev/null 2>&1
r=$(stop); isblock "$r" && ok "남은 조건이 바뀌면 다시 한 번 막는다" || no "재차단" "${r:0:80}"
r=$(stop); isblock "$r" && no "바뀐 조건도 두 번째엔 막지 않아야" "${r:0:80}" || ok "바뀐 조건도 두 번째엔 멈추게 둔다"
bouncer done 'verify/보고B' >/dev/null 2>&1
stop >/dev/null
[ "$(stage)" = done ] && ok "다 표시하면 다음 단계로 간다" || no "전이" "$(stage)"
finish
