#!/bin/bash
# test-bash-gate.sh — bash-gate 단위 테스트 (session_id 저장 + done 조건)

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"
PASS=0; FAIL=0

check() {
  local label="$1" output="$2" expected="$3"
  local actual
  if [ -z "$output" ]; then
    actual="allow"
  else
    actual=$(echo "$output" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  fi
  if [ "$actual" = "$expected" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (expected=$expected got=$actual)"; echo "   output: $output"; FAIL=$((FAIL+1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# 임시 git repo
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")
mkdir -p "$TMPDIR/.claude/ai-bouncer"
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
mkdir -p "$TASK_DIR/verifications"
touch "$TASK_DIR/.active"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF

run_gate() {
  local cmd="$1" sid="${2:-}"
  (cd "$TMPDIR" && jq -n --arg cmd "$cmd" --arg sid "$sid" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

# TC-01: session_id가 /tmp/.ai-bouncer-current-session에 저장됨
TEST_SID="test-session-12345"
rm -f /tmp/.ai-bouncer-current-session
run_gate "ls" "$TEST_SID" > /dev/null 2>&1 || true
SAVED_SID=$(cat /tmp/.ai-bouncer-current-session 2>/dev/null | tr -d '[:space:]')
if [ "$SAVED_SID" = "$TEST_SID" ]; then
  echo "✅ TC-01: session_id /tmp 저장 확인"; PASS=$((PASS+1))
else
  echo "❌ TC-01: session_id 저장 실패 (expected=$TEST_SID got=$SAVED_SID)"; FAIL=$((FAIL+1))
fi

# TC-02: done 전환 시도 + e2e-result.md 없음 → block
# CMD 패턴: "workflow_phase":"done" 을 state.json에 쓰는 패턴 (bash-gate pattern 1 매칭)
rm -f "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"done"} >> state.json' "")
check "TC-02: done 전환 + no e2e-result.md → block" "$OUT" "block"

# TC-03: done 전환 시도 + e2e-result.md 통과 → allow
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"done"} >> state.json' "")
check "TC-03: done 전환 + e2e-result.md 통과 → allow" "$OUT" "allow"

# TC-04: cancelled 전환은 e2e-result.md 없어도 항상 허용 (planning 상태)
rm -f "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"cancelled"} >> state.json' "")
check "TC-04: cancelled 전환 → always allow (planning)" "$OUT" "allow"

# TC-05: development → cancelled (bash) → block (항상)
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"dev_phases":{}}
EOF
OUT=$(run_gate 'echo {"workflow_phase":"cancelled"} >> state.json' "")
check "TC-05: development → cancelled (bash) → block" "$OUT" "block"

# TC-06: rm .active + workflow_phase=development → block
OUT=$(run_gate "rm -f .ai-bouncer-tasks/2026-01-01/test-task/.active" "")
check "TC-06: rm .active + phase=development → block" "$OUT" "block"
touch "$TASK_DIR/.active"
# state.json 복원 (TC-10+ 테스트용)
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF

# ============================================================
# TC-10~14: IS_DELEGATED_AGENT 경로 + team 모드 team_name 검증
# (delegated subagent도 team_name="" 이면 gate에서 차단)
# ============================================================

# 글로벌 /tmp/.ai-bouncer-approved-agents 백업/복구 — 다른 세션 영향 방지
APPROVED_GLOBAL="/tmp/.ai-bouncer-approved-agents"
ORIG_APPROVED=""
if [ -f "$APPROVED_GLOBAL" ]; then
  ORIG_APPROVED=$(cat "$APPROVED_GLOBAL")
fi
restore_approved() {
  if [ -z "$ORIG_APPROVED" ]; then
    rm -f "$APPROVED_GLOBAL"
  else
    printf '%s\n' "$ORIG_APPROVED" > "$APPROVED_GLOBAL"
  fi
}
trap "rm -rf '$TMPDIR'; restore_approved" EXIT

# delegated 경로 진입을 위해 session_id를 approved-agents에 등록
DELEGATED_SID="delegated-bash-gate-sid-$$"

clear_and_register() {
  : > "$APPROVED_GLOBAL"
  echo "${DELEGATED_SID}|${TASK_DIR}" >> "$APPROVED_GLOBAL"
}

# delegated 경로용 write 명령어 — exception이 아닌 일반 파일에 write
DUMMY_FILE="$TMPDIR/dummy.txt"
touch "$DUMMY_FILE"

run_gate_delegated() {
  (cd "$TMPDIR" && jq -n --arg cmd "echo foo > $DUMMY_FILE" --arg sid "$DELEGATED_SID" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

# plan.md 생성 (gate-checks 우회 — delegated 경로에서는 사용되지 않지만 안전)
mkdir -p "$TASK_DIR/phase-1-test"
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
delegated team_name validation
EOF

# TC-10: IS_DELEGATED_AGENT=true + development + team mode + top-level team_name="" → block
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-10: delegated + dev + team + team_name='' → block" "$OUT" "block"

# TC-11: IS_DELEGATED_AGENT=true + development + team mode + team_name="my-team" → allow
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"my-team","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-11: delegated + dev + team + team_name='my-team' → allow" "$OUT" "allow"

# TC-12: IS_DELEGATED_AGENT=true + development + team mode + dev_phase=2 + per-phase team_name="" → block
mkdir -p "$TASK_DIR/phase-2-second"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"first","folder":"phase-1-test","team_name":"team-1"},"2":{"name":"second","folder":"phase-2-second","team_name":""}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-12: delegated + dev_phase=2 + per-phase team_name='' → block" "$OUT" "block"

# TC-13: IS_DELEGATED_AGENT=true + development + subagent mode + team_name="" → allow
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"subagent","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-13: delegated + dev + subagent mode + team_name='' → allow" "$OUT" "allow"

# TC-14: IS_DELEGATED_AGENT=true + planning phase → allow (검증은 development에서만)
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"team_name":"","dev_phases":{}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-14: delegated + planning + team_name='' → allow" "$OUT" "allow"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
