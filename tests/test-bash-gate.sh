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

# TC-04: cancelled 전환은 e2e-result.md 없어도 항상 허용
rm -f "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"cancelled"} >> state.json' "")
check "TC-04: cancelled 전환 → always allow" "$OUT" "allow"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
