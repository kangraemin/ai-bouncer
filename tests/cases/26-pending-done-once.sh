#!/usr/bin/env bash
# 케이스 26 — done 표시가 남았으면 안 끝난 것이다. 막되, 의미 있을 때만 막는다.
#
# 도구를 썼으면(진행) 다시 막고, 같은 사유에 도구 없이 또 멈추면 다시 막지 않는다
# (같은 차단만 반복하는 루프 54건). 어느 쪽이든 단계는 넘어가지 않는다.
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
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=10 >/dev/null
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

bouncer start plan pd >/dev/null
r=$(stop); isblock "$r" && ok "첫 Stop 은 막는다" || no "첫 차단" "${r:0:80}"
printf '%s' "$r" | grep -q "bouncer done" && ok "끝났으면 칠 명령을 알려준다" || no "안내" "${r:0:120}"
pre Bash '{"command":"ls"}' >/dev/null 2>&1
r=$(restop); isblock "$r" && ok "도구를 쓰고 멈추면 다시 막는다" || no "안 끝났는데 통과" "${r:0:80}"
r=$(restop); [ -z "$r" ] && ok "도구 없이 같은 사유로 또 멈추면 막지 않는다" || no "무의미한 반복 차단" "${r:0:80}"
[ "$(stage)" = verify ] && ok "막지 않아도 단계는 그대로" || no "넘어감" "$(stage)"
r=$(stop); isblock "$r" && ok "새 사용자 턴에서는 다시 막는다" || no "새 턴 통과" "${r:0:80}"
bouncer done 'verify/보고A' >/dev/null 2>&1
r=$(restop); isblock "$r" && ok "남은 조건이 바뀌면 다시 막는다" || no "재차단" "${r:0:80}"
bouncer done 'verify/보고B' >/dev/null 2>&1
stop >/dev/null
[ "$(stage)" = done ] && ok "다 표시하면 다음 단계로 간다" || no "전이" "$(stage)"
finish
