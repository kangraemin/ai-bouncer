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

echo "── plan 단계 보호 ──"
# 수정 차단은 Claude Code plan mode 가 한다 — 엔진은 상태 파일만 지킨다
[ -n "$(pre Write "{\"file_path\":\"$T/.ai-bouncer/tasks/x/state.json\"}")" ] && ok "state.json 보호" || no "state.json 보호" "통과됨"
[ -z "$(pre Edit "{\"file_path\":\"$T/app.js\"}" OTHER)" ] && ok "남의 세션 무관여" || no "남의 세션 무관여" "간섭"

echo "── ExitPlanMode 승인 관찰 ──"
PLAN='## 계획
- 결제 모듈 수정
- 테스트 추가

| 바꾸는 대상 | 참조처(파일:줄) | 영향 | 조치 |
|---|---|---|---|
| pay() | api.ts:12 | 시그니처 변경 | 호출부 수정 |'
hook post-tool "$(jq -nc --arg c "$T" --arg p "$PLAN" \
  '{session_id:"S1",cwd:$c,tool_name:"ExitPlanMode",tool_input:{plan:$p}}')"
[ "$(state '.checklist | length')" = 2 ] \
  && ok "승인된 계획이 체크리스트가 된다" || no "계획 이관 실패" "$(state -c .checklist)"
[ "$(state '[.checklist[].text | select(contains("|"))] | length')" = 0 ] \
  && ok "영향 범위 표 행은 체크리스트에 안 들어간다" || no "표 행 유입" "$(state -c .checklist)"
[ "$(state '.checklist[0].text')" = "결제 모듈 수정" ] \
  && ok "항목 텍스트가 그대로 온다" || no "텍스트 어긋남" "$(state '.checklist[0].text')"

echo "── Stop: plan → implement (plan 은 지시만, 게이트 없음) ──"
stop >/dev/null
[ "$(stage)" = implement ] && ok "implement로 전이" || no "전이" "$(stage)"

echo "── implement 단계 forbid ──"
[ -z "$(pre Edit "{\"file_path\":\"$T/app.js\"}")" ] && ok "Edit 허용" || no "Edit 허용" "차단됨"
[ -n "$(pre Bash '{"command":"git push origin main"}')" ] && ok "push 차단" || no "push 차단" "통과됨"

echo "── Stop: implement→verify ──"
# implement 에 완료 대조 게이트가 생겼다 — Stop 만으로는 못 넘어간다
stop >/dev/null                                  # 사람 대기 표시
bouncer done "implement/구현 완료 대조" >/dev/null 2>&1
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify로 전이" || no "전이" "$(stage)"

echo "── verify: 검증 보고는 지시만 (자기신고 없음) ──"
says "blocking이 아니다" bouncer done "verify/검증 보고" && ok "done 표시할 조건이 없다" || no "자기신고 남음"
stop >/dev/null
[ "$(stage)" = finalize ] && ok "finalize로 전이" || no "전이" "$(stage)"

echo "── finalize: 무관한 WIP가 남아 있어도 막지 않는다 ──"
echo dirty >> app.js
stop >/dev/null
[ "$(stage)" = done ] && ok "WIP 있어도 done 전이" || no "done 전이" "$(stage)"

echo "── done: 진입과 동시에 lock 해제(추가 Stop 불필요) ──"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "lock 해제" "남아있음" || ok "lock 해제"
ls "$T"/.ai-bouncer/tasks/*/state.json >/dev/null 2>&1 && ok "state.json 보존" || no "state.json 보존"

finish
