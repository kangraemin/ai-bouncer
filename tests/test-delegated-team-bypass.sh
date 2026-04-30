#!/bin/bash
# test-delegated-team-bypass.sh — delegated subagent + team 모드 team_name 검증
#
# 버그 시나리오: agent_mode=team + team_name="" 상태에서
#   1) subagent-track.sh 가 활성 development task에 대해 team_name 검증 없이 등록
#   2) bash-gate.sh 가 IS_DELEGATED_AGENT=true 경로에서 검증 없이 통과
# 본 테스트는 두 경로 모두에서 team_name 검증이 동작하는지 확인한다.

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

# 글로벌 /tmp/.ai-bouncer-approved-agents 백업 (다른 세션 영향 방지)
APPROVED_GLOBAL="/tmp/.ai-bouncer-approved-agents"
ORIG_APPROVED=""
if [ -f "$APPROVED_GLOBAL" ]; then
  ORIG_APPROVED=$(cat "$APPROVED_GLOBAL")
fi

restore_approved() {
  if [ -z "$ORIG_APPROVED" ]; then
    rm -f "$APPROVED_GLOBAL"
  else
    printf '%s\n' "$ORIG_APPROVED" > "$APPROVED_GLOBAL"
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'; restore_approved" EXIT

# 임시 git repo
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")
mkdir -p "$TMPDIR/.claude/ai-bouncer"

# 활성 development task
TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-05-01/test-delegated-team"
PHASE_DIR="$TASK_DIR/phase-1-test"
mkdir -p "$PHASE_DIR" "$TASK_DIR/verifications"

# .active 파일 (claim 상태). 테스트 SID는 시나리오마다 다르게 사용.
DUMMY_SID="active-owner-sid-$$"
echo "$DUMMY_SID" > "$TASK_DIR/.active"

# plan.md (gate-checks가 요구할 수 있음)
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
Test delegated team_name validation
EOF

# write 대상 더미 파일 (project source 위치)
DUMMY="$TMPDIR/dummy.txt"
touch "$DUMMY"

write_team_config() {
  cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
}

write_subagent_config() {
  cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"subagent","commit_strategy":"none"}
EOF
}

write_state() {
  printf '%s\n' "$1" > "$TASK_DIR/state.json"
}

# approved-agents에 SID 등록 (delegated 경로 활성화)
register_approved() {
  local sid="$1"
  echo "${sid}|${TASK_DIR}" >> "$APPROVED_GLOBAL"
}

# approved-agents 초기화 (다른 시나리오 간 누수 방지)
clear_approved() {
  : > "$APPROVED_GLOBAL"
}

# subagent-track.sh 호출 후 등록 여부 확인
# 반환: "registered" 또는 "rejected"
run_subagent_track() {
  local sid="$1"
  clear_approved
  (cd "$TMPDIR" && jq -n --arg sid "$sid" '{"session_id":$sid}' \
    | bash "$HOOKS_DIR/subagent-track.sh" 2>/dev/null) || true
  if grep -q "^${sid}|" "$APPROVED_GLOBAL" 2>/dev/null; then
    echo "registered"
  else
    echo "rejected"
  fi
}

# bash-gate.sh 호출 (delegated 경로). state/config는 호출 전 미리 세팅.
run_bash_gate_delegated() {
  local sid="$1"
  (cd "$TMPDIR" && jq -n --arg cmd "echo foo > $DUMMY" --arg sid "$sid" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

check_track() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (expected=$expected got=$actual)"; FAIL=$((FAIL+1))
  fi
}

# ============================================================
# 시나리오 A: top-level team_name (legacy/fallback) 검증
# ============================================================
echo "=== 시나리오 A: top-level team_name ==="

# 공통 state (top-level team_name 만 시나리오별로 변경)
STATE_TOP_EMPTY='{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}},"task_dir":".ai-bouncer-tasks/2026-05-01/test-delegated-team","active_file":".ai-bouncer-tasks/2026-05-01/test-delegated-team/.active"}'

STATE_TOP_SET='{"workflow_phase":"development","plan_approved":true,"team_name":"my-team","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}},"task_dir":".ai-bouncer-tasks/2026-05-01/test-delegated-team","active_file":".ai-bouncer-tasks/2026-05-01/test-delegated-team/.active"}'

# TC-A1: subagent-track.sh — team 모드 + top-level team_name="" → 등록 거부
write_team_config
write_state "$STATE_TOP_EMPTY"
SID_A1="agent-a1-$$"
RESULT=$(run_subagent_track "$SID_A1")
check_track "TC-A1: track + team + team_name='' → rejected" "$RESULT" "rejected"

# TC-A2: bash-gate.sh — 수동 등록 후 team 모드 + team_name="" → block
# 시나리오: track이 (어떤 이유든) 등록을 허용한 상태에서도 gate가 마지막 방어선이어야 함
write_team_config
write_state "$STATE_TOP_EMPTY"
clear_approved
SID_A2="agent-a2-$$"
register_approved "$SID_A2"
OUT=$(run_bash_gate_delegated "$SID_A2")
check "TC-A2: gate(delegated) + team + team_name='' → block" "$OUT" "block"

# TC-A3: subagent-track.sh — team 모드 + top-level team_name="my-team" → 등록됨
write_team_config
write_state "$STATE_TOP_SET"
SID_A3="agent-a3-$$"
RESULT=$(run_subagent_track "$SID_A3")
check_track "TC-A3: track + team + team_name='my-team' → registered" "$RESULT" "registered"

# TC-A4: bash-gate.sh — TC-A3 상태에서 delegated 경로 → allow
write_team_config
write_state "$STATE_TOP_SET"
clear_approved
register_approved "$SID_A3"
OUT=$(run_bash_gate_delegated "$SID_A3")
check "TC-A4: gate(delegated) + team + team_name='my-team' → allow" "$OUT" "allow"

# ============================================================
# 시나리오 B: per-phase team_name (current_dev_phase 우선)
# ============================================================
echo ""
echo "=== 시나리오 B: per-phase team_name ==="

# Phase 2 디렉토리 생성
PHASE2_DIR="$TASK_DIR/phase-2-second"
mkdir -p "$PHASE2_DIR"

STATE_PHASE2_EMPTY='{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"first","folder":"phase-1-test","team_name":"team-1"},"2":{"name":"second","folder":"phase-2-second","team_name":""}},"task_dir":".ai-bouncer-tasks/2026-05-01/test-delegated-team","active_file":".ai-bouncer-tasks/2026-05-01/test-delegated-team/.active"}'

STATE_PHASE2_SET='{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"first","folder":"phase-1-test","team_name":"team-1"},"2":{"name":"second","folder":"phase-2-second","team_name":"phase2-team"}},"task_dir":".ai-bouncer-tasks/2026-05-01/test-delegated-team","active_file":".ai-bouncer-tasks/2026-05-01/test-delegated-team/.active"}'

# TC-B1: track — team 모드 + dev_phase=2 + dev_phases.2.team_name="" → 등록 거부
write_team_config
write_state "$STATE_PHASE2_EMPTY"
SID_B1="agent-b1-$$"
RESULT=$(run_subagent_track "$SID_B1")
check_track "TC-B1: track + dev_phase=2 + per-phase team_name='' → rejected" "$RESULT" "rejected"

# TC-B2: track — team 모드 + dev_phases.2.team_name="phase2-team" → 등록됨
write_team_config
write_state "$STATE_PHASE2_SET"
SID_B2="agent-b2-$$"
RESULT=$(run_subagent_track "$SID_B2")
check_track "TC-B2: track + dev_phase=2 + per-phase team_name='phase2-team' → registered" "$RESULT" "registered"

# ============================================================
# 시나리오 C: subagent 모드는 team_name 검증 대상 아님
# ============================================================
echo ""
echo "=== 시나리오 C: subagent 모드 (team_name 검증 안 함) ==="

# TC-C1: subagent 모드 + team_name="" → 등록됨 (차단 없음)
write_subagent_config
write_state "$STATE_TOP_EMPTY"
SID_C1="agent-c1-$$"
RESULT=$(run_subagent_track "$SID_C1")
check_track "TC-C1: track + subagent mode + team_name='' → registered" "$RESULT" "registered"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
