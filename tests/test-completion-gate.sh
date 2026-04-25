#!/bin/bash
# test-completion-gate.sh — e2e-result.md 기반 completion-gate 단위 테스트

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

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
mkdir -p "$TASK_DIR/verifications"
touch "$TASK_DIR/.active"

write_state() {
  cat > "$TASK_DIR/state.json" <<EOF
{"workflow_phase":"$1","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
}

run_gate() {
  (cd "$TMPDIR" && echo '{"session_id":"","stop_hook_active":false}' | bash "$HOOKS_DIR/completion-gate.sh" 2>/dev/null) || true
}

# TC-01: verification + e2e-result.md 없음 → block
write_state "verification"
check "TC-01: verification + no e2e-result.md → block" "$(run_gate)" "block"

# TC-02: verification + e2e-result.md 실패 → block
printf "## 결론\n실패\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-02: verification + e2e-result.md 실패 → block" "$(run_gate)" "block"

# TC-03: verification + e2e-result.md 통과 → allow
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-03: verification + e2e-result.md 통과 → allow" "$(run_gate)" "allow"

# TC-04: done phase → allow (gate 비활성)
write_state "done"
rm -f "$TASK_DIR/verifications/e2e-result.md"
check "TC-04: done phase → allow" "$(run_gate)" "allow"

# TC-05: planning phase → allow
write_state "planning"
check "TC-05: planning phase → allow" "$(run_gate)" "allow"

# TC-06: development + dev_phases 비어있음 → allow (completion-gate는 ✅ 체크만)
write_state "development"
check "TC-06: development + dev_phases={} → allow" "$(run_gate)" "allow"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
