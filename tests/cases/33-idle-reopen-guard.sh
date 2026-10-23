#!/usr/bin/env bash
# 케이스 33 — 안 끝났으면 막는다. 단, 같은 차단을 도구 없이 반복할 때는 다시 막지 않는다.
#
# 2026-10-22 ttuk-chiro-clinic: 차단할 때마다 모델이 도구 없이 한 줄만 답해 5회 이상 연속
# 루프가 54건 나왔다. 그렇다고 "다음 턴에 확인한다"며 통과시키면 안 끝난 채로 끝난다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_idle.yaml" <<'Y'
version: 1
workflows:
  simple: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 검사, run: "false", blocking: true}
      - {label: 확인, inject: "확인하고 bouncer done 해라.", blocking: true}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_idle.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=10 >/dev/null
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }
bouncer start simple idle >/dev/null
TASKDIR="$(task_dir)"
tool(){ printf '%s' "$(( $(cat "$TASKDIR/.tool_seq" 2>/dev/null || echo 0) + 1 ))" > "$TASKDIR/.tool_seq"; }

r=$(stop); isblock "$r" && ok "안 끝났으면 막는다" || no "첫 Stop" "${r:0:100}"
r=$(restop); [ -z "$r" ] && ok "도구 없이 같은 사유로 또 멈추면 다시 막지 않는다" || no "반복 차단" "${r:0:100}"
printf '%s' "$r" | grep -q '다음 턴' && no "다음 턴으로 미루는 안내" "${r:0:100}" || ok "다음 턴으로 미루는 안내를 내지 않는다"
[ "$(stage)" = verify ] && ok "단계는 그대로다 (통과가 아니다)" || no "넘어감" "$(stage)"

# 도구를 쓰고 멈춘 재진입은 진행 중이다 — 계속 막는다.
n=0
for i in 1 2 3 4; do tool; r=$(restop); isblock "$r" && n=$((n+1)); done
[ "$n" = 4 ] && ok "도구를 쓰는 동안은 계속 막는다" || no "진행 중인데 통과" "$n/4"

# 사용자 턴 뒤 첫 Stop 은 다시 막는다.
r=$(stop); isblock "$r" && ok "새 사용자 턴은 다시 막는다" || no "새 턴 통과" "${r:0:100}"
finish
