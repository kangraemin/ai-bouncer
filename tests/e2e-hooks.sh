#!/bin/bash
# E2E Hook 테스트 스크립트
# 사용법: bash tests/e2e-hooks.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0
HOOKS_DIR="hooks"

# 테스트 환경 설정
TASK_DIR="docs/2026-03-08/e2e-hook-hardening"
STATE_FILE="$TASK_DIR/state.json"
ACTIVE_FILE="$TASK_DIR/.active"
TEST_SID="e2e-test-session-$(date +%s)"

setup() {
  # state.json을 원하는 상태로 설정
  local mode="${1:-simple}" phase="${2:-development}" approved="${3:-true}"
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['mode'] = '$mode'
s['workflow_phase'] = '$phase'
s['plan_approved'] = ('$approved' == 'true')
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
  echo "$TEST_SID" > "$ACTIVE_FILE"
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot
}

# 헬퍼: hook 실행 후 차단 여부 확인
run_hook() {
  local hook="$1" input="$2"
  echo "$input" | bash "$HOOKS_DIR/$hook" 2>/dev/null || true
}

assert_pass() {
  local desc="$1" result="$2"
  if [ -z "$result" ] || ! echo "$result" | grep -q '"block"'; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — 차단됨: $(echo "$result" | jq -r '.reason' 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
}

assert_block() {
  local desc="$1" result="$2"
  if echo "$result" | grep -q '"block"' 2>/dev/null; then
    echo "  ✅ $desc (차단됨)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — 차단되지 않음"
    FAIL=$((FAIL + 1))
  fi
}

echo "═══════════════════════════════════════════"
echo "  ai-bouncer E2E Hook Tests"
echo "═══════════════════════════════════════════"
echo ""

# ─── 1. plan-gate 테스트 ───────────────────
echo "─── plan-gate.sh ───"

setup "simple" "development" "true"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE + development + approved → 통과" "$R"

setup "simple" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SIMPLE + planning → 차단" "$R"

setup "simple" "development" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SIMPLE + development + 미승인 → 차단" "$R"

# plan.md 경로는 항상 허용
setup "simple" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/plan.md\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan.md 경로 → 항상 통과" "$R"

# ~/.claude/plans/ 경로
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HOME/.claude/plans/test.md\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "~/.claude/plans/ → 항상 통과" "$R"

# 위임 에이전트
setup "simple" "development" "true"
echo "${TEST_SID}-sub|$(pwd)/$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "위임 에이전트 → 부모 task 기준 통과" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 2. bash-gate 테스트 ──────────────────
echo "─── bash-gate.sh ───"

setup "simple" "development" "true"

# fd redirect 오탐
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls foo 2>/dev/null\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "2>/dev/null → 오탐 아님" "$R"

R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat file 2>&1\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "2>&1 → 오탐 아님" "$R"

R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cmd 1>/dev/null 2>/dev/null\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "1>/dev/null 2>/dev/null → 오탐 아님" "$R"

# 진짜 쓰기는 development에서 통과 (gate 조건 충족)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "echo > file.txt (development) → 통과" "$R"

# planning에서 쓰기는 차단
setup "simple" "planning" "false"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "echo > file.txt (planning) → 차단" "$R"

# git 명령어는 항상 통과
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "git add → 항상 통과" "$R"

# state.json 예외
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"python3 -c 'import json; ...' state.json\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "state.json 수정 → 예외 통과" "$R"

# rm state.json은 예외 아님
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm state.json\"},\"session_id\":\"$TEST_SID\"}")
assert_block "rm state.json (planning) → 차단" "$R"

# python 오탐 (python_version 같은 변수)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo python_version\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "echo python_version → 오탐 아님" "$R"

echo ""

# ─── 3. subagent-track/cleanup 테스트 ─────
echo "─── subagent-track/cleanup ───"

setup "simple" "development" "true"

# SubagentStart
R=$(echo "{\"session_id\":\"sub-001\",\"agent_id\":\"agent-1\"}" | bash hooks/subagent-track.sh 2>/dev/null)
if [ -f /tmp/.ai-bouncer-approved-agents ] && grep -q "sub-001" /tmp/.ai-bouncer-approved-agents; then
  echo "  ✅ SubagentStart: sub-001 등록됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ SubagentStart: sub-001 등록 안 됨"
  FAIL=$((FAIL + 1))
fi

# SubagentStop
echo "{\"session_id\":\"sub-001\"}" | bash hooks/subagent-cleanup.sh 2>/dev/null
if [ ! -f /tmp/.ai-bouncer-approved-agents ] || ! grep -q "sub-001" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo "  ✅ SubagentStop: sub-001 제거됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ SubagentStop: sub-001 제거 안 됨"
  FAIL=$((FAIL + 1))
fi

# planning 상태에서는 등록 안 됨
setup "simple" "planning" "false"
echo "{\"session_id\":\"sub-002\"}" | bash hooks/subagent-track.sh 2>/dev/null
if ! grep -q "sub-002" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo "  ✅ planning 상태 → 등록 안 됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ planning 상태인데 등록됨"
  FAIL=$((FAIL + 1))
fi

echo ""

# ─── 4. completion-gate 테스트 ────────────
echo "─── completion-gate.sh ───"

setup "simple" "development" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE 모드 → completion-gate 스킵" "$R"

setup "normal" "verification" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "NORMAL + verification + round 없음 → 차단" "$R"

echo "${TEST_SID}-sub|$(pwd)/$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook completion-gate.sh "{\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "위임 에이전트 → completion-gate 스킵" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 5. bash-audit 테스트 ─────────────────
echo "─── bash-audit.sh ───"

# 스냅샷 없으면 스킵
rm -f /tmp/.ai-bouncer-snapshot
R=$(run_hook bash-audit.sh "{\"tool_name\":\"Bash\",\"session_id\":\"$TEST_SID\"}")
assert_pass "스냅샷 없음 → audit 스킵" "$R"

# 승인된 에이전트는 스킵
touch /tmp/.ai-bouncer-snapshot
echo "${TEST_SID}-sub|$(pwd)/$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook bash-audit.sh "{\"tool_name\":\"Bash\",\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "승인된 에이전트 → audit 스킵" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 6. 예외 경로 테스트 ─────────────────
echo "─── 예외 경로 ───"

setup "simple" "planning" "false"

# tests.md
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > tests.md << EOF\\ntest\\nEOF\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "tests.md Bash 쓰기 → 예외 통과" "$R"

# .active 파일 삭제
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -f docs/2026-03-08/e2e-hook-hardening/.active\"},\"session_id\":\"$TEST_SID\"}")
assert_pass ".active 삭제 → 예외 통과" "$R"

echo ""

# ─── 정리 ─────────────────────────────────
setup "simple" "development" "true"
rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot

echo "═══════════════════════════════════════════"
echo "  결과: ✅ $PASS 통과 / ❌ $FAIL 실패"
echo "═══════════════════════════════════════════"

exit $FAIL
