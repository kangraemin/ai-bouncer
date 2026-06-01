#!/bin/bash
# test-plan-gate.sh — unified mode 기준 plan-gate 종합 단위 테스트

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
OWNER_SID="pg-owner-sess"
mkdir -p "$TASK_DIR" "$PHASE_DIR" "$TASK_DIR/verifications"
echo "$OWNER_SID" > "$TASK_DIR/.active"
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
Test plan
EOF

DUMMY="$TMPDIR/dummy.sh"
touch "$DUMMY"
(cd "$TMPDIR" && git add dummy.sh && git commit -q -m "init")

write_state() { cat > "$TASK_DIR/state.json" <<EOF
$1
EOF
}

run_gate() {
  local file="$1"
  (cd "$TMPDIR" && echo "{\"tool_name\":\"Edit\",\"session_id\":\"$OWNER_SID\",\"tool_input\":{\"file_path\":\"$file\",\"old_string\":\"x\",\"new_string\":\"y\"}}" | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}

run_gate_state() {
  local new_content="$1"
  local encoded
  encoded=$(echo "$new_content" | jq -Rs .)
  (cd "$TMPDIR" && echo "{\"tool_name\":\"Write\",\"session_id\":\"$OWNER_SID\",\"tool_input\":{\"file_path\":\"$TASK_DIR/state.json\",\"content\":$encoded}}" \
    | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}

run_gate_write() {
  local file="$1" content="$2"
  local encoded
  encoded=$(echo "$content" | jq -Rs .)
  (cd "$TMPDIR" && echo "{\"tool_name\":\"Write\",\"session_id\":\"$OWNER_SID\",\"tool_input\":{\"file_path\":\"$file\",\"content\":$encoded}}" \
    | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}

BASE_STATE='{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"step 1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'

write_phase_md() { cat > "$PHASE_DIR/phase.md" <<EOF
$1
EOF
}

write_step1() { cat > "$PHASE_DIR/step-1.md" <<EOF
$1
EOF
}

# ── 기본 게이트 ──

# TC-01: plan_approved=false → block (CHECK 3)
write_state '{"workflow_phase":"development","plan_approved":false,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-01: plan_approved=false → block" "$(run_gate "$DUMMY")" "block"

# TC-02: dev_phases={} → block (CHECK 6.7)
write_state '{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
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

# TC-05: phase.md without ## 범위 → allow (기술 접근 있으면 통과)
write_phase_md "## 목표
goal here
## 기술 접근
- 파일 A: 변경 전 → 변경 후
## Steps
- step 1"
write_step1 "# Step 1

## TC
| TC-01 | happy path runs correctly | returns exit code 0 | \`echo ok\` | ⬜ |"
check "TC-05: phase.md without ## 범위 → allow (범위 제거됨)" "$(run_gate "$DUMMY")" "allow"

# TC-06: 이전 step에 ✅ 없음 → block (CHECK 7c), step=2
write_state '{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"},"2":{"title":"s2"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
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

# ── state.json 쓰기 검증 ──

# TC-08: plan_approved=true → development 쓰기 allow
write_state '{"workflow_phase":"planning","plan_approved":true,"current_dev_phase":0,"current_step":0,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-08: plan_approved=true → development 쓰기 allow" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{}}')" \
  "allow"

# TC-09: plan_approved=false → development 쓰기 block
write_state '{"workflow_phase":"planning","plan_approved":false,"current_dev_phase":0,"current_step":0,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-09: plan_approved=false → development 쓰기 block" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":false,"current_dev_phase":1,"current_step":1,"dev_phases":{}}')" \
  "block"

rm -f "$PHASE_DIR"/step-*.md

# TC-10: verification 전환 시 미완료 step → block (CHECK 1.6c)
write_state "$BASE_STATE"
write_phase_md "## 목표
goal
## Steps
- step 1"
write_step1 "# Step 1
## 구현 목표
Test"
check "TC-10: verification 전환 시 미완료 step → block" \
  "$(run_gate_state '{"workflow_phase":"verification","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-11: done 전환 시 미완료 step → block (e2e-result.md 있어도, CHECK 1.6c)
mkdir -p "$TASK_DIR/verifications"
cat > "$TASK_DIR/verifications/e2e-result.md" <<'EOF'
# E2E 결과
## 결론
통과
EOF
check "TC-11: done 전환 시 미완료 step → block (e2e-result.md 있어도)" \
  "$(run_gate_state '{"workflow_phase":"done","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-12: verification 전환 시 모든 step ✅, status 필드 없음 → allow (Bug fix)
write_step1 "# Step 1
## 구현 결과
Done ✅"
check "TC-12: verification 전환 시 모든 step ✅ + status 없음 → allow" \
  "$(run_gate_state '{"workflow_phase":"verification","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# TC-13: development → cancelled write → block
write_state "$BASE_STATE"
check "TC-13: development → cancelled → block" \
  "$(run_gate_state '{"workflow_phase":"cancelled","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-14: development → cancelled, 모든 step ✅ 있어도 → block
write_step1 "# Step 1
## 구현 결과
Done ✅"
check "TC-14: development → cancelled (모든 step ✅) → block" \
  "$(run_gate_state '{"workflow_phase":"cancelled","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# ── dev_phases.status 필드 검증 ──

# TC-15: verification 전환 + dev_phases status=pending → block (명시적 미완료)
write_step1 "# Step 1
## 구현 결과
Done ✅"
check "TC-15: verification + status=pending → block" \
  "$(run_gate_state '{"workflow_phase":"verification","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","status":"pending","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-16: verification + status=done → allow
check "TC-16: verification + status=done → allow" \
  "$(run_gate_state '{"workflow_phase":"verification","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","status":"done","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# TC-17: done + e2e 통과 + status=done → allow
check "TC-17: done + e2e 통과 + status=done → allow" \
  "$(run_gate_state '{"workflow_phase":"done","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","status":"done","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# TC-18: done + e2e 통과 + status="" (빈 문자열) → allow (비어있으면 스킵)
check "TC-18: done + e2e 통과 + status='' → allow" \
  "$(run_gate_state '{"workflow_phase":"done","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","status":"","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# ── step overflow / CHECK 1.6b ──

# TC-19: current_step > max_step → block (overflow)
check "TC-19: current_step 오버플로 → block" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":5,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{},"2":{}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-20: current_step = max_step (OK)
write_step1 "# Step 1
## TC
| TC-1 | happy | ok | pass | \`echo ok\` | ⬜ |"
check "TC-20: current_step = max_step → allow (no overflow)" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# ── verifications/ 경로 접근 제어 ──

# TC-21: development + verifications/ 쓰기 → block
write_state "$BASE_STATE"
VERF_FILE="$TASK_DIR/verifications/e2e-result.md"
check "TC-21: development + verifications/ 쓰기 → block" \
  "$(run_gate_write "$VERF_FILE" "# E2E 결과")" \
  "block"

# TC-22: verification + verifications/ 쓰기 → allow
write_state '{"workflow_phase":"verification","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"step 1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-22: verification + verifications/ 쓰기 → allow" \
  "$(run_gate_write "$VERF_FILE" "# E2E 결과")" \
  "allow"

# ── 예외 경로 ──

# TC-23: ~/.claude/plans/ 경로 → 즉시 allow (CHECK 0)
write_state "$BASE_STATE"
PLAN_PATH="$HOME/.claude/plans/test-plan.md"
check "TC-23: ~/.claude/plans/ 경로 → allow" \
  "$(run_gate_write "$PLAN_PATH" "# Plan")" \
  "allow"

# TC-24: plan.md 경로 → 즉시 allow (CHECK 1)
check "TC-24: plan.md 경로 → allow" \
  "$(run_gate_write "$TASK_DIR/plan.md" "# Plan")" \
  "allow"

# TC-25: .ai-bouncer-tasks/ 내부 .md 파일 → allow
check "TC-25: .ai-bouncer-tasks/ 내부 .md → allow" \
  "$(run_gate_write "$TASK_DIR/phase-1-test/step-2.md" "# Step 2")" \
  "allow"

# TC-26: .ai-bouncer-tasks/ 내부 .sh 파일 → block (스크립트 생성 금지)
check "TC-26: .ai-bouncer-tasks/ 내부 .sh → block" \
  "$(run_gate_write "$TASK_DIR/phase-1-test/run.sh" "#!/bin/bash")" \
  "block"

# TC-27: .ai-bouncer-tasks/ 내부 .py 파일 → block
check "TC-27: .ai-bouncer-tasks/ 내부 .py → block" \
  "$(run_gate_write "$TASK_DIR/helper.py" "import os")" \
  "block"

# ── phase.md 필수 섹션 ──

# TC-28: phase.md without ## 기술 접근 → block
write_phase_md "## 목표
goal
## Steps
- step 1"
write_step1 "# Step 1
## TC
| TC-1 | happy | ok | pass | \`echo x\` | ⬜ |"
write_state "$BASE_STATE"
check "TC-28: phase.md without ## 기술 접근 → block" "$(run_gate "$DUMMY")" "block"

# TC-29: phase.md 모든 섹션 있음 → allow
write_phase_md "## 목표
goal
## 기술 접근
- file.tsx: before → after
## Steps
- step 1"
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario pass | expected result | \`echo x\` | ⬜ |
검증 명령어: \`echo x\`"
check "TC-29: phase.md 모든 섹션 → allow" "$(run_gate "$DUMMY")" "allow"

# ── TC 형식 검증 ──

# TC-30: TC 시나리오 4자 (5자 미만) → block (CHECK 7e-2)
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | ok도 | pass | \`echo x\` | ⬜ |
검증 명령어: \`echo x\`"
check "TC-30: TC 시나리오 4자 → block" "$(run_gate "$DUMMY")" "block"

# TC-31: TC 시나리오 정확히 5자 → allow
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | ok여도x | pass여도x | \`echo x\` | ⬜ |
검증 명령어: \`echo x\`"
check "TC-31: TC 시나리오 5자 이상 → allow" "$(run_gate "$DUMMY")" "allow"

# TC-32: backtick 없음 → block (CHECK 7e-3)
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok |  |
검증 명령어: echo x"
check "TC-32: backtick 없음 → block" "$(run_gate "$DUMMY")" "block"

# TC-33: TC 형식이 | TC-1 |이 아닌 | 1 | → block (7e: TC-N 패턴 필요)
write_step1 "# Step 1
## 테스트 기준
| 1 | happy | scenario ok | expected ok | \`echo x\` | ⬜ |
검증 명령어: \`echo x\`"
check "TC-33: TC-ID=1 (TC-N 아님) → block" "$(run_gate "$DUMMY")" "block"

# ── 이전 step 실행출력 검증 ──

# TC-34: step=2이고 step-1에 ✅있지만 실행출력 없음 → block (CHECK 7c-2)
write_state '{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"},"2":{"title":"s2"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
write_phase_md "## 목표
goal
## 기술 접근
- file: before → after
## Steps
- step 1
- step 2"
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok | \`echo x\` | ✅ |
검증 명령어: \`echo x\`"
cat > "$PHASE_DIR/step-2.md" <<'EOF'
# Step 2
## 테스트 기준
| TC-1 | happy | s2 scenario | s2 expected | `echo y` | ⬜ |
검증 명령어: `echo y`
EOF
check "TC-34: 이전 step ✅ 있지만 실행출력 없음 → block" "$(run_gate "$DUMMY")" "block"

# TC-35: step-1에 ✅ + 실행출력 1줄만 (펜스 없이) → block (최소 2줄 필요, CHECK 7c-3)
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok | \`echo x\` | ✅ |
검증 명령어: \`echo x\`
## 실행출력
단 한 줄"
check "TC-35: 실행출력 1줄 → block (2줄 미만)" "$(run_gate "$DUMMY")" "block"

# TC-36: step-1에 ✅ + 실행출력 2줄 → allow
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok | \`echo x\` | ✅ |
검증 명령어: \`echo x\`
## 실행출력
첫째 줄 출력
둘째 줄 출력"
check "TC-36: 실행출력 2줄 → allow" "$(run_gate "$DUMMY")" "allow"

# ── 이전 Phase 검증 ──

rm -f "$PHASE_DIR"/step-*.md
PHASE2_DIR="$TASK_DIR/phase-2-second"
mkdir -p "$PHASE2_DIR"

# TC-37: Phase 2로 이동했는데 Phase 1 step ✅ 없음 → block
write_state '{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"s1"}},"team_name":""},"2":{"name":"second","folder":"phase-2-second","steps":{"1":{"title":"s1"}},"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
write_phase_md "## 목표
p1 goal
## 기술 접근
- file: before → after
## Steps
- step 1"
write_step1 "# Step 1 (미완료)"
cat > "$PHASE2_DIR/phase.md" <<'EOF'
## 목표
p2 goal
## 기술 접근
- file2: before → after
## Steps
- step 1
EOF
cat > "$PHASE2_DIR/step-1.md" <<'EOF'
# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok | `echo z` | ⬜ |
검증 명령어: `echo z`
EOF
check "TC-37: Phase 1 미완료 상태에서 Phase 2 수정 → block" "$(run_gate "$DUMMY")" "block"

# TC-38: Phase 1 step ✅ 있음 → Phase 2 수정 allow
write_step1 "# Step 1
## 테스트 기준
| TC-1 | happy | scenario ok | expected ok | \`echo x\` | ✅ |

## 실행출력
\`\`\`
출력줄 1
출력줄 2
\`\`\`"
check "TC-38: Phase 1 ✅ → Phase 2 수정 allow" "$(run_gate "$DUMMY")" "allow"

# ── CHECK 1.6f: resolved_agent_mode single override ──

# TC-39: phase_count>3 + config≠single + 새 content에 single → block
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
check "TC-39: phase_count>3 + config=team + single override → block" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{},"2":{},"3":{},"4":{}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "block"

# TC-40: phase_count=3 + config=team + single → allow (3 이하는 허용)
check "TC-40: phase_count=3 + single override → allow (≤3 허용)" \
  "$(run_gate_state '{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{},"2":{},"3":{}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}')" \
  "allow"

# ── 없는 task (.active 없음) ──

# TC-41: .active 파일 없는 경우 → allow (gate 비활성)
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF
rm -f "$TASK_DIR/.active"
write_state "$BASE_STATE"
check "TC-41: .active 없음 → allow" "$(run_gate "$DUMMY")" "allow"
echo "$OWNER_SID" > "$TASK_DIR/.active"

# ── nested sub-project: git toplevel ≠ 작업 디렉토리 ──
# (sub-dir이 자체 git repo가 아니면 git rev-parse가 상위 repo를 반환 →
#  .ai-bouncer-tasks/가 toplevel 바로 아래가 아니어도 task 파일로 인식해야 함)

NESTED_TASK="$TMPDIR/subproj/.ai-bouncer-tasks/2026-01-01/nested-task"
NESTED_SID="pg-nested-sess"
mkdir -p "$NESTED_TASK"
echo "$NESTED_SID" > "$NESTED_TASK/.active"
NESTED_STATE='{"workflow_phase":"planning","plan_approved":false,"current_dev_phase":0,"current_step":0,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/nested-task","active_file":".ai-bouncer-tasks/2026-01-01/nested-task/.active"}'
echo "$NESTED_STATE" > "$NESTED_TASK/state.json"
NESTED_ENC=$(echo "$NESTED_STATE" | jq -Rs .)

# TC-42: nested sub-project의 .ai-bouncer-tasks/ 하위 state.json (planning) → allow
NESTED_OUT=$(cd "$TMPDIR/subproj" && echo "{\"tool_name\":\"Write\",\"session_id\":\"$NESTED_SID\",\"tool_input\":{\"file_path\":\"$NESTED_TASK/state.json\",\"content\":$NESTED_ENC}}" | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
check "TC-42: nested sub-project planning state.json write → allow" "$NESTED_OUT" "allow"

# TC-43: nested sub-project의 .ai-bouncer-tasks/ 밖 일반 소스 파일 (planning) → block (정상 차단 유지)
NESTED_SRC_OUT=$(cd "$TMPDIR/subproj" && echo "{\"tool_name\":\"Write\",\"session_id\":\"$NESTED_SID\",\"tool_input\":{\"file_path\":\"$TMPDIR/subproj/foo.sh\",\"content\":\"echo hi\"}}" | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
check "TC-43: nested sub-project non-task source file → block" "$NESTED_SRC_OUT" "block"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
