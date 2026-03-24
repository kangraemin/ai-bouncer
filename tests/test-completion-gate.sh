#!/usr/bin/env bash
# E2E tests for completion-gate.sh hook behavior (artifact-based)
# Usage: bash tests/test-completion-gate.sh

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; echo "       → $2"; ((FAIL_COUNT++)) || true; }

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 실제 설치 (suite 1회) — 설치된 경로의 hook 사용
INSTALL_REPO=$(mktemp -d)
git init "$INSTALL_REPO" -q
git -C "$INSTALL_REPO" -c user.email=test@test.com -c user.name=Test commit --allow-empty -m "init" -q 2>/dev/null
(cd "$INSTALL_REPO" && bash "$SRC_DIR/install.sh" --ci 2>/dev/null)
HOOK_SCRIPT="$INSTALL_REPO/.claude/hooks/completion-gate.sh"

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT" "$INSTALL_REPO"; }
trap cleanup EXIT

setup_env() {
  local dir="$1"
  local task_name="$2"
  local workflow_phase="${3:-verification}"
  local plan_approved="${4:-true}"

  mkdir -p "$dir/.ai-bouncer-tasks/${task_name}"
  touch "$dir/.ai-bouncer-tasks/${task_name}/.active"

  python3 - "$dir" "$task_name" "$workflow_phase" "$plan_approved" <<'PYEOF'
import json, sys
d, task, phase, approved = sys.argv[1:]
state = {
    'workflow_phase': phase,
    'plan_approved': approved == 'true',
    'team_name': 'test-team',
    'current_dev_phase': 1,
    'current_step': 1,
    'dev_phases': {},
    'verification': {'rounds_passed': 0}
}
with open(f'{d}/.ai-bouncer-tasks/{task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

create_round() {
  local dir="$1"
  local task="$2"
  local round_num="$3"
  local content="$4"
  mkdir -p "$dir/.ai-bouncer-tasks/${task}/verifications"
  echo "$content" > "$dir/.ai-bouncer-tasks/${task}/verifications/round-${round_num}.md"
}

run_hook() {
  local dir="$1"
  (cd "$dir" && bash "$HOOK_SCRIPT" 2>/dev/null)
}

assert_allow() {
  local label="$1" out="$2"
  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)
  if [ "$decision" != "block" ]; then
    pass "$label"
  else
    local reason; reason=$(echo "$out" | jq -r '.reason // ""' 2>/dev/null)
    fail "$label" "got block: $reason"
  fi
}

assert_block() {
  local label="$1" out="$2"
  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)
  if [ "$decision" = "block" ]; then
    pass "$label"
  else
    fail "$label" "expected block, got allow"
  fi
}

# ---------------------------------------------------------------------------
# TC-C1: verification + round 파일 없음 → BLOCK
# ---------------------------------------------------------------------------
tc_c1() {
  local dir="$TMPDIR_ROOT/tc_c1"
  setup_env "$dir" "my-task" "verification" "true"
  local out; out=$(run_hook "$dir")
  assert_block "TC-C1: verification + round 파일 없음 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-C2: verification + round-1,2,3 모두 "통과" → ALLOW
# ---------------------------------------------------------------------------
tc_c2() {
  local dir="$TMPDIR_ROOT/tc_c2"
  setup_env "$dir" "my-task" "verification" "true"
  create_round "$dir" "my-task" 1 "# Round 1\n검증 통과\n\n## 결론\n통과"
  create_round "$dir" "my-task" 2 "# Round 2\n검증 통과\n\n## 결론\n통과"
  create_round "$dir" "my-task" 3 "# Round 3\n검증 통과\n\n## 결론\n통과"
  local out; out=$(run_hook "$dir")
  assert_allow "TC-C2: verification + 3 rounds 통과 → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-C3: verification + round-2 "실패" 포함 → BLOCK
# ---------------------------------------------------------------------------
tc_c3() {
  local dir="$TMPDIR_ROOT/tc_c3"
  setup_env "$dir" "my-task" "verification" "true"
  create_round "$dir" "my-task" 1 "# Round 1\n검증 통과\n\n## 결론\n통과"
  create_round "$dir" "my-task" 2 "# Round 2\n검증 실패 — Step 1 오류\n\n## 결론\n실패"
  create_round "$dir" "my-task" 3 "# Round 3\n검증 통과\n\n## 결론\n통과"
  local out; out=$(run_hook "$dir")
  assert_block "TC-C3: verification + round-2 실패 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-C4: verification + round 파일 2개만 → BLOCK
# ---------------------------------------------------------------------------
tc_c4() {
  local dir="$TMPDIR_ROOT/tc_c4"
  setup_env "$dir" "my-task" "verification" "true"
  create_round "$dir" "my-task" 1 "# Round 1\n검증 통과\n\n## 결론\n통과"
  create_round "$dir" "my-task" 2 "# Round 2\n검증 통과\n\n## 결론\n통과"
  local out; out=$(run_hook "$dir")
  assert_block "TC-C4: verification + round 2개만 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-C5: non-verification phase → ALLOW
# ---------------------------------------------------------------------------
tc_c5() {
  local dir="$TMPDIR_ROOT/tc_c5"
  setup_env "$dir" "my-task" "development" "true"
  local out; out=$(run_hook "$dir")
  assert_allow "TC-C5: non-verification phase → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-C6: normal + development + 미완료 phase → BLOCK
# ---------------------------------------------------------------------------
tc_c6() {
  local dir="$TMPDIR_ROOT/tc_c6"
  setup_env "$dir" "my-task" "development" "true"
  python3 -c "
import json
f = '$dir/.ai-bouncer-tasks/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['current_dev_phase'] = 2
s['dev_phases'] = {'1': {'name': 'p1', 'folder': 'phase-1', 'steps': 1}, '2': {'name': 'p2', 'folder': 'phase-2', 'steps': 1}}
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local out; out=$(run_hook "$dir")
  assert_block "TC-C6: normal + development + 미완료 phase → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-C7: normal + development + 완료된 phase → ALLOW
# ---------------------------------------------------------------------------
tc_c7() {
  local dir="$TMPDIR_ROOT/tc_c7"
  setup_env "$dir" "my-task" "development" "true"
  python3 -c "
import json
f = '$dir/.ai-bouncer-tasks/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['current_dev_phase'] = 3
s['dev_phases'] = {'1': {'name': 'p1', 'folder': 'phase-1', 'steps': 1}, '2': {'name': 'p2', 'folder': 'phase-2', 'steps': 1}}
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local out; out=$(run_hook "$dir")
  assert_allow "TC-C7: normal + development + 완료된 phase → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# SIMPLE 모드 테스트
# ---------------------------------------------------------------------------

# TC-CS1: simple + plan_approved + non-done → BLOCK (Phase S3 강제)
tc_cs1() {
  local dir="$TMPDIR_ROOT/tc_cs1"
  setup_env "$dir" "my-task" "verification" "true"
  python3 -c "
import json
f = '$dir/.ai-bouncer-tasks/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['mode'] = 'simple'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local out; out=$(run_hook "$dir")
  assert_block "TC-CS1: simple + plan_approved + non-done → BLOCK" "$out"
}

# TC-CS2: normal + verification + round 없음 → BLOCK (기존 동작 유지)
tc_cs2() {
  local dir="$TMPDIR_ROOT/tc_cs2"
  setup_env "$dir" "my-task" "verification" "true"
  local out; out=$(run_hook "$dir")
  assert_block "TC-CS2: normal + verification + round 없음 → BLOCK" "$out"
}

# TC-CS3: simple + plan_approved=false → ALLOW (계획 미승인 차단 없음)
tc_cs3() {
  local dir="$TMPDIR_ROOT/tc_cs3"
  setup_env "$dir" "my-task" "development" "false"
  python3 -c "
import json
f = '$dir/.ai-bouncer-tasks/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['mode'] = 'simple'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local out; out=$(run_hook "$dir")
  assert_allow "TC-CS3: simple + plan_approved=false → ALLOW" "$out"
}

# TC-CS4: simple + done → ALLOW
tc_cs4() {
  local dir="$TMPDIR_ROOT/tc_cs4"
  setup_env "$dir" "my-task" "done" "true"
  python3 -c "
import json
f = '$dir/.ai-bouncer-tasks/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['mode'] = 'simple'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local out; out=$(run_hook "$dir")
  assert_allow "TC-CS4: simple + done → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== completion-gate.sh E2E Tests (Artifact-based) ===${NC}"
echo ""

tc_c1; tc_c2; tc_c3; tc_c4; tc_c5; tc_c6; tc_c7
tc_cs1; tc_cs2; tc_cs3; tc_cs4

echo ""
echo "---"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✅ $PASS_COUNT/$TOTAL passed${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAIL_COUNT/$TOTAL failed${NC}"
  exit 1
fi
