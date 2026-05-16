#!/bin/bash
# test-block-logger.sh — ai-bouncer 차단 이벤트 logger e2e 테스트
# HOME을 임시 디렉토리로 격리해 실제 사용자 로그 오염 없이 검증한다.

set -euo pipefail
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"

PASS=0
FAIL=0
record() {
  if [ "$1" = "PASS" ]; then
    PASS=$((PASS+1)); echo "✅ $2"
  else
    FAIL=$((FAIL+1)); echo "❌ $2"
  fi
}

# bash-gate가 자기 검사로 막지 않도록 입력 명령은 base64로 인코딩해 전달한다.
# (echo "...command..."이 hook의 stdin에 보이지 않게 하기 위함)
make_payload() {
  local cmd_b64="$1"
  local tool="${2:-Bash}"
  local extra="${3:-}"
  python3 -c "
import json, sys, base64
cmd = base64.b64decode(sys.argv[1]).decode()
tool = sys.argv[2]
extra = sys.argv[3] if len(sys.argv) > 3 else ''
inp = {'tool_name': tool, 'tool_input': {'command': cmd}, 'session_id': 't'}
if extra:
    inp['tool_input'] = json.loads(extra)
print(json.dumps(inp))
" "$cmd_b64" "$tool" "$extra"
}

# === TC-1: bash-gate가 차단할 때 JSONL 한 줄 기록 ===
TMPHOME=$(mktemp -d)
PAYLOAD_F=$(mktemp)
CMD_B64=$(printf '%s' 'bash .ai-bouncer-tasks/foo/x.sh' | base64)
make_payload "$CMD_B64" Bash > "$PAYLOAD_F"
HOME="$TMPHOME" bash "$HOOKS_DIR/bash-gate.sh" < "$PAYLOAD_F" > /dev/null
LOG="$TMPHOME/.claude/ai-bouncer-blocks.log"
LINES=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
CODE=$(jq -r '.code' < "$LOG" 2>/dev/null)
HOOK=$(jq -r '.hook' < "$LOG" 2>/dev/null)
if [ "$LINES" = "1" ] && [ "$CODE" = "BG-INTERNAL-SCRIPT" ] && [ "$HOOK" = "bash-gate" ]; then
  record PASS "TC-1: bash-gate block → 1 JSONL line with code=BG-INTERNAL-SCRIPT"
else
  record FAIL "TC-1: lines=$LINES code=$CODE hook=$HOOK"
fi
rm -f "$PAYLOAD_F"
rm -rf "$TMPHOME"

# === TC-2: bash-gate가 통과시키는 명령에선 로그 미생성 ===
TMPHOME=$(mktemp -d)
PAYLOAD_F=$(mktemp)
CMD_B64=$(printf '%s' 'ls -la' | base64)
make_payload "$CMD_B64" Bash > "$PAYLOAD_F"
HOME="$TMPHOME" bash "$HOOKS_DIR/bash-gate.sh" < "$PAYLOAD_F" > /dev/null
LOG="$TMPHOME/.claude/ai-bouncer-blocks.log"
if [ ! -f "$LOG" ]; then
  record PASS "TC-2: bash-gate pass → no log file created"
else
  LINES=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ "$LINES" = "0" ]; then
    record PASS "TC-2: bash-gate pass → no log lines"
  else
    record FAIL "TC-2: bash-gate pass left log lines=$LINES"
  fi
fi
rm -f "$PAYLOAD_F"
rm -rf "$TMPHOME"

# === TC-3: plan-gate가 차단할 때 PG-* code로 기록 ===
TMPHOME=$(mktemp -d)
PAYLOAD_F=$(mktemp)
TASK_ROOT=".ai-bouncer-tasks/2026-05-16/test-pg"
mkdir -p "$TASK_ROOT"
echo "t" > "$TASK_ROOT/.active"
cat > "$TASK_ROOT/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false}
EOF
python3 -c "
import json, os
d = {
  'tool_name': 'Write',
  'tool_input': {'file_path': os.getcwd() + '/.ai-bouncer-tasks/2026-05-16/test-pg/phase-1-x/phase.md', 'content': 't'},
  'session_id': 't'
}
print(json.dumps(d))
" > "$PAYLOAD_F"
HOME="$TMPHOME" bash "$HOOKS_DIR/plan-gate.sh" < "$PAYLOAD_F" > /dev/null
LOG="$TMPHOME/.claude/ai-bouncer-blocks.log"
LINES=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
CODE=$(jq -r '.code' < "$LOG" 2>/dev/null)
HOOK=$(jq -r '.hook' < "$LOG" 2>/dev/null)
if [ "$LINES" = "1" ] && [[ "$CODE" == PG-* ]] && [ "$HOOK" = "plan-gate" ]; then
  record PASS "TC-3: plan-gate block → 1 JSONL line with code=$CODE"
else
  record FAIL "TC-3: lines=$LINES code=$CODE hook=$HOOK"
fi
rm -rf "$TASK_ROOT" "$PAYLOAD_F" "$TMPHOME"

# === TC-4: JSONL의 필수 필드 모두 존재 ===
TMPHOME=$(mktemp -d)
PAYLOAD_F=$(mktemp)
CMD_B64=$(printf '%s' 'bash .ai-bouncer-tasks/foo/x.sh' | base64)
make_payload "$CMD_B64" Bash > "$PAYLOAD_F"
HOME="$TMPHOME" bash "$HOOKS_DIR/bash-gate.sh" < "$PAYLOAD_F" > /dev/null
LOG="$TMPHOME/.claude/ai-bouncer-blocks.log"
TS=$(jq -r '.ts' < "$LOG" 2>/dev/null)
PROJ=$(jq -r '.project' < "$LOG" 2>/dev/null)
REASON=$(jq -r '.reason' < "$LOG" 2>/dev/null)
if [ -n "$TS" ] && [ "$TS" != "null" ] && [ -n "$PROJ" ] && [ -n "$REASON" ]; then
  record PASS "TC-4: JSONL has ts/project/reason fields populated"
else
  record FAIL "TC-4: ts=$TS proj=$PROJ reason=$REASON"
fi
rm -f "$PAYLOAD_F"
rm -rf "$TMPHOME"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "ALL TESTS PASSED"
