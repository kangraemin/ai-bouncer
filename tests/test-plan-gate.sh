#!/usr/bin/env bash
# E2E tests for plan-gate.sh hook behavior (artifact-based)
# Usage: bash tests/test-plan-gate.sh

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; echo "       → $2"; ((FAIL_COUNT++)) || true; }

HOOK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/plan-gate.sh"

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

make_input() {
  local tool="${1:-Write}"
  local file_path="${2:-/some/file.txt}"
  jq -n --arg tool "$tool" --arg path "$file_path" \
    '{tool_name: $tool, tool_input: {file_path: $path}}'
}

# setup_env DIR TASK PHASE PLAN_APPROVED TEAM_NAME CREATE_STEP FILL_TC PREV_PASSED
# CREATE_STEP: "yes" → step-1.md 생성 (현재 step)
# FILL_TC: "yes" → step-1.md에 실제 TC 행 추가
# PREV_PASSED: "yes" → step-0.md (이전 step)에 ✅ 추가 (current_step=2일 때 사용)
setup_env() {
  local dir="$1"
  local task_name="$2"
  local workflow_phase="${3:-planning}"
  local plan_approved="${4:-false}"
  local team_name="${5:-}"
  local create_step="${6:-no}"
  local fill_tc="${7:-no}"
  local prev_passed="${8:-no}"

  mkdir -p "$dir/docs/${task_name}"
  echo "$task_name" > "$dir/docs/.active"

  # plan.md 생성 (plan_approved=true일 때)
  if [ "$plan_approved" = "true" ]; then
    echo "# Plan" > "$dir/docs/${task_name}/plan.md"
  fi

  # team config 생성 (team_name이 있을 때)
  if [ -n "$team_name" ]; then
    mkdir -p "$HOME/.claude/teams/${team_name}"
    echo '{"members":[{"name":"lead"},{"name":"dev"}]}' > "$HOME/.claude/teams/${team_name}/config.json"
  fi

  local phase_folder="phase-1-test"
  mkdir -p "$dir/docs/${task_name}/${phase_folder}"

  # step 파일 생성
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

  # 이전 step (prev_passed 용)
  if [ "$prev_passed" = "yes" ]; then
    cat > "$dir/docs/${task_name}/${phase_folder}/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 로그인 성공 | 토큰 반환 | ✅ PASS |
STEPEOF
  fi

  # state.json 생성
  local current_step=1
  if [ "$prev_passed" = "yes" ] || [ "$prev_passed" = "no_check" ]; then
    current_step=2
    if [ "$create_step" = "yes" ]; then
      if [ "$fill_tc" = "yes" ]; then
        cat > "$dir/docs/${task_name}/${phase_folder}/step-2.md" << 'STEPEOF'
# Step 2: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 검증 시나리오 | 성공 |  |
STEPEOF
      fi
    fi
  fi

  python3 - "$dir" "$task_name" "$workflow_phase" "$plan_approved" "$team_name" "$current_step" <<'PYEOF'
import json, sys
d, task, phase, approved, team_name, current_step = sys.argv[1:]
state = {
    'workflow_phase': phase,
    'plan_approved': approved == 'true',
    'team_name': team_name,
    'current_dev_phase': 1,
    'current_step': int(current_step),
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

# Cleanup helper for team dirs
TEAM_DIRS_TO_CLEAN=()
cleanup_teams() {
  for td in "${TEAM_DIRS_TO_CLEAN[@]}"; do
    rm -rf "$td"
  done
}

# ---------------------------------------------------------------------------
# TC-1: planning + Write plan.md → ALLOW
# ---------------------------------------------------------------------------
tc1() {
  local dir="$TMPDIR_ROOT/tc1"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "Write" "$dir/docs/my-task/plan.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-1: planning + Write plan.md → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-2: planning + Write regular file → BLOCK
# ---------------------------------------------------------------------------
tc2() {
  local dir="$TMPDIR_ROOT/tc2"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "Write" "/some/regular/file.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-2: planning + Write regular file → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-3: development + plan_approved=false → BLOCK
# ---------------------------------------------------------------------------
tc3() {
  local dir="$TMPDIR_ROOT/tc3"
  setup_env "$dir" "my-task" "development" "false" ""
  local input; input=$(make_input "Write" "/src/app.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-3: development + plan_approved=false → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-4: 전체 조건 충족 (팀+step+TC+plan.md) → ALLOW
# ---------------------------------------------------------------------------
tc4() {
  local dir="$TMPDIR_ROOT/tc4"
  local team="test-team-tc4-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-4: 전체 조건 충족 → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-5: planning + Write step-*.md → ALLOW
# ---------------------------------------------------------------------------
tc5() {
  local dir="$TMPDIR_ROOT/tc5"
  setup_env "$dir" "my-task" "planning" "false" ""
  local input; input=$(make_input "Write" "$dir/docs/my-task/phase-1/step-1.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-5: planning + Write step-*.md → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-6: development + Write phase-*.md → ALLOW
# ---------------------------------------------------------------------------
tc6() {
  local dir="$TMPDIR_ROOT/tc6"
  local team="test-team-tc6-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team"
  local input; input=$(make_input "Write" "$dir/docs/my-task/phase-1-auth/phase.md")
  local out; out=$(run_hook "$dir" "$input")
  assert_allow "TC-6: development + Write phase-*.md → ALLOW" "$out"
}

# ---------------------------------------------------------------------------
# TC-7: development + plan_approved=true + 팀 디렉토리 없음 → BLOCK
# ---------------------------------------------------------------------------
tc7() {
  local dir="$TMPDIR_ROOT/tc7"
  setup_env "$dir" "my-task" "development" "true" "nonexistent-team-$$"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-7: development + 팀 디렉토리 없음 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-8: development + 팀 있음 + step.md 미존재 → BLOCK
# ---------------------------------------------------------------------------
tc8() {
  local dir="$TMPDIR_ROOT/tc8"
  local team="test-team-tc8-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  # create_step=no → step-1.md 없음
  setup_env "$dir" "my-task" "development" "true" "$team" "no" "no"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-8: development + step.md 미존재 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-9: development + step.md 존재 + TC 행 비어있음 → BLOCK
# ---------------------------------------------------------------------------
tc9() {
  local dir="$TMPDIR_ROOT/tc9"
  local team="test-team-tc9-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  # create_step=yes, fill_tc=no → TC 행은 빈 템플릿
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "no"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-9: development + step.md TC 빈 템플릿 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-10: development + 이전 step에 ✅ 없음 → BLOCK
# ---------------------------------------------------------------------------
tc10() {
  local dir="$TMPDIR_ROOT/tc10"
  local team="test-team-tc10-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  # prev_passed=no_check → current_step=2, step-1.md 있지만 ✅ 없음
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes" "no_check"
  # step-1.md에 ✅ 없는 상태로 만듦
  cat > "$dir/docs/my-task/phase-1-test/step-1.md" << 'EOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 로그인 성공 | 토큰 반환 | FAIL |
EOF
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-10: development + 이전 step ✅ 없음 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-11: development + plan_approved=true + plan.md 파일 없음 → BLOCK
# ---------------------------------------------------------------------------
tc11() {
  local dir="$TMPDIR_ROOT/tc11"
  local team="test-team-tc11-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes"
  # plan.md 삭제
  rm -f "$dir/docs/my-task/plan.md"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-11: development + plan.md 없음 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# TC-12: development + 팀 멤버 1명 (부족) → BLOCK
# ---------------------------------------------------------------------------
tc12() {
  local dir="$TMPDIR_ROOT/tc12"
  local team="test-team-tc12-$$"
  TEAM_DIRS_TO_CLEAN+=("$HOME/.claude/teams/${team}")
  setup_env "$dir" "my-task" "development" "true" "$team" "yes" "yes"
  # 팀 멤버를 1명으로 변경
  echo '{"members":[{"name":"lead"}]}' > "$HOME/.claude/teams/${team}/config.json"
  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")
  assert_block "TC-12: development + 팀 멤버 1명 → BLOCK" "$out"
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== plan-gate.sh E2E Tests (Artifact-based) ===${NC}"
echo ""

tc1; tc2; tc3; tc4; tc5; tc6; tc7; tc8; tc9; tc10; tc11; tc12

# Cleanup team directories
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
