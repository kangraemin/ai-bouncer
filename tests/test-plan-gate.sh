#!/bin/bash
# test-plan-gate.sh — unified mode 기준 plan-gate 단위 테스트

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

# 임시 git repo + bouncer config (single mode)
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")
mkdir -p "$TMPDIR/.claude/ai-bouncer"
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
PHASE_DIR="$TASK_DIR/phase-1-test"
mkdir -p "$TASK_DIR" "$PHASE_DIR"
touch "$TASK_DIR/.active"
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
Test plan
EOF

# Dummy source file to write (outside .ai-bouncer-tasks)
DUMMY="$TMPDIR/dummy.sh"
touch "$DUMMY"
(cd "$TMPDIR" && git add dummy.sh && git commit -q -m "init")

write_state() {
  cat > "$TASK_DIR/state.json" <<EOF
$1
EOF
}

run_gate() {
  local file="$1"
  (cd "$TMPDIR" && echo "{\"tool_name\":\"Edit\",\"session_id\":\"\",\"tool_input\":{\"file_path\":\"$file\",\"old_string\":\"x\",\"new_string\":\"y\"}}" | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}

BASE_STATE='{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"step 1"}}}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'

write_phase_md() {
  cat > "$PHASE_DIR/phase.md" <<EOF
$1
EOF
}

write_step1() {
  cat > "$PHASE_DIR/step-1.md" <<EOF
$1
EOF
}

# TC-01: plan_approved=false → block (CHECK 3)
write_state '{"workflow_phase":"development","plan_approved":false,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}}}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-01: plan_approved=false → block" "$(run_gate "$DUMMY")" "block"

# TC-02: dev_phases={} → block (CHECK 6.7)
write_state '{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-02: dev_phases={} → block" "$(run_gate "$DUMMY")" "block"

# TC-03: phase.md without ## 목표 → block (CHECK 7a-2)
write_state "$BASE_STATE"
write_phase_md "## 범위
scope here
## Steps
- step 1"
check "TC-03: phase.md without ## 목표 → block" "$(run_gate "$DUMMY")" "block"

# TC-04: phase.md without ## Steps → block (CHECK 7a-2)
write_phase_md "## 목표
goal here
## 범위
scope here"
check "TC-04: phase.md without ## Steps → block" "$(run_gate "$DUMMY")" "block"

# TC-05: phase.md without ## 범위 → NOT blocked (범위 required 섹션에서 제거됨)
write_phase_md "## 목표
goal here
## Steps
- step 1"
write_step1 "# Step 1

## TC
| TC-01 | happy path runs correctly | returns exit code 0 | \`echo ok\` | ⬜ |"
check "TC-05: phase.md without ## 범위 → allow (범위 제거됨)" "$(run_gate "$DUMMY")" "allow"

# TC-06: 이전 step에 ✅ 없음 → block (CHECK 7c), step=2
write_state '{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"},"2":{"title":"s2"}}}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
write_phase_md "## 목표
goal
## Steps
- step 1
- step 2"
write_step1 "# Step 1

## TC
| TC-01 | previous step test | returns exit code 0 | \`echo ok\` | ⬜ |"
cat > "$PHASE_DIR/step-2.md" <<'EOF'
# Step 2

## TC
| TC-01 | current step test | returns exit code 0 | `echo ok` | ⬜ |
EOF
check "TC-06: 이전 step에 ✅ 없음 → block" "$(run_gate "$DUMMY")" "block"

# TC-07: 현재 step에 TC 없음 → block (CHECK 7e)
write_state "$BASE_STATE"
write_phase_md "## 목표
goal
## Steps
- step 1"
write_step1 "# Step 1

## 개발 내용
어떤 기능을 개발합니다."
check "TC-07: 현재 step에 TC 없음 → block" "$(run_gate "$DUMMY")" "block"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
