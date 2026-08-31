#!/usr/bin/env bash
# 케이스 1 — plan 워크플로우 전 구간 (plan → implement → verify → finalize → done)
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"

git init -q . && git config user.email t@t && git config user.name t
echo hello > app.js && git add app.js && git commit -qm init

# 실제 설치와 동일하게: 런타임 상태는 gitignore, 설정은 커밋
printf '.ai-bouncer/\n' > .gitignore
mkdir -p .claude/ai-bouncer/prompts
cp "$R/config/default.yaml" .claude/ai-bouncer/workflow.yaml
cp "$R/config/prompts/plan.md" .claude/ai-bouncer/prompts/plan.md
echo '{"max_continue":3}' > .claude/ai-bouncer/config.json
printf 'workflow.compiled.json\n' > .claude/ai-bouncer/.gitignore
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json || exit 1
git add .gitignore .claude && git commit -qm "chore: ai-bouncer 설정 추가"

export CLAUDE_CODE_SESSION_ID=SESS1
bouncer() { bash "$R/engine/bouncer.sh" "$@"; }
hook() { local h="$1"; shift; printf '%s' "$1" | bash "$R/hooks/$h.sh"; }
state() { jq -r "$1" "$T"/.ai-bouncer/tasks/*/state.json 2>/dev/null; }
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

echo "── 모드 목록 ──"; bouncer workflows | sed 's/^/  /'

echo "── 작업 시작 ──"
START_OUT="$(bouncer start plan "결제 버그")"
printf '%s\n' "$START_OUT" | head -2 | sed 's/^/  /'
printf '%s' "$START_OUT" | grep -q 'EnterPlanMode' && ok "start가 첫 스테이지 지시를 즉시 전달" || no "첫 지시 전달" "start 출력에 없음"
[ "$(state .current_stage)" = plan ] && ok "current_stage=plan" || no "시작" "$(state .current_stage)"

echo "── plan 단계 forbid ──"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T/app.js\"}}")
[ -n "$r" ] && ok "Edit 차단" || no "Edit 차단" "통과됨"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > app.js\"}}")
[ -n "$r" ] && ok "bash 리다이렉트 차단" || no "bash 우회 차단" "통과됨"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i '' s/a/b/ app.js\"}}")
[ -n "$r" ] && ok "sed -i 차단" || no "sed -i 차단" "통과됨"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$T/.ai-bouncer/tasks/x/state.json\"}}")
[ -n "$r" ] && ok "state.json 보호" || no "state.json 보호" "통과됨"
r=$(hook pre-tool "{\"session_id\":\"OTHER\",\"cwd\":\"$T\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T/app.js\"}}")
[ -z "$r" ] && ok "남의 세션 무관여" || no "남의 세션 무관여" "간섭"

echo "── Stop: 미승인이면 전이 금지 ──"
r=$(hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}")
[ "$(state .current_stage)" = plan ] && ok "plan 유지" || no "plan 유지" "$(state .current_stage)"
# 사람 대기 상태라도 지시와 사유는 반드시 전달돼야 한다.
# (양쪽 결과를 다 통과로 처리하면 "지시가 아예 안 나가는" 버그를 놓친다)
CTX="$(printf '%s' "$r" | jq -r '.hookSpecificOutput.additionalContext // .reason // ""')"
[ -n "$CTX" ] && ok "사람 대기여도 내용이 전달됨" || no "지시 전달" "출력이 비어 있음"
printf '%s' "$CTX" | grep -q '승인' && ok "미충족 사유가 구체적" || no "사유 내용" "$CTX"

echo "── ExitPlanMode 승인 관찰 ──"
hook post-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"ExitPlanMode\",\"tool_input\":{}}"
[ "$(state '.evidence["plan/계획 수립과 승인"]')" = true ] && ok "plan_approved 기록" || no "plan_approved 기록" "$(state .evidence)"

echo "── Stop: 승인 후 전이 ──"
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = implement ] && ok "implement로 전이" || no "전이" "$(state .current_stage)"

echo "── implement 단계 forbid ──"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T/app.js\"}}")
[ -z "$r" ] && ok "Edit 허용" || no "Edit 허용" "차단됨"
r=$(hook pre-tool "{\"session_id\":\"SESS1\",\"cwd\":\"$T\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"}}")
[ -n "$r" ] && ok "push 차단" || no "push 차단" "통과됨"

echo "── Stop: implement→verify ──"
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = verify ] && ok "verify로 전이" || no "전이" "$(state .current_stage)"

echo "── verify: 검증 보고(blocking) 대기 ──"
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = verify ] && ok "verify 유지 (보고 전)" || no "verify 유지" "$(state .current_stage)"
bouncer done "verify/검증 보고" >/dev/null && ok "bouncer done 기록" || no "bouncer done"
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = finalize ] && ok "finalize로 전이" || no "전이" "$(state .current_stage)"

echo "── finalize: 워킹트리 더러우면 못 넘어감 ──"
echo dirty >> app.js
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = finalize ] && ok "더러우면 유지" || no "더러우면 유지" "$(state .current_stage)"
git add app.js && git commit -qm fix
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(state .current_stage)" = done ] && ok "커밋 후 done 전이" || no "done 전이" "$(state .current_stage)"

echo "── done: lock 해제 ──"
hook stop "{\"session_id\":\"SESS1\",\"cwd\":\"$T\"}" >/dev/null
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "lock 해제" "남아있음" || ok "lock 해제"
ls "$T"/.ai-bouncer/tasks/*/state.json >/dev/null 2>&1 && ok "state.json 보존" || no "state.json 보존"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
