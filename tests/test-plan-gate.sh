#!/usr/bin/env bash
# E2E tests for plan-gate.sh hook behavior
# Tests: plan.md exception, planning block, plan_approved block, dev allow
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

# Build a hook input JSON for a Write tool call
make_input() {
  local tool="${1:-Write}"
  local file_path="${2:-/some/file.txt}"
  jq -n --arg tool "$tool" --arg path "$file_path" \
    '{tool_name: $tool, tool_input: {file_path: $path}}'
}

# Set up a minimal repo environment with docs/.active and state.json
setup_env() {
  local dir="$1"
  local task_name="$2"
  local workflow_phase="${3:-planning}"
  local plan_approved="${4:-false}"
  local team_spawned="${5:-false}"
  local test_defined="${6:-false}"

  mkdir -p "$dir/docs/${task_name}"
  echo "$task_name" > "$dir/docs/.active"

  python3 - "$dir" "$task_name" "$workflow_phase" "$plan_approved" "$team_spawned" "$test_defined" <<'PYEOF'
import json, sys
d, task, phase, approved, spawned, tdefined = sys.argv[1:]
state = {
    'workflow_phase': phase,
    'plan_approved': approved == 'true',
    'team_spawned': spawned == 'true',
    'current_dev_phase': 1,
    'current_step': 1,
    'dev_phases': {
        '1': {
            'steps': {
                '1': {
                    'test_defined': tdefined == 'true',
                    'passed': False
                }
            }
        }
    },
    'verification': {'rounds_passed': 0}
}
with open(f'{d}/docs/{task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

# Run the hook from within the test directory
run_hook() {
  local dir="$1"
  local input="$2"
  # Run hook from dir so relative paths (docs/.active etc.) resolve correctly
  (cd "$dir" && echo "$input" | bash "$HOOK_SCRIPT" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# TC-1: planning + Write to */plan.md → ALLOW (no block)
# ---------------------------------------------------------------------------
tc1() {
  local dir="$TMPDIR_ROOT/tc1"
  setup_env "$dir" "my-task" "planning" "false" "false" "false"

  local input; input=$(make_input "Write" "$dir/docs/my-task/plan.md")
  local out; out=$(run_hook "$dir" "$input")

  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)

  if [ "$decision" != "block" ]; then
    pass "TC-1: planning + Write to plan.md → ALLOW"
  else
    local reason; reason=$(echo "$out" | jq -r '.reason // ""' 2>/dev/null)
    fail "TC-1: planning + Write to plan.md → ALLOW" "got block: $reason"
  fi
}

# ---------------------------------------------------------------------------
# TC-2: planning + Write to regular file → BLOCK
# ---------------------------------------------------------------------------
tc2() {
  local dir="$TMPDIR_ROOT/tc2"
  setup_env "$dir" "my-task" "planning" "false" "false" "false"

  local input; input=$(make_input "Write" "/some/regular/file.ts")
  local out; out=$(run_hook "$dir" "$input")

  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)

  if [ "$decision" = "block" ]; then
    pass "TC-2: planning + Write to regular file → BLOCK"
  else
    fail "TC-2: planning + Write to regular file → BLOCK" "expected block, got: $out"
  fi
}

# ---------------------------------------------------------------------------
# TC-3: plan_approved=false (non-planning phase) + Write → BLOCK
# ---------------------------------------------------------------------------
tc3() {
  local dir="$TMPDIR_ROOT/tc3"
  setup_env "$dir" "my-task" "development" "false" "false" "false"

  local input; input=$(make_input "Write" "/src/app.ts")
  local out; out=$(run_hook "$dir" "$input")

  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)

  if [ "$decision" = "block" ]; then
    pass "TC-3: plan_approved=false + Write → BLOCK"
  else
    fail "TC-3: plan_approved=false + Write → BLOCK" "expected block, got: $out"
  fi
}

# ---------------------------------------------------------------------------
# TC-4: dev + team_spawned=true + test_defined=true + Write → ALLOW
# ---------------------------------------------------------------------------
tc4() {
  local dir="$TMPDIR_ROOT/tc4"
  setup_env "$dir" "my-task" "development" "true" "true" "true"

  local input; input=$(make_input "Write" "/src/feature.ts")
  local out; out=$(run_hook "$dir" "$input")

  local decision; decision=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null)

  if [ "$decision" != "block" ]; then
    pass "TC-4: dev + team_spawned=true + test_defined=true + Write → ALLOW"
  else
    local reason; reason=$(echo "$out" | jq -r '.reason // ""' 2>/dev/null)
    fail "TC-4: dev + team_spawned=true + test_defined=true + Write → ALLOW" "got block: $reason"
  fi
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== plan-gate.sh E2E Tests ===${NC}"
echo ""

tc1
tc2
tc3
tc4

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
