#!/usr/bin/env bash
# E2E tests for bash-gate.sh hook behavior (Layer 1)
# Usage: bash tests/test-bash-gate.sh

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; echo "       → $2"; ((FAIL_COUNT++)) || true; }

HOOK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/bash-gate.sh"

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; rm -f /tmp/.ai-bouncer-snapshot; }
trap cleanup EXIT

make_input() {
  local cmd="${1:-ls}"
  jq -n --arg cmd "$cmd" \
    '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# setup_env DIR TASK PHASE PLAN_APPROVED TEAM_NAME CREATE_STEP FILL_TC
setup_env() {
  local dir="$1"
  local task_name="$2"
  local workflow_phase="${3:-planning}"
  local plan_approved="${4:-false}"
  local team_name="${5:-}"
  local create_step="${6:-no}"
  local fill_tc="${7:-no}"

  mkdir -p "$dir/docs/${task_name}"
  echo "$task_name" > "$dir/docs/.active"

  # plan.md 생성 (plan_approved=true일 때)
  if [ "$plan_approved" = "true" ]; then
    echo "# Plan" > "$dir/docs/${task_name}/plan.md"
  fi

  # team config
  if [ -n "$team_name" ]; then
    mkdir -p "$HOME/.claude/teams/${team_name}"
    echo '{"members":[{"name":"lead"},{"name":"dev"}]}' > "$HOME/.claude/teams/${team_name}/config.json"
  fi

  local phase_folder="phase-1-test"
  mkdir -p "$dir/docs/${task_name}/${phase_folder}"

  if [ "$create_step" = "yes" ]; then
    if [ "$fill_tc" = "yes" ]; then
      cat > "$dir/docs/${task_name}/${phase_folder}/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 로그인 성공 | 토큰 반환 |  |
STEPEOF
    else
      cat > "$dir/docs/${task_name}/${phase_folder}/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 |  |  |  |
STEPEOF
    fi
  fi

  # git init for git diff commands
  (cd "$dir" && git init -q && git add -A && git -c user.email=test@test.com -c user.name=Test commit -m "init" -q) 2>/dev/null

  python3 - "$dir" "$task_name" "$workflow_phase" "$plan_approved" "$team_name" <<'PYEOF'
import json, sys
d, task, phase, approved, team_name = sys.argv[1:]
state = {
    'workflow_phase': phase,
    'plan_approved': approved == 'true',
    'team_name': team_name,
    'current_dev_phase': 1,
    'current_step': 1,
    'dev_phases': {
        '1': {
            'name': 'test',
            'folder': 'phase-1-test',
            'steps': {
                '1': {'title': 'Test step', 'doc_path': f'docs/{task}/phase-1-test/step-1.md'}
            }
        }
    },
    'verification': {'rounds_passed': 0}
}
with open(f'{d}/docs/{task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

run_hook() {
  local dir="$1"
  local input="$2"
  rm -f /tmp/.ai-bouncer-snapshot
  (cd "$dir" && echo "$input" | bash "$HOOK_SCRIPT" 2>/dev/null)
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

TEAM_DIRS_TO_CLEAN=()
cleanup_teams() {
  for td in "${TEAM_DIRS_TO_CLEAN[@]}"; do
    rm -rf "$td"
  done
}

# ---------------------------------------------------------------------------
# ALLOW: 쓰기 패턴 없음
# ---------------------------------------------------------------------------

# TC-B1: ls → ALLOW
tc_b1() {
  local dir="$TMPDIR_ROOT/tc_b1"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "ls -la")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B1: ls → ALLOW (쓰기 패턴 없음)" "$out"
}

# TC-B2: cat (읽기) → ALLOW
tc_b2() {
  local dir="$TMPDIR_ROOT/tc_b2"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "cat /some/file.txt")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B2: cat (읽기) → ALLOW" "$out"
}

# TC-B3: grep → ALLOW
tc_b3() {
  local dir="$TMPDIR_ROOT/tc_b3"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "grep -r 'pattern' src/")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B3: grep → ALLOW" "$out"
}

# TC-B4: git → ALLOW
tc_b4() {
  local dir="$TMPDIR_ROOT/tc_b4"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "git add -A && git commit -m 'test'")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B4: git → ALLOW" "$out"
}

# TC-B5: npm test → ALLOW
tc_b5() {
  local dir="$TMPDIR_ROOT/tc_b5"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "npm test")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B5: npm test → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# ALLOW: 예외 경로
# ---------------------------------------------------------------------------

# TC-B6: plan.md → ALLOW
tc_b6() {
  local dir="$TMPDIR_ROOT/tc_b6"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo '# Plan' > docs/my-task/plan.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B6: echo > plan.md → ALLOW (예외 경로)" "$out"
}

# TC-B7: ~/.claude/plans/ → ALLOW
tc_b7() {
  local dir="$TMPDIR_ROOT/tc_b7"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo 'plan' > ~/.claude/plans/my-plan.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B7: echo > ~/.claude/plans/ → ALLOW (예외 경로)" "$out"
}

# TC-B8: step-*.md → ALLOW
tc_b8() {
  local dir="$TMPDIR_ROOT/tc_b8"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo '# Step' > docs/my-task/phase-1/step-1.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B8: echo > step-1.md → ALLOW (예외 경로)" "$out"
}

# TC-B9: state.json → ALLOW
tc_b9() {
  local dir="$TMPDIR_ROOT/tc_b9"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "python3 -c 'import json; ...' > state.json")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B9: python > state.json → ALLOW (예외 경로)" "$out"
}

# ---------------------------------------------------------------------------
# BLOCK: planning + 쓰기
# ---------------------------------------------------------------------------

# TC-B10: cat > file (planning) → BLOCK
tc_b10() {
  local dir="$TMPDIR_ROOT/tc_b10"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "cat > /src/app.ts << 'EOF'\nconsole.log('hello')\nEOF")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B10: cat > file (planning) → BLOCK" "$out"
}

# TC-B11: echo > file (planning) → BLOCK
tc_b11() {
  local dir="$TMPDIR_ROOT/tc_b11"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo 'hello' > /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B11: echo > file (planning) → BLOCK" "$out"
}

# TC-B12: tee (planning) → BLOCK
tc_b12() {
  local dir="$TMPDIR_ROOT/tc_b12"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo 'data' | tee /src/config.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B12: tee (planning) → BLOCK" "$out"
}

# TC-B13: sed -i (planning) → BLOCK
tc_b13() {
  local dir="$TMPDIR_ROOT/tc_b13"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "sed -i 's/old/new/g' /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B13: sed -i (planning) → BLOCK" "$out"
}

# TC-B14: cp (planning) → BLOCK
tc_b14() {
  local dir="$TMPDIR_ROOT/tc_b14"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "cp /tmp/exploit.ts /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B14: cp (planning) → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# BLOCK: gate 미충족
# ---------------------------------------------------------------------------

# TC-B15: development + plan_approved=false → BLOCK
tc_b15() {
  local dir="$TMPDIR_ROOT/tc_b15"
  setup_env "$dir" "my-task" "development" "false" ""
  local input; input=$(make_input "echo 'hack' > /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B15: development + plan_approved=false → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# BLOCK: .active 비우기 공격
# ---------------------------------------------------------------------------

# TC-B16: planning + echo "" > .active → BLOCK (.active는 예외 아님)
tc_b16() {
  local dir="$TMPDIR_ROOT/tc_b16"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input 'echo "" > docs/.active')
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B16: planning + echo > .active → BLOCK (gate 무력화 방지)" "$out"
}

# ---------------------------------------------------------------------------
# ALLOW: 전체 충족
# ---------------------------------------------------------------------------

# TC-B17: development + 전체 조건 충족 + echo > → ALLOW
tc_b17() {
  local dir="$TMPDIR_ROOT/tc_b16"
  local team="test-team-tcb17-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes"
  local input; input=$(make_input "echo 'code' > /src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-B17: development + 전체 조건 충족 + echo > → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# BLOCK: rm/rmdir/unlink, curl/wget, workflow_phase whitelist, dev+step=0
# ---------------------------------------------------------------------------

# TC-B18: rm state.json (planning) → BLOCK
tc_b18() {
  local dir="$TMPDIR_ROOT/tc_b18"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "rm state.json")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B18: rm state.json (planning) → BLOCK" "$out"
}

# TC-B19: rm -rf docs/task/ (planning) → BLOCK
tc_b19() {
  local dir="$TMPDIR_ROOT/tc_b19"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "rm -rf docs/my-task/")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B19: rm -rf docs/task/ (planning) → BLOCK" "$out"
}

# TC-B20: workflow_phase=done + echo > file → BLOCK (whitelist)
tc_b20() {
  local dir="$TMPDIR_ROOT/tc_b20"
  setup_env "$dir" "my-task" "done" "true" ""
  python3 -c "
import json
f = '$dir/docs/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['workflow_phase'] = 'done'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  echo "# Plan" > "$dir/docs/my-task/plan.md"
  local input; input=$(make_input "echo 'hack' > /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B20: workflow_phase=done + echo > file → BLOCK (화이트리스트)" "$out"
}

# TC-B21: workflow_phase=invalid + echo > file → BLOCK
tc_b21() {
  local dir="$TMPDIR_ROOT/tc_b21"
  setup_env "$dir" "my-task" "planning" "false" ""
  python3 -c "
import json
f = '$dir/docs/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['workflow_phase'] = 'invalid'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local input; input=$(make_input "echo 'hack' > /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B21: workflow_phase=invalid → BLOCK" "$out"
}

# TC-B22: development + current_step=0 + echo > → BLOCK
tc_b22() {
  local dir="$TMPDIR_ROOT/tc_b22"
  local team="test-team-tcb22-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes"
  python3 -c "
import json
f = '$dir/docs/my-task/state.json'
with open(f) as fp: s = json.load(fp)
s['current_step'] = 0
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  local input; input=$(make_input "echo 'hack' > /src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B22: development + current_step=0 → BLOCK" "$out"
}

# TC-B23: curl -o src/file.ts url (planning) → BLOCK
tc_b23() {
  local dir="$TMPDIR_ROOT/tc_b23"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "curl -o src/file.ts https://example.com/file")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B23: curl -o (planning) → BLOCK" "$out"
}

# TC-B24: wget -O src/file.ts url (planning) → BLOCK
tc_b24() {
  local dir="$TMPDIR_ROOT/tc_b24"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "wget -O src/file.ts https://example.com/file")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B24: wget -O (planning) → BLOCK" "$out"
}

# TC-B25: curl url --output src/file.ts (planning) → BLOCK
tc_b25() {
  local dir="$TMPDIR_ROOT/tc_b25"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "curl https://example.com/file --output src/file.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B25: curl --output (planning) → BLOCK" "$out"
}

# TC-B27: ~/.claude/ai-bouncer/sessions/ Bash 쓰기 → BLOCK
tc_b27() {
  local dir="$TMPDIR_ROOT/tc_b27"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "echo 'hack' > ~/.claude/ai-bouncer/sessions/repo/docs/.active")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-B27: ~/.claude/ai-bouncer/sessions/ 쓰기 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== bash-gate.sh E2E Tests (Layer 1) ===${NC}"
echo ""

tc_b1; tc_b2; tc_b3; tc_b4; tc_b5
tc_b6; tc_b7; tc_b8; tc_b9
tc_b10; tc_b11; tc_b12; tc_b13; tc_b14
tc_b15
tc_b16; tc_b17
tc_b18; tc_b19; tc_b20; tc_b21; tc_b22
tc_b23; tc_b24; tc_b25; tc_b27

cleanup_teams

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
