#!/bin/bash
# test-bash-gate.sh — bash-gate 종합 단위 테스트

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

# 임시 git repo
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test")
mkdir -p "$TMPDIR/.claude/ai-bouncer"
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
OWNER_SID="bg-owner-sess"
mkdir -p "$TASK_DIR/verifications"
echo "$OWNER_SID" > "$TASK_DIR/.active"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF

run_gate() {
  local cmd="$1" sid="${2:-}"
  # sid 미지정/빈값이면 .active owner로 폴백 (빈 SESSION_ID hijack 방지 후 정상 매칭 유지)
  [ -z "$sid" ] && sid=$(cat "$TASK_DIR/.active" 2>/dev/null | tr -d '[:space:]')
  (cd "$TMPDIR" && jq -n --arg cmd "$cmd" --arg sid "$sid" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

# ── TC-01: session_id 저장 ──
TEST_SID="test-session-12345"
rm -f /tmp/.ai-bouncer-current-session
run_gate "ls" "$TEST_SID" > /dev/null 2>&1 || true
SAVED_SID=$(cat /tmp/.ai-bouncer-current-session 2>/dev/null | tr -d '[:space:]')
if [ "$SAVED_SID" = "$TEST_SID" ]; then
  echo "✅ TC-01: session_id /tmp 저장 확인"; PASS=$((PASS+1))
else
  echo "❌ TC-01: session_id 저장 실패 (expected=$TEST_SID got=$SAVED_SID)"; FAIL=$((FAIL+1))
fi

# ── done 전환 조건 ──

# TC-02: done 전환 + e2e-result.md 없음 → block
rm -f "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"done"} >> state.json' "")
check "TC-02: done 전환 + no e2e-result.md → block" "$OUT" "block"

# TC-03: done 전환 + e2e-result.md 통과 → allow
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"done"} >> state.json' "")
check "TC-03: done 전환 + e2e-result.md 통과 → allow" "$OUT" "allow"

# TC-04: cancelled 전환 → always allow (planning 상태)
rm -f "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_gate 'echo {"workflow_phase":"cancelled"} >> state.json' "")
check "TC-04: cancelled 전환 → always allow (planning)" "$OUT" "allow"

# TC-05: development → cancelled (bash) → block (plan_approved=true)
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"dev_phases":{}}
EOF
OUT=$(run_gate 'echo {"workflow_phase":"cancelled"} >> state.json' "")
check "TC-05: development → cancelled (bash) → block" "$OUT" "block"

# TC-06: rm .active + workflow_phase=development → block
OUT=$(run_gate "rm -f .ai-bouncer-tasks/2026-01-01/test-task/.active" "")
check "TC-06: rm .active + phase=development → block" "$OUT" "block"
echo "$OWNER_SID" > "$TASK_DIR/.active"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF

# ── IS_DELEGATED_AGENT 경로 ──

APPROVED_GLOBAL="/tmp/.ai-bouncer-approved-agents"
ORIG_APPROVED=""
[ -f "$APPROVED_GLOBAL" ] && ORIG_APPROVED=$(cat "$APPROVED_GLOBAL")
restore_approved() { [ -z "$ORIG_APPROVED" ] && rm -f "$APPROVED_GLOBAL" || printf '%s\n' "$ORIG_APPROVED" > "$APPROVED_GLOBAL"; }
trap "rm -rf '$TMPDIR'; restore_approved" EXIT

DELEGATED_SID="delegated-bash-gate-sid-$$"
clear_and_register() {
  : > "$APPROVED_GLOBAL"
  echo "${DELEGATED_SID}|${TASK_DIR}" >> "$APPROVED_GLOBAL"
}

DUMMY_FILE="$TMPDIR/dummy.txt"
touch "$DUMMY_FILE"

run_gate_delegated() {
  (cd "$TMPDIR" && jq -n --arg cmd "echo foo > $DUMMY_FILE" --arg sid "$DELEGATED_SID" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

mkdir -p "$TASK_DIR/phase-1-test"
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
delegated team_name validation
EOF

# TC-10: IS_DELEGATED_AGENT=true + development + team mode + top-level team_name="" → block
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-10: delegated + dev + team + team_name='' → block" "$OUT" "block"

# TC-11: IS_DELEGATED_AGENT=true + development + team mode + team_name="my-team" → allow
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"my-team","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-11: delegated + dev + team + team_name='my-team' → allow" "$OUT" "allow"

# TC-12: IS_DELEGATED_AGENT=true + dev_phase=2 + per-phase team_name="" → block
mkdir -p "$TASK_DIR/phase-2-second"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"first","folder":"phase-1-test","team_name":"team-1"},"2":{"name":"second","folder":"phase-2-second","team_name":""}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-12: delegated + dev_phase=2 + per-phase team_name='' → block" "$OUT" "block"

# TC-13: IS_DELEGATED_AGENT=true + development + subagent mode + team_name="" → allow
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"subagent","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"team_name":"","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"test","folder":"phase-1-test"}}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-13: delegated + dev + subagent mode + team_name='' → allow" "$OUT" "allow"

# TC-14: IS_DELEGATED_AGENT=true + planning phase → allow
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"team_name":"","dev_phases":{}}
EOF
clear_and_register
OUT=$(run_gate_delegated)
check "TC-14: delegated + planning + team_name='' → allow" "$OUT" "allow"

# ── single 모드 gate 검증 ──

cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF
: > "$APPROVED_GLOBAL"

# ── 쓰기 패턴 감지 ──

# TC-20: > 리다이렉트 → IS_WRITE=true → gate 검사
# planning 상태이므로 gate pass (planning → allow)
OUT=$(run_gate "echo hello > /tmp/outfile.txt" "")
check "TC-20: echo > /tmp/ (planning) → allow" "$OUT" "allow"

# TC-21: >> append → IS_WRITE=true
OUT=$(run_gate "echo hello >> /tmp/outfile.txt" "")
check "TC-21: echo >> /tmp/ (planning) → allow" "$OUT" "allow"

# TC-22: tee → IS_WRITE=true
OUT=$(run_gate "cat something | tee /tmp/outfile.txt" "")
check "TC-22: tee /tmp/ → allow" "$OUT" "allow"

# TC-23: sed -i → IS_WRITE=true
OUT=$(run_gate "sed -i 's/x/y/' /tmp/tmpfile.txt" "")
check "TC-23: sed -i /tmp/ → allow" "$OUT" "allow"

# TC-24: cp → IS_WRITE=true
OUT=$(run_gate "cp /tmp/src.txt /tmp/dst.txt" "")
check "TC-24: cp /tmp/→/tmp/ → allow" "$OUT" "allow"

# TC-25: mv → IS_WRITE=true
OUT=$(run_gate "mv /tmp/src.txt /tmp/dst.txt" "")
check "TC-25: mv /tmp/→/tmp/ → allow" "$OUT" "allow"

# TC-26: touch → IS_WRITE=true → /tmp/ 허용
OUT=$(run_gate "touch /tmp/newfile.txt" "")
check "TC-26: touch /tmp/ → allow" "$OUT" "allow"

# TC-27: rm /tmp/ → allow (IS_WRITE + /tmp/ exception)
OUT=$(run_gate "rm /tmp/tmpfile.txt" "")
check "TC-27: rm /tmp/ → allow" "$OUT" "allow"

# TC-28: wget → IS_WRITE=true
# planning 상태이면 gate 검사에서 pass (planning)
OUT=$(run_gate "wget -O /tmp/file.txt http://example.com" "")
check "TC-28: wget to /tmp/ (planning) → allow" "$OUT" "allow"

# TC-29: python3 -c "code" → IS_WRITE 감지 (python은 파일 쓰기 가능) → planning + no-approval → block
OUT=$(run_gate 'python3 -c "import json; print(json.dumps({}))"' "")
check "TC-29: python3 -c 코드 (planning+no-approval) → block" "$OUT" "block"

# TC-30: git status → 쓰기 패턴 없음 → fast exit
OUT=$(run_gate "git status" "")
check "TC-30: git status → allow (fast exit)" "$OUT" "allow"

# TC-31: git add → 쓰기 패턴 없음 → fast exit
OUT=$(run_gate "git add -A" "")
check "TC-31: git add → allow (fast exit)" "$OUT" "allow"

# TC-32: git diff → fast exit
OUT=$(run_gate "git diff HEAD" "")
check "TC-32: git diff → allow (fast exit)" "$OUT" "allow"

# TC-33: git log → fast exit
OUT=$(run_gate "git log --oneline -5" "")
check "TC-33: git log → allow (fast exit)" "$OUT" "allow"

# ── commit_strategy 검증 ──

PHASE_DIR_CS="$TASK_DIR/phase-1-cs"
mkdir -p "$PHASE_DIR_CS"

# TC-40: commit_strategy=per-step + step ✅ 있음 → allow
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"per-step"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"cs","folder":"phase-1-cs","steps":{"1":{"title":"s1"}},"team_name":""}}}
EOF
printf "## TC\n| TC-1 | happy | ok test | pass | \`echo x\` | ✅ |\n\n## 실행출력\n결과줄1\n결과줄2\n" > "$PHASE_DIR_CS/step-1.md"
OUT=$(run_gate "git commit -m 'feat: step done'" "")
check "TC-40: per-step + step ✅ → allow commit" "$OUT" "allow"

# TC-41: commit_strategy=per-step + step ❌ → block
printf "## TC\n| TC-1 | happy | ok test | pass | \`echo x\` | ❌ |\n" > "$PHASE_DIR_CS/step-1.md"
OUT=$(run_gate "git commit -m 'feat: step done'" "")
check "TC-41: per-step + step ❌ → block commit" "$OUT" "block"

# TC-42: commit_strategy=per-phase + 마지막 step ✅ → allow
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"per-phase"}
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"cs","folder":"phase-1-cs","steps":{"1":{"title":"s1"},"2":{"title":"s2"}},"team_name":""}}}
EOF
printf "## TC\n| TC-1 | happy | ok test | pass | \`echo x\` | ✅ |\n\n## 실행출력\n결과줄1\n결과줄2\n" > "$PHASE_DIR_CS/step-1.md"
printf "## TC\n| TC-1 | happy | ok test | pass | \`echo x\` | ✅ |\n\n## 실행출력\n결과줄1\n결과줄2\n" > "$PHASE_DIR_CS/step-2.md"
OUT=$(run_gate "git commit -m 'feat: phase done'" "")
check "TC-42: per-phase + 마지막 step ✅ → allow commit" "$OUT" "allow"

# TC-43: commit_strategy=per-phase + 마지막 step ❌ → block
printf "## TC\n| TC-1 | happy | ok test | pass | \`echo x\` | ❌ |\n" > "$PHASE_DIR_CS/step-2.md"
OUT=$(run_gate "git commit -m 'feat: phase done'" "")
check "TC-43: per-phase + 마지막 step ❌ → block commit" "$OUT" "block"

# TC-44: commit_strategy=none → 항상 block
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"none"}
EOF
OUT=$(run_gate "git commit -m 'feat: test'" "")
check "TC-44: commit_strategy=none → block" "$OUT" "block"

# TC-45: done 상태 → commit 항상 허용
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"done","plan_approved":true,"dev_phases":{}}
EOF
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"per-step"}
EOF
OUT=$(run_gate "git commit -m 'feat: done state'" "")
check "TC-45: done 상태 → commit allow" "$OUT" "allow"

# TC-46: git push → commit과 동일 조건 (done 상태 → allow)
OUT=$(run_gate "git push origin main" "")
check "TC-46: git push + done 상태 → allow" "$OUT" "allow"

# ── .active 삭제 제어 ──

# TC-50: rm .active + done 상태 → allow
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"done","plan_approved":true,"dev_phases":{}}
EOF
OUT=$(run_gate "rm -f .ai-bouncer-tasks/2026-01-01/test-task/.active" "")
check "TC-50: rm .active + done → allow" "$OUT" "allow"
echo "$OWNER_SID" > "$TASK_DIR/.active"

# TC-51: rm .active + cancelled 상태 → allow
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"cancelled","plan_approved":false,"dev_phases":{}}
EOF
OUT=$(run_gate "rm -f .ai-bouncer-tasks/2026-01-01/test-task/.active" "")
check "TC-51: rm .active + cancelled → allow" "$OUT" "allow"
echo "$OWNER_SID" > "$TASK_DIR/.active"

# TC-52: rm .active + verification 상태 → block
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"verification","plan_approved":true,"dev_phases":{}}
EOF
OUT=$(run_gate "rm -f .ai-bouncer-tasks/2026-01-01/test-task/.active" "")
check "TC-52: rm .active + verification → block" "$OUT" "block"
echo "$OWNER_SID" > "$TASK_DIR/.active"

# ── verifications/ 접근 제어 ──

# TC-60: development + verifications/ 에 > 리다이렉트 → block
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"cs","folder":"phase-1-cs","steps":{"1":{}},"team_name":""}}}
EOF
OUT=$(run_gate "echo result > .ai-bouncer-tasks/2026-01-01/test-task/verifications/e2e-result.md" "")
check "TC-60: development + verifications/ 쓰기 → block" "$OUT" "block"

# TC-61: verification + verifications/ 에 > 리다이렉트 → gate pass
# CHECK 6.8: 모든 step-*.md에 ✅ 필요. CHECK 7a: phase.md + 필수 섹션 필요.
printf "## 목표\n테스트\n## 기술 접근\n- 변경없음\n## Steps\n- Step 1: 테스트 단계\n" > "$PHASE_DIR_CS/phase.md"
printf "## TC\n| TC-1 | happy | ok scenario | expected ok | \`echo x\` | ✅ |\n\n## 실행출력\n결과줄1\n결과줄2\n" > "$PHASE_DIR_CS/step-1.md"
printf "## TC\n| TC-1 | happy | ok scenario | expected ok | \`echo x\` | ✅ |\n\n## 실행출력\n결과줄1\n결과줄2\n" > "$PHASE_DIR_CS/step-2.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"verification","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"cs","folder":"phase-1-cs","steps":{"1":{},"2":{}},"team_name":""}}}
EOF
OUT=$(run_gate "echo result > .ai-bouncer-tasks/2026-01-01/test-task/verifications/e2e-result.md" "")
check "TC-61: verification + verifications/ 쓰기 → allow" "$OUT" "allow"

# ── .ai-bouncer-tasks/ 스크립트 실행 금지 ──

# TC-70: python3 스크립트 .ai-bouncer-tasks/ 내부 실행 → block
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF
OUT=$(run_gate "python3 .ai-bouncer-tasks/2026-01-01/test-task/phase-1/setup.py" "")
check "TC-70: .ai-bouncer-tasks/ 내부 py 스크립트 실행 → block" "$OUT" "block"

# TC-71: bash 스크립트 .ai-bouncer-tasks/ 내부 실행 → block
OUT=$(run_gate "bash .ai-bouncer-tasks/2026-01-01/test-task/run.sh" "")
check "TC-71: .ai-bouncer-tasks/ 내부 sh 스크립트 실행 → block" "$OUT" "block"

# ── ~/.claude/ 예외 경로 ──

# TC-80: ~/.claude/ 경로 쓰기 → always allow
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"t","folder":"phase-1-cs","steps":{"1":{}},"team_name":""}}}
EOF
OUT=$(run_gate "echo x > $HOME/.claude/test.log" "")
check "TC-80: ~/.claude/ 경로 → always allow" "$OUT" "allow"

# TC-81: plan.md 쓰기 → allow (gate exception)
OUT=$(run_gate "echo plan > .ai-bouncer-tasks/2026-01-01/test-task/plan.md" "")
check "TC-81: plan.md 쓰기 → allow" "$OUT" "allow"

# TC-82: step-1.md 쓰기 → allow (gate exception)
OUT=$(run_gate "echo step > .ai-bouncer-tasks/2026-01-01/test-task/phase-1-cs/step-1.md" "")
check "TC-82: step-1.md 쓰기 → allow" "$OUT" "allow"

# TC-83: phase-1.md 쓰기 → allow (gate exception)
OUT=$(run_gate "echo phase > .ai-bouncer-tasks/2026-01-01/test-task/phase-1-cs/phase-1.md" "")
check "TC-83: phase-*.md 쓰기 → allow" "$OUT" "allow"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
