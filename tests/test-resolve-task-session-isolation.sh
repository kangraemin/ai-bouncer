#!/bin/bash
# test-resolve-task-session-isolation.sh — 빈/타-SESSION_ID cross-session hijack 방지 검증
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RT="$REPO/hooks/lib/resolve-task.sh"
HOOKS="$REPO/hooks"
PASS=0; FAIL=0
ok(){ echo "✅ $1"; PASS=$((PASS+1)); }
ng(){ echo "❌ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
OWNER="ownerA-$$"
TD="$TMP/.ai-bouncer-tasks/2026-06-01/task-X"; mkdir -p "$TD"
printf '%s' "$OWNER" > "$TD/.active"
cat > "$TD/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{}}
EOF
trap 'rm -rf "$TMP"' EXIT

resolve(){ SESSION_ID="$1" bash -c 'cd "'"$TMP"'"; source "'"$RT"'"; echo "MY=$IS_MY_TASK NAME=$TASK_NAME"'; }
decision(){ echo "$1" | jq -r '.decision // "allow"' 2>/dev/null || echo allow; }

# TC-1 (negative): 빈 SESSION_ID → owner 인정 안 함
O1=$(resolve "")
echo "$O1" | grep -q "MY=true" && ng "TC-1: 빈 세션이 owner로 인정됨(취약) ($O1)" || ok "TC-1: 빈 세션 owner 거부"
echo "$O1" | grep -qE "NAME=$" && ok "TC-1: TASK_NAME 빈값" || ng "TC-1: TASK_NAME 비어있지 않음 ($O1)"

# TC-2 (negative): 다른 session_id → owner 아님
O2=$(resolve "other-$$")
echo "$O2" | grep -q "MY=true" && ng "TC-2: 다른 세션이 owner로 인정됨 ($O2)" || ok "TC-2: 다른 세션 owner 거부"

# TC-3 (regression): 자기 session_id → owner 정상
O3=$(resolve "$OWNER")
echo "$O3" | grep -q "MY=true" && ok "TC-3: 자기 세션 owner 인정" || ng "TC-3(회귀): 자기 세션 owner 거부됨 ($O3)"
echo "$O3" | grep -q "NAME=task-X" && ok "TC-3: TASK_NAME=task-X" || ng "TC-3: TASK_NAME 틀림 ($O3)"

# TC-4 (e2e): bash-gate 빈 세션 + 쓰기 → block
BG1=$(cd "$TMP" && jq -n '{tool_name:"Bash",session_id:"",tool_input:{command:"echo hi > realfile.sh"}}' | bash "$HOOKS/bash-gate.sh" 2>/dev/null)
[ "$(decision "$BG1")" = "block" ] && ok "TC-4: bash-gate 빈 세션 쓰기 차단" || ng "TC-4: 차단 안 됨 ($BG1)"

# TC-5 (regression): bash-gate 유효 세션(미점유) + 쓰기 → allow (가드 미발동)
BG2=$(cd "$TMP" && jq -n --arg sid "valid-$$" '{tool_name:"Bash",session_id:$sid,tool_input:{command:"echo hi > realfile.sh"}}' | bash "$HOOKS/bash-gate.sh" 2>/dev/null)
[ "$(decision "$BG2")" = "block" ] && ng "TC-5(회귀): 유효 세션이 차단됨 ($BG2)" || ok "TC-5: 유효 세션 쓰기 통과"

# TC-6 (e2e): plan-gate 빈 세션 + 非plan 파일 Write → block
PG1=$(cd "$TMP" && jq -n --arg fp "$TMP/foo.sh" '{tool_name:"Write",session_id:"",tool_input:{file_path:$fp,content:"x"}}' | bash "$HOOKS/plan-gate.sh" 2>/dev/null)
[ "$(decision "$PG1")" = "block" ] && ok "TC-6: plan-gate 빈 세션 차단" || ng "TC-6: 차단 안 됨 ($PG1)"

# TC-7 (regression): plan-gate 빈 세션이라도 ~/.claude/plans/ 쓰기는 통과 (CHECK 0 우선)
PG2=$(cd "$TMP" && jq -n --arg fp "$HOME/.claude/plans/x.md" '{tool_name:"Write",session_id:"",tool_input:{file_path:$fp,content:"x"}}' | bash "$HOOKS/plan-gate.sh" 2>/dev/null)
[ "$(decision "$PG2")" = "block" ] && ng "TC-7(회귀): plan 파일이 차단됨 ($PG2)" || ok "TC-7: plan 파일 쓰기 통과"

echo ""; echo "결과: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
