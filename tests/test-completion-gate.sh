#!/bin/bash
# test-completion-gate.sh — completion-gate 종합 단위 테스트

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

check_reason() {
  local label="$1" output="$2" needle="$3"
  if echo "$output" | jq -r '.reason // ""' 2>/dev/null | grep -qF "$needle"; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (reason에 '$needle' 없음)"; echo "   output: $output"; FAIL=$((FAIL+1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
mkdir -p "$TASK_DIR/verifications"
touch "$TASK_DIR/.active"

write_state() {
  cat > "$TASK_DIR/state.json" <<EOF
$1
EOF
}

run_gate() {
  local sid="${1:-}"
  (cd "$TMPDIR" && echo "{\"session_id\":\"$sid\",\"stop_hook_active\":false}" | bash "$HOOKS_DIR/completion-gate.sh" 2>/dev/null) || true
}

# ── 기본 workflow_phase별 ──

# TC-01: verification + e2e-result.md 없음 → block
write_state '{"workflow_phase":"verification","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-01: verification + no e2e-result.md → block" "$(run_gate)" "block"

# TC-02: verification + e2e-result.md 실패 → block
printf "## 결론\n실패\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-02: verification + e2e-result.md 실패 → block" "$(run_gate)" "block"

# TC-03: verification + e2e-result.md 통과 → allow
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-03: verification + e2e-result.md 통과 → allow" "$(run_gate)" "allow"

# TC-04: done + e2e-result.md 통과 → allow
write_state '{"workflow_phase":"done","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-04: done + e2e-result.md 통과 → allow" "$(run_gate)" "allow"

# TC-05: planning phase → allow
write_state '{"workflow_phase":"planning","plan_approved":false,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-05: planning phase → allow" "$(run_gate)" "allow"

# TC-06: development + dev_phases={} → allow
write_state '{"workflow_phase":"development","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-06: development + dev_phases={} → allow" "$(run_gate)" "allow"

# TC-07: cancelled → allow
write_state '{"workflow_phase":"cancelled","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-07: cancelled → allow" "$(run_gate)" "allow"

# ── done 상태 검증 ──

# TC-08: done + plan_approved=true + no e2e-result.md → block
rm -f "$TASK_DIR/verifications/e2e-result.md"
write_state '{"workflow_phase":"done","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-08: done + plan_approved=true + no e2e → block" "$(run_gate)" "block"

# TC-09: done + plan_approved=false + no e2e → allow (plan_approved 미설정 시 done 통과)
write_state '{"workflow_phase":"done","plan_approved":false,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-09: done + plan_approved=false + no e2e → allow" "$(run_gate)" "allow"

# TC-10: done + plan_approved=true + e2e 실패 → block
printf "## 결론\n실패 — 검증 실패\n" > "$TASK_DIR/verifications/e2e-result.md"
write_state '{"workflow_phase":"done","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-10: done + e2e 실패 → block" "$(run_gate)" "block"

# ── e2e-result.md 형식 검증 ──

# TC-11: 결론 바로 뒤 빈 줄 있으면 → block (## 결론\n\n통과)
printf "## 결론\n\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
write_state '{"workflow_phase":"verification","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}'
check "TC-11: e2e 결론 뒤 빈 줄 → block" "$(run_gate)" "block"

# TC-12: 결론 + 통과 — 부가 설명 → allow
printf "## 결론\n통과 — 모든 검증 완료\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-12: 결론 통과+설명 → allow" "$(run_gate)" "allow"

# TC-13: ## 결론 없는 e2e-result.md → block
printf "모든 테스트 통과\n" > "$TASK_DIR/verifications/e2e-result.md"
check "TC-13: e2e 결론 섹션 없음 → block" "$(run_gate)" "block"

# ── development 단계 step ✅ 검증 ──

PHASE_DIR="$TASK_DIR/phase-1-test"
mkdir -p "$PHASE_DIR"

# TC-A: Bug A 회귀 — current_dev_phase=2 > PHASE_COUNT=1, 모든 step ✅ → block
printf "| TC-1 | happy | scenario | expected | ✅ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-A: Bug A — current_dev_phase=2 > PHASE_COUNT=1 → block" "$(run_gate)" "block"

# TC-B: Bug B 회귀 — step에 TC-1 ✅ + TC-2 ⏸️ → block
printf "| TC-1 | happy | scenario | expected | ✅ |\n| TC-2 | e2e | scenario | expected | ⏸️ deferred |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-B: Bug B — TC-1 ✅ + TC-2 ⏸️ → block" "$(run_gate)" "block"

# TC-C: 모든 TC ✅ → block (verification 전환 강제)
printf "| TC-1 | happy | scenario | expected | ✅ |\n| TC-2 | e2e | scenario | expected | ✅ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-C: 모든 TC ✅ → block (verification 전환 강제)" "$(run_gate)" "block"

# ── TC 결과 컬럼별 ──

# TC-14: TC 결과 컬럼에 ❌ → block
printf "| TC-1 | happy | scenario | expected | ❌ |\n" > "$PHASE_DIR/step-1.md"
check "TC-14: TC결과 ❌ → block" "$(run_gate)" "block"

# TC-15: TC 결과 컬럼에 빈셀 → block
printf "| TC-1 | happy | scenario | expected |  |\n" > "$PHASE_DIR/step-1.md"
check "TC-15: TC결과 빈셀 → block" "$(run_gate)" "block"

# TC-16: TC 결과 컬럼에 임의 텍스트 → block
printf "| TC-1 | happy | scenario | expected | 검증중 |\n" > "$PHASE_DIR/step-1.md"
check "TC-16: TC결과 임의텍스트 → block" "$(run_gate)" "block"

# ── 멀티 Phase ──

PHASE2_DIR="$TASK_DIR/phase-2-second"
mkdir -p "$PHASE2_DIR"

# TC-17: Phase 1 done ✅, Phase 2 step 미완료 → block
printf "| TC-1 | happy | scenario ok | expected pass | ✅ |\n" > "$PHASE_DIR/step-1.md"
printf "| TC-1 | e2e | phase2 test | pass check | ❌ |\n" > "$PHASE2_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""},"2":{"name":"second","steps":{"1":"y"},"depends_on":[1],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-17: Phase1 ✅ Phase2 ❌ → block" "$(run_gate)" "block"

# TC-18: Phase 1 done ✅, Phase 2 done ✅ → block (verification 전환 강제)
printf "| TC-1 | e2e | phase2 test | pass | ✅ |\n" > "$PHASE2_DIR/step-1.md"
check "TC-18: Phase1 ✅ Phase2 ✅ → block (verification 강제)" "$(run_gate)" "block"

# TC-19: Phase 1 step 없음 → block (step 파일 없는 phase)
rm -f "$PHASE_DIR"/step-*.md
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-19: step 파일 없는 phase → block" "$(run_gate)" "block"

# TC-20: Phase 폴더 없음 → block
rm -rf "$PHASE2_DIR"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[]},"2":{"name":"missing","steps":{"1":"y"},"depends_on":[]}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-20: phase 폴더 없음 → block" "$(run_gate)" "block"

# ── 세션 격리 ──

# TC-21: SESSION_ID가 .active와 일치 → 내 task
OTHER_SID="other-session-999"
MY_SID="my-session-abc"
echo "$MY_SID" > "$TASK_DIR/.active"
printf "| TC-1 | happy | done | pass | ✅ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-21: 내 session_id → task 매칭 → block (완료 시 verification 강제)" \
  "$(run_gate "$MY_SID")" "block"

# TC-22: SESSION_ID가 다른 세션 → 내 task 아님 → allow
check "TC-22: 타 session_id → IS_MY_TASK=false → allow" \
  "$(run_gate "$OTHER_SID")" "allow"

# .active 원상복구
touch "$TASK_DIR/.active"

# ── subagent 우회 ──

APPROVED_GLOBAL="/tmp/.ai-bouncer-approved-agents"
ORIG_APPROVED=""
[ -f "$APPROVED_GLOBAL" ] && ORIG_APPROVED=$(cat "$APPROVED_GLOBAL")
restore_approved() { [ -z "$ORIG_APPROVED" ] && rm -f "$APPROVED_GLOBAL" || printf '%s\n' "$ORIG_APPROVED" > "$APPROVED_GLOBAL"; }
trap "rm -rf '$TMPDIR'; restore_approved" EXIT

# TC-23: 승인된 subagent SESSION_ID → completion-gate 즉시 스킵 → allow
SUBAGENT_SID="subagent-delegated-$$"
: > "$APPROVED_GLOBAL"
echo "${SUBAGENT_SID}|${TASK_DIR}" >> "$APPROVED_GLOBAL"
# development + step ❌ 있어도 subagent면 스킵
printf "| TC-1 | e2e | test | pass | ❌ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-23: 승인된 subagent → completion-gate 스킵 → allow" \
  "$(run_gate "$SUBAGENT_SID")" "allow"
sed -i.bak "/$SUBAGENT_SID/d" "$APPROVED_GLOBAL" 2>/dev/null; rm -f "${APPROVED_GLOBAL}.bak"

# ── _get_phase_folder fallback ──

# TC-24: dev_phases에 folder 키 없고 phase-1-* 디렉토리 존재 → fallback으로 찾음 → step 체크
mkdir -p "$TASK_DIR/phase-1-myname"
printf "| TC-1 | happy | ok | pass | ✅ |\n" > "$TASK_DIR/phase-1-myname/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"myname","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-24: folder 키 없이 phase-1-* 패턴 매칭 → block (verification 강제)" "$(run_gate)" "block"
rm -rf "$TASK_DIR/phase-1-myname"

# TC-25: dev_phases에 folder 키 있고 해당 디렉토리 존재 → 정확히 매칭
mkdir -p "$TASK_DIR/phase-1-explicit"
printf "| TC-1 | happy | ok | pass | ✅ |\n" > "$TASK_DIR/phase-1-explicit/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"explicit","folder":"phase-1-explicit","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-25: folder 키 명시 → 직접 매칭 → block (verification 강제)" "$(run_gate)" "block"
rm -rf "$TASK_DIR/phase-1-explicit"

# ── 멀티 step phase ──

mkdir -p "$PHASE_DIR"

# TC-26: step-1 ✅ step-2 ❌ → block
printf "| TC-1 | happy | ok | pass | ✅ |\n" > "$PHASE_DIR/step-1.md"
printf "| TC-1 | e2e | not done | fail | ❌ |\n" > "$PHASE_DIR/step-2.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x","2":"y"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-26: step-1 ✅ step-2 ❌ → block" "$(run_gate)" "block"

# TC-27: step-1 ✅ step-2 ✅ → block (verification 강제)
printf "| TC-1 | e2e | done now | pass | ✅ |\n" > "$PHASE_DIR/step-2.md"
check "TC-27: step-1 ✅ step-2 ✅ → block (verification 강제)" "$(run_gate)" "block"

# TC-28: step-1 ❌ → block (첫 step 미완료)
printf "| TC-1 | happy | not ok | fail | ❌ |\n" > "$PHASE_DIR/step-1.md"
check "TC-28: step-1 ❌ → block" "$(run_gate)" "block"

# ── 5컬럼 TC 형식 ──

# TC-29: 5컬럼 형식 실제결과 컬럼 위치 확인 ✅ → verification 강제
printf "| TC-1 | happy | scenario description | expected result | ✅ |\n" > "$PHASE_DIR/step-1.md"
rm -f "$PHASE_DIR/step-2.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check "TC-29: 5컬럼 TC ✅ → block (verification 강제)" "$(run_gate)" "block"

# TC-30: 5컬럼 TC-2 결과 ⏸️ → block
printf "| TC-1 | happy | scenario description | expected result | ✅ |\n| TC-2 | e2e | runtime check | correct render | ⏸️ |\n" > "$PHASE_DIR/step-1.md"
check "TC-30: 5컬럼 TC-2 ⏸️ → block" "$(run_gate)" "block"

# ── escalation 카운터 ──
ESC_SID="esc-test-sid"
echo "$ESC_SID" > "$TASK_DIR/.active"
rm -f "$TASK_DIR/.cg-stop-count-$ESC_SID"
mkdir -p "$PHASE_DIR"; rm -f "$PHASE_DIR"/step-*.md
printf "| TC-1 | happy | scenario here | expected here | ❌ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF

# TC-31: 1회차 → 기본 메시지("묻지 마라") + block
check_reason "TC-31: 1회차 escalation 기본 메시지" "$(run_gate "$ESC_SID")" "묻지 마라"

# TC-32: 2회차 → "[2회 차단]"
check_reason "TC-32: 2회차 escalation" "$(run_gate "$ESC_SID")" "[2회 차단]"

# TC-33: 카운터가 10에서 cap — 13회까지 호출해도 decision=block + 최대 경고
for _ in 3 4 5 6 7 8 9 10 11 12 13; do run_gate "$ESC_SID" >/dev/null; done
LAST=$(run_gate "$ESC_SID")
check "TC-33: cap 후에도 block 유지" "$LAST" "block"
check_reason "TC-33b: 10회 cap 한계 메시지" "$LAST" "[10회 차단 — 한계 도달]"
check_reason "TC-33c: cap에서 AskUserQuestion 탈출구 제시" "$LAST" "AskUserQuestion"

# TC-34: 진행 시(블로킹 지점 변경) 카운터 리셋 — cap(10) 상태에서 step-1 ✅ + 신규 step-2 ❌
# → BLOCK_REASON이 step-2로 바뀜 → count 1로 리셋 → 1회차 기본 메시지 복귀
printf "| TC-1 | happy | scenario here | expected here | ✅ |\n" > "$PHASE_DIR/step-1.md"
printf "| TC-1 | happy | second scenario | expected two | ❌ |\n" > "$PHASE_DIR/step-2.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x","2":"y"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check_reason "TC-34: 블로킹 지점 변경 시 카운터 리셋(1회차 복귀)" "$(run_gate "$ESC_SID")" "묻지 마라"
rm -f "$PHASE_DIR/step-2.md"

# TC-35: 신규 세션이 task 재클레임 → 카운터 독립(1회차 기본 메시지)
# completion-gate는 .active owner 세션에만 동작하므로, 새 세션은 .active를 소유해야 한다.
FRESH_SID="fresh-sid-xyz"
echo "$FRESH_SID" > "$TASK_DIR/.active"
rm -f "$TASK_DIR/.cg-stop-count-$FRESH_SID"
printf "| TC-1 | happy | scenario here | expected here | ❌ |\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"dev_phases":{"1":{"name":"test","steps":{"1":"x"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
check_reason "TC-35: 신규 session_id는 카운터 초기화" "$(run_gate "$FRESH_SID")" "묻지 마라"

# TC-36: verification 전환 시 카운터 파일 삭제 (ESC_SID가 task owner여야 reset 도달)
echo "$ESC_SID" > "$TASK_DIR/.active"
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"verification","plan_approved":true,"dev_phases":{},"task_dir":".ai-bouncer-tasks/2026-01-01/test-task","active_file":".ai-bouncer-tasks/2026-01-01/test-task/.active"}
EOF
run_gate "$ESC_SID" >/dev/null
[ ! -f "$TASK_DIR/.cg-stop-count-$ESC_SID" ] && { echo "✅ TC-36: verification 전환 시 카운터 삭제"; PASS=$((PASS+1)); } || { echo "❌ TC-36: 카운터 파일 잔존"; FAIL=$((FAIL+1)); }

# .active 원상복구
touch "$TASK_DIR/.active"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
