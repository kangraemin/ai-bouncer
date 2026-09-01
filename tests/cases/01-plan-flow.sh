#!/usr/bin/env bash
# 케이스 1 — plan 워크플로우 전 구간 (plan → implement → verify → finalize → done)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

echo "── 모드 목록 ──"; bouncer workflows | sed 's/^/  /'

echo "── 작업 시작 ──"
START_OUT="$(bouncer start plan "결제 버그")"
printf '%s\n' "$START_OUT" | head -2 | sed 's/^/  /'
printf '%s' "$START_OUT" | grep -q 'EnterPlanMode' \
  && ok "start가 첫 스테이지 지시를 즉시 전달" || no "첫 지시 전달" "start 출력에 없음"
[ "$(stage)" = plan ] && ok "current_stage=plan" || no "시작" "$(stage)"

echo "── plan 단계 forbid ──"
[ -n "$(pre Edit "{\"file_path\":\"$T/app.js\"}")" ] && ok "Edit 차단" || no "Edit 차단" "통과됨"
[ -n "$(pre Bash '{"command":"echo x > app.js"}')" ] && ok "bash 리다이렉트 차단" || no "bash 우회 차단" "통과됨"
SEDI="$(jq -nc --arg c "sed -i '' s/a/b/ app.js" '{command:$c}')"
[ -n "$(pre Bash "$SEDI")" ] && ok "sed -i 차단" || no "sed -i 차단" "통과됨"
[ -n "$(pre Write "{\"file_path\":\"$T/.ai-bouncer/tasks/x/state.json\"}")" ] && ok "state.json 보호" || no "state.json 보호" "통과됨"
[ -z "$(pre Edit "{\"file_path\":\"$T/app.js\"}" OTHER)" ] && ok "남의 세션 무관여" || no "남의 세션 무관여" "간섭"

echo "── Stop: 미승인이면 전이 금지 ──"
r=$(stop)
[ "$(stage)" = plan ] && ok "plan 유지" || no "plan 유지" "$(stage)"
# 사람 대기 상태라도 지시와 사유는 반드시 전달돼야 한다.
# (양쪽 결과를 다 통과로 처리하면 "지시가 아예 안 나가는" 버그를 놓친다)
CTX="$(printf '%s' "$r" | jq -r '.hookSpecificOutput.additionalContext // .reason // ""')"
[ -n "$CTX" ] && ok "사람 대기여도 내용이 전달됨" || no "지시 전달" "출력이 비어 있음"
printf '%s' "$CTX" | grep -q '승인' && ok "미충족 사유가 구체적" || no "사유 내용" "$CTX"

echo "── ExitPlanMode 승인 관찰 ──"
hook post-tool "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"tool_name\":\"ExitPlanMode\",\"tool_input\":{}}"
[ "$(state '.evidence["plan/계획 수립과 승인"]')" = true ] \
  && ok "plan_approved 기록" || no "plan_approved 기록" "$(state .evidence)"

echo "── Stop: 승인 후 전이 ──"
stop >/dev/null
[ "$(stage)" = implement ] && ok "implement로 전이" || no "전이" "$(stage)"

echo "── implement 단계 forbid ──"
[ -z "$(pre Edit "{\"file_path\":\"$T/app.js\"}")" ] && ok "Edit 허용" || no "Edit 허용" "차단됨"
[ -n "$(pre Bash '{"command":"git push origin main"}')" ] && ok "push 차단" || no "push 차단" "통과됨"

echo "── Stop: implement→verify ──"
# implement 에 완료 대조 게이트가 생겼다 — Stop 만으로는 못 넘어간다
stop >/dev/null                                  # 사람 대기 표시
user_turn >/dev/null
bouncer done "implement/구현 완료 대조" >/dev/null 2>&1
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify로 전이" || no "전이" "$(stage)"

echo "── verify: 검증 보고(blocking) 대기 ──"
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify 유지 (보고 전)" || no "verify 유지" "$(stage)"
user_turn >/dev/null                        # 사람이 실제로 답한 상황
bouncer done "verify/검증 보고" >/dev/null && ok "bouncer done 기록" || no "bouncer done"
stop >/dev/null
[ "$(stage)" = finalize ] && ok "finalize로 전이" || no "전이" "$(stage)"

echo "── finalize: 워킹트리 더러우면 못 넘어감 ──"
echo dirty >> app.js
stop >/dev/null
[ "$(stage)" = finalize ] && ok "더러우면 유지" || no "더러우면 유지" "$(stage)"
git add app.js && git commit -qm fix
stop >/dev/null
[ "$(stage)" = done ] && ok "커밋 후 done 전이" || no "done 전이" "$(stage)"

echo "── done: lock 해제 ──"
stop >/dev/null
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "lock 해제" "남아있음" || ok "lock 해제"
ls "$T"/.ai-bouncer/tasks/*/state.json >/dev/null 2>&1 && ok "state.json 보존" || no "state.json 보존"

finish
