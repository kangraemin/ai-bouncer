#!/bin/bash
# test-e2e-workflow.sh — 전체 워크플로우 E2E 시뮬레이션
# planning → development → verification → done 흐름을 hook 관점에서 검증
# bash-gate / plan-gate / completion-gate 를 실제 순서로 호출

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"
PASS=0; FAIL=0

check() {
  local label="$1" output="$2" expected="$3"
  local actual
  if [ -z "$output" ]; then actual="allow"; else
    actual=$(echo "$output" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  fi
  if [ "$actual" = "$expected" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (expected=$expected got=$actual)"; echo "   output: $output"; FAIL=$((FAIL+1))
  fi
}

check_stop() {
  local label="$1" output="$2" expected="$3"
  local actual
  if [ -z "$output" ]; then
    actual="continue"
  else
    actual=$(echo "$output" | jq -r '.decision // "continue"' 2>/dev/null || echo "continue")
    [ -z "$actual" ] && actual="continue"
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
(cd "$TMPDIR" && git init -q && git config user.email "t@t.com" && git config user.name "T")
mkdir -p "$TMPDIR/.claude/ai-bouncer"
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"per-step"}
EOF

TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/e2e-test"
OWNER_SID="e2e-owner-sess"
mkdir -p "$TASK_DIR/verifications"

# 헬퍼 함수
run_plan() {
  local file="$1" sid="${2:-}" content="${3:-x}"
  [ -z "$sid" ] && sid="$OWNER_SID"
  (cd "$TMPDIR" && jq -n --arg file "$file" --arg sid "$sid" --arg content "$content" \
    '{"tool_name":"Write","session_id":$sid,"tool_input":{"file_path":$file,"content":$content}}' \
    | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}

run_bash() {
  local cmd="$1" sid="${2:-}"
  [ -z "$sid" ] && sid="$OWNER_SID"
  (cd "$TMPDIR" && jq -n --arg cmd "$cmd" --arg sid "$sid" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}

run_stop() {
  local sid="${1:-}"
  [ -z "$sid" ] && sid="$OWNER_SID"
  (cd "$TMPDIR" && jq -n --arg sid "$sid" \
    '{"session_id":$sid}' \
    | bash "$HOOKS_DIR/completion-gate.sh" 2>/dev/null) || true
}

# ===== SCENARIO A: planning 단계 — 아직 plan 없음 =====
echo ""
echo "=== SCENARIO A: Planning 단계 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF
echo "$OWNER_SID" > "$TASK_DIR/.active"

# A-01: planning + 소스코드 수정 → block (plan 없음)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "A-01: planning + source write → block (no plan)" "$OUT" "block"

# A-02: planning + state.json 수정 → allow (gate exception)
OUT=$(run_plan "$TASK_DIR/state.json" "")
check "A-02: planning + state.json write → allow" "$OUT" "allow"

# A-03: planning + plan.md 작성 → allow (bootstrap)
OUT=$(run_plan "$TASK_DIR/plan.md" "")
check "A-03: planning + plan.md write → allow (bootstrap)" "$OUT" "allow"

# A-04: planning + bash echo → allow (planning 상태)
OUT=$(run_bash "echo hello" "")
check "A-04: planning + bash echo → allow" "$OUT" "allow"

# A-05: planning + bash ls → allow (fast exit)
OUT=$(run_bash "ls -la" "")
check "A-05: planning + bash ls → allow (fast exit)" "$OUT" "allow"

# A-06: stop hook → planning 단계 → continue (completion-gate는 planning 상태에서 항상 통과)
OUT=$(run_stop "")
check_stop "A-06: stop + planning → continue (gate skips planning state)" "$OUT" "continue"

# A-07: planning + plan 승인 → still continue (gate only checks dev/verification)
cat > "$TASK_DIR/plan.md" <<'EOF'
# Plan
## 목표
테스트 계획

## 개발 Phase 계획
### Phase 1: 구현
- Step 1: 기능 구현 — 완료 기준: 테스트 통과
EOF
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":true,"dev_phases":{}}
EOF
OUT=$(run_stop "")
check_stop "A-07: stop + planning (approved) → continue" "$OUT" "continue"

# ===== SCENARIO B: development 시작 — Phase 1 Step 1 =====
echo ""
echo "=== SCENARIO B: Development Phase 1 Step 1 ==="

PHASE_DIR="$TASK_DIR/phase-1-impl"
mkdir -p "$PHASE_DIR"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{"title":"기능구현"}},"team_name":""}}}
EOF

# B-01: dev + phase.md 없음 → block (7a)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "B-01: dev + no phase.md → block (7a)" "$OUT" "block"

# B-02: dev + phase.md 작성 → allow (bootstrap)
OUT=$(run_plan "$PHASE_DIR/phase.md" "")
check "B-02: dev + phase.md write → allow (bootstrap)" "$OUT" "allow"

printf "## 목표\n구현 목표\n## 기술 접근\n- app.py: 없음 → 기능 추가\n## Steps\n- Step 1: 기능 구현 — 테스트 통과\n" > "$PHASE_DIR/phase.md"

# B-03: dev + phase.md OK + step.md 없음 → block (7d)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "B-03: dev + no step.md → block (7d)" "$OUT" "block"

# B-04: dev + step.md 작성 → allow (bootstrap)
OUT=$(run_plan "$PHASE_DIR/step-1.md" "")
check "B-04: dev + step.md write → allow (bootstrap)" "$OUT" "allow"

printf "## 구현 목표\n- 변경 대상: app.py\n\n## 테스트 기준\n\n| TC-ID | 유형 | 시나리오 | 기대 결과 | 실제 결과 |\n|-------|------|----------|-----------|-----------||\n| TC-1  |      |          |           |           |\n" > "$PHASE_DIR/step-1.md"

# B-05: dev + TC 없음 (placeholder만) → block (7e)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "B-05: dev + TC placeholder only → block (7e)" "$OUT" "block"

# B-06: dev + TC 작성 (시나리오 너무 짧음) → block (7e-2)
printf "## TC\n| TC-1 | ok | abc | xy | \`cmd\` |  |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "B-06: dev + TC too short → block (7e-2)" "$OUT" "block"

# B-07: dev + TC 작성 (정상) → allow
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` |  |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "B-07: dev + TC OK → allow source write" "$OUT" "allow"

# B-08: dev + bash write → allow (TC OK, gate passes)
OUT=$(run_bash "echo code > $TMPDIR/src/app.py" "")
check "B-08: dev + bash write source → allow" "$OUT" "allow"

# B-09: stop + TC 없이 → block (completion-gate)
OUT=$(run_stop "")
check_stop "B-09: stop + TC no result → block" "$OUT" "block"

# B-10: dev + 실행출력 없이 step 완료 표시 → stop block
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` | ✅ |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_stop "")
check_stop "B-10: stop + ✅ but no 실행출력 → block" "$OUT" "block"

# B-11: dev + 실행출력 1줄만 → stop block
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` | ✅ |\n\n## 실행출력\n한 줄만\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_stop "")
check_stop "B-11: stop + 1-line 실행출력 → block" "$OUT" "block"

# B-12: dev + 실행출력 2줄 → stop blocks (all done → forces verification transition)
# completion-gate: 모든 step ✅이면 "verification으로 전환하세요" block (not continue)
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_stop "")
check_stop "B-12: stop + step ✅ + 2-line 출력 → block (go-to-verification)" "$OUT" "block"

# ===== SCENARIO C: Phase 1 Step 2 =====
echo ""
echo "=== SCENARIO C: Development Phase 1 Step 2 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{"title":"1단계"},"2":{"title":"2단계"}},"team_name":""}}}
EOF

# C-01: step2 + step1 ✅ 없음 → block (7c)
printf "## TC\n| TC-1 | happy | scenario ok | result ok | \`cmd\` |  |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_plan "$TMPDIR/src/feature.py" "")
check "C-01: step2 + prev step no ✅ → block (7c)" "$OUT" "block"

# C-02: step2 + step1 ✅ 있음 + 실행출력 없음 → block (7c-2)
printf "## TC\n| TC-1 | happy | scenario ok | result ok | \`cmd\` | ✅ |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_plan "$TMPDIR/src/feature.py" "")
check "C-02: step2 + prev ✅ + no 실행출력 → block (7c-2)" "$OUT" "block"

# C-03: step2 + step1 ✅ + 실행출력 OK + step2.md 없음 → block (7d)
printf "## TC\n| TC-1 | happy | scenario ok | result ok | \`cmd\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_plan "$TMPDIR/src/feature.py" "")
check "C-03: step2 + step1 ok + no step2.md → block (7d)" "$OUT" "block"

# C-04: step2 + step2.md 없음 → allow (bootstrap)
OUT=$(run_plan "$PHASE_DIR/step-2.md" "")
check "C-04: step2.md write → allow (bootstrap)" "$OUT" "allow"

printf "## TC\n| TC-1 | happy | scenario 2 ok | result 2 ok | \`echo step2\` |  |\n" > "$PHASE_DIR/step-2.md"

# C-05: step2 + step2.md OK → allow source
OUT=$(run_plan "$TMPDIR/src/feature.py" "")
check "C-05: step2 + step2.md TC OK → allow source" "$OUT" "allow"

# C-06: phase 1 step 2 완료 → stop blocks (all done → verification 전환 강제)
printf "## TC\n| TC-1 | happy | scenario 2 ok | result 2 ok | \`echo step2\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-2.md"
OUT=$(run_stop "")
check_stop "C-06: stop + step2 ✅ → block (go-to-verification)" "$OUT" "block"

# ===== SCENARIO D: Phase 2 (2-phase 순차) =====
echo ""
echo "=== SCENARIO D: Development Phase 2 (순차) ==="

PHASE2_DIR="$TASK_DIR/phase-2-test"
mkdir -p "$PHASE2_DIR"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{},"2":{}},"team_name":""},"2":{"name":"test","folder":"phase-2-test","steps":{"1":{}},"team_name":""}}}
EOF

# D-01: phase2 + phase1 모든 step ✅ → allow
OUT=$(run_plan "$PHASE2_DIR/phase.md" "")
check "D-01: phase2 + phase1 완료 → allow (bootstrap)" "$OUT" "allow"

# D-02: phase2 + phase1 step 미완료 → block (source file write blocked)
printf "## TC\n| TC-1 | happy | scenario | expected | \`cmd\` |  |\n" > "$PHASE_DIR/step-2.md"
OUT=$(run_plan "$TMPDIR/src/test_app.py" "")
check "D-02: phase2 + phase1 step❌ → block (7-PHASE)" "$OUT" "block"

# step-2.md 복원
printf "## TC\n| TC-1 | happy | scenario 2 ok | result 2 ok | \`echo step2\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-2.md"

printf "## 목표\n테스트 목표\n## 기술 접근\n- test.py: 없음 → 테스트 추가\n## Steps\n- Step 1: 테스트 작성 — 완료기준: 통과\n" > "$PHASE2_DIR/phase.md"
printf "## TC\n| TC-1 | happy | test scenario | test result ok | \`pytest test.py\` |  |\n" > "$PHASE2_DIR/step-1.md"

# D-03: phase2 + TC OK → allow source
OUT=$(run_plan "$TMPDIR/tests/test_app.py" "")
check "D-03: phase2 + TC OK → allow source write" "$OUT" "allow"

# D-04: phase2 step1 완료 → stop blocks (all phases done → verification 전환)
printf "## TC\n| TC-1 | happy | test scenario | test result ok | \`pytest test.py\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE2_DIR/step-1.md"
OUT=$(run_stop "")
check_stop "D-04: stop + phase2 step1 ✅ → block (go-to-verification)" "$OUT" "block"

# ===== SCENARIO E: verification 단계 =====
echo ""
echo "=== SCENARIO E: Verification 단계 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"verification","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":2,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{},"2":{}},"team_name":""},"2":{"name":"test","folder":"phase-2-test","steps":{"1":{}},"team_name":""}}}
EOF

# E-01: verification + e2e-result.md 없음 → stop block
OUT=$(run_stop "")
check_stop "E-01: verification + no e2e-result.md → block" "$OUT" "block"

# E-02: verification + e2e-result.md 포맷 틀림 → block
printf "## 결론\n실패\n" > "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_stop "")
check_stop "E-02: verification + e2e 실패 → block" "$OUT" "block"

# E-03: verification + e2e 통과 → continue (completion-gate exits 0 silently)
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
OUT=$(run_stop "")
check_stop "E-03: verification + e2e pass → continue (silent exit)" "$OUT" "continue"

# E-04: verification + verifications/ 쓰기 → allow
OUT=$(run_bash "echo result > $TASK_DIR/verifications/e2e-result.md" "")
check "E-04: verification + verifications/ bash write → allow" "$OUT" "allow"

# E-05: verification + 소스 수정 → allow (plan-gate은 verification에서 소스 파일을 차단하지 않음)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "E-05: verification + source write → allow (no block in verification)" "$OUT" "allow"

# E-06: verification + state.json 수정 → allow (exception)
OUT=$(run_plan "$TASK_DIR/state.json" "")
check "E-06: verification + state.json write → allow" "$OUT" "allow"

# E-07: verification + phase1 step 미완료 상태 → bash-gate block
printf "## TC\n| TC-1 | happy | scenario | expected | \`cmd\` |  |\n" > "$PHASE_DIR/step-1.md"
OUT=$(run_bash "echo result > $TASK_DIR/verifications/e2e-result.md" "")
check "E-07: verification + phase step ❌ → bash block" "$OUT" "block"

# 복원
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-1.md"

# ===== SCENARIO F: done 단계 =====
echo ""
echo "=== SCENARIO F: Done 단계 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"done","plan_approved":true,"dev_phases":{}}
EOF
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"

# F-01: done + stop → continue
OUT=$(run_stop "")
check_stop "F-01: done + stop → continue" "$OUT" "continue"

# F-02: done + source write → allow
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "F-02: done + source write → allow" "$OUT" "allow"

# F-03: done + bash write → allow
OUT=$(run_bash "echo x > $TMPDIR/output.txt" "")
check "F-03: done + bash write → allow" "$OUT" "allow"

# F-04: done + git commit → allow
OUT=$(run_bash "git commit -m 'feat: done'" "")
check "F-04: done + git commit → allow" "$OUT" "allow"

# ===== SCENARIO G: cancelled 단계 =====
echo ""
echo "=== SCENARIO G: Cancelled 단계 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"cancelled","plan_approved":false,"dev_phases":{}}
EOF

# G-01: cancelled + stop → continue
OUT=$(run_stop "")
check_stop "G-01: cancelled + stop → continue" "$OUT" "continue"

# G-02: cancelled + source write → allow
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "G-02: cancelled + source write → allow" "$OUT" "allow"

# ===== SCENARIO H: no .active file =====
echo ""
echo "=== SCENARIO H: .active 없음 ==="

rm -f "$TASK_DIR/.active"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"dev_phases":{}}
EOF

# H-01: .active 없음 → plan gate allow
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "H-01: no .active → plan gate allow" "$OUT" "allow"

# H-02: .active 없음 → bash gate allow
OUT=$(run_bash "echo x > $TMPDIR/file.txt" "")
check "H-02: no .active → bash gate allow" "$OUT" "allow"

# H-03: .active 없음 → stop allow
OUT=$(run_stop "")
check_stop "H-03: no .active → stop continue" "$OUT" "continue"

echo "$OWNER_SID" > "$TASK_DIR/.active"

# ===== SCENARIO I: 전환 - state.json workflow_phase 갱신 =====
echo ""
echo "=== SCENARIO I: workflow_phase 전환 제어 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` |  |\n" > "$PHASE_DIR/step-1.md"

# I-01: development → verification 전환 (bash echo to state.json) → allow (exception)
OUT=$(run_bash "echo '{\"workflow_phase\":\"verification\"}' > $TASK_DIR/state.json" "")
check "I-01: development → verification (bash state.json) → allow" "$OUT" "allow"

# I-02: development → done 전환 (bash-gate) → allow (bash-gate는 done 전환 미검증)
# done 전환 차단은 plan-gate CHECK 1.6d (Write tool)에서만 수행함
rm -f "$TASK_DIR/verifications/e2e-result.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF
OUT=$(run_bash "echo '{\"workflow_phase\":\"done\"}' >> $TASK_DIR/state.json" "")
check "I-02: development → done bash (no e2e) → allow (bash-gate 미검증)" "$OUT" "allow"

# I-03: plan-gate(Write)로 done 전환 + e2e-result.md 없음 → block
# plan-gate CHECK 1.6d는 done 전환 시 e2e-result.md 통과 확인
rm -f "$TASK_DIR/verifications/e2e-result.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF
DONE_CONTENT='{"workflow_phase":"done","plan_approved":true,"resolved_agent_mode":"single","dev_phases":{}}'
OUT=$(run_plan "$TASK_DIR/state.json" "" "$DONE_CONTENT")
check "I-03: plan-gate done (no e2e-result) → block (CHECK 1.6d)" "$OUT" "block"

# I-04: plan-gate done 전환 + e2e 통과 + all steps ✅ → allow
printf "## 결론\n통과\n" > "$TASK_DIR/verifications/e2e-result.md"
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` | ✅ |\n\n## 실행출력\n줄1\n줄2\n" > "$PHASE_DIR/step-1.md"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF
OUT=$(run_plan "$TASK_DIR/state.json" "" "$DONE_CONTENT")
check "I-04: plan-gate done (e2e pass + all steps ✅) → allow" "$OUT" "allow"

# I-05: development → cancelled 전환 (dev 상태) → block
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","dev_phases":{}}
EOF
OUT=$(run_bash "echo '{\"workflow_phase\":\"cancelled\"}' >> $TASK_DIR/state.json" "")
check "I-05: development → cancelled (bash) → block" "$OUT" "block"

# ===== SCENARIO J: 멀티 step 경계 검증 =====
echo ""
echo "=== SCENARIO J: Multi-step 경계 ==="

PHASE_J="$TASK_DIR/phase-1-multi"
mkdir -p "$PHASE_J"
printf "## 목표\n멀티스텝\n## 기술 접근\n- main.py: 기능 추가\n## Steps\n- Step 1\n- Step 2\n- Step 3\n" > "$PHASE_J/phase.md"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"multi","folder":"phase-1-multi","steps":{"1":{},"2":{},"3":{}},"team_name":""}}}
EOF

# J-01: step1 → step 파일 없음 → block
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-01: step1 + no step1.md → block (7d)" "$OUT" "block"

printf "## TC\n| TC-1 | happy | step 1 scenario | step 1 expected | \`cmd1\` |  |\n" > "$PHASE_J/step-1.md"

# J-02: step1 TC OK → allow
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-02: step1 TC OK → allow" "$OUT" "allow"

# step1 완료
printf "## TC\n| TC-1 | happy | step 1 scenario | step 1 expected | \`cmd1\` | ✅ |\n\n## 실행출력\n출력줄1\n출력줄2\n" > "$PHASE_J/step-1.md"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":2,"dev_phases":{"1":{"name":"multi","folder":"phase-1-multi","steps":{"1":{},"2":{},"3":{}},"team_name":""}}}
EOF

# J-03: step2 → step2.md 없음 → block
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-03: step2 + no step2.md → block (7d)" "$OUT" "block"

printf "## TC\n| TC-1 | happy | step 2 scenario | step 2 expected | \`cmd2\` |  |\n" > "$PHASE_J/step-2.md"

# J-04: step2 TC OK → allow
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-04: step2 TC OK → allow" "$OUT" "allow"

printf "## TC\n| TC-1 | happy | step 2 scenario | step 2 expected | \`cmd2\` | ✅ |\n\n## 실행출력\n출력줄1\n출력줄2\n" > "$PHASE_J/step-2.md"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":3,"dev_phases":{"1":{"name":"multi","folder":"phase-1-multi","steps":{"1":{},"2":{},"3":{}},"team_name":""}}}
EOF

printf "## TC\n| TC-1 | happy | step 3 scenario | step 3 expected | \`cmd3\` |  |\n" > "$PHASE_J/step-3.md"

# J-05: step3 TC OK → allow
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-05: step3 TC OK → allow" "$OUT" "allow"

# J-06: step3 완료 → stop continue
printf "## TC\n| TC-1 | happy | step 3 scenario | step 3 expected | \`cmd3\` | ✅ |\n\n## 실행출력\n출력줄1\n출력줄2\n" > "$PHASE_J/step-3.md"
OUT=$(run_stop "")
check_stop "J-06: all 3 steps ✅ → block (go-to-verification)" "$OUT" "block"

# J-07: step overflow (step=4 but only 3 defined) → plan-gate block
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":4,"dev_phases":{"1":{"name":"multi","folder":"phase-1-multi","steps":{"1":{},"2":{},"3":{}},"team_name":""}}}
EOF
OUT=$(run_plan "$TMPDIR/src/main.py" "")
check "J-07: step overflow (step=4, max=3) → block" "$OUT" "block"

# ===== SCENARIO K: 예외 경로 (항상 허용) =====
echo ""
echo "=== SCENARIO K: 예외 경로 ==="

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF
printf "## TC\n| TC-1 | happy | correct scenario | expected result | \`echo test\` |  |\n" > "$PHASE_DIR/step-1.md"

# K-01: .ai-bouncer-tasks/ 내 .md (plan.md) → allow
OUT=$(run_plan "$TASK_DIR/plan.md" "")
check "K-01: task plan.md write → allow" "$OUT" "allow"

# K-02: .ai-bouncer-tasks/ 내 step-1.md → allow
OUT=$(run_plan "$PHASE_DIR/step-1.md" "")
check "K-02: task step-1.md write → allow" "$OUT" "allow"

# K-03: .ai-bouncer-tasks/ 내 phase.md → allow
OUT=$(run_plan "$PHASE_DIR/phase.md" "")
check "K-03: task phase.md write → allow" "$OUT" "allow"

# K-04: ~/.claude/ 내 파일 → always allow
OUT=$(run_bash "echo log >> $HOME/.claude/worklog.txt" "")
check "K-04: ~/.claude/ bash write → allow" "$OUT" "allow"

# K-05: /tmp/ bash write → always allow
OUT=$(run_bash "echo tmp > /tmp/bouncer-test-$$.txt" "")
check "K-05: /tmp/ bash write → allow" "$OUT" "allow"

# K-06: mktemp → allow
OUT=$(run_bash "F=\$(mktemp); echo x > \$F" "")
check "K-06: mktemp write → allow" "$OUT" "allow"

# K-07: rm /tmp/ → allow
OUT=$(run_bash "rm -f /tmp/bouncer-test-$$.txt" "")
check "K-07: rm /tmp/ → allow" "$OUT" "allow"

# K-08: git read commands → fast exit allow
for gcmd in "git status" "git log -5" "git diff HEAD" "git branch" "git show HEAD"; do
  OUT=$(run_bash "$gcmd" "")
  check "K-08: $gcmd → allow" "$OUT" "allow"
done

# ===== SCENARIO L: plan-gate 검증 섹션 =====
echo ""
echo "=== SCENARIO L: plan.md / phase.md 필수 섹션 ==="

PHASE_L="$TASK_DIR/phase-1-section"
mkdir -p "$PHASE_L"

cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"section","folder":"phase-1-section","steps":{"1":{}},"team_name":""}}}
EOF

# L-01: phase.md 목표 섹션 없음 → block
printf "## 기술 접근\n- 없음\n## Steps\n- Step 1\n" > "$PHASE_L/phase.md"
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "L-01: phase.md without 목표 → block" "$OUT" "block"

# L-02: phase.md 기술접근 섹션 없음 → block
printf "## 목표\n구현\n## Steps\n- Step 1\n" > "$PHASE_L/phase.md"
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "L-02: phase.md without 기술 접근 → block" "$OUT" "block"

# L-03: phase.md Steps 섹션 없음 → block
printf "## 목표\n구현\n## 기술 접근\n- 없음\n" > "$PHASE_L/phase.md"
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "L-03: phase.md without Steps → block" "$OUT" "block"

# L-04: phase.md 모든 섹션 있음 → 다음 체크로
printf "## 목표\n구현\n## 기술 접근\n- 없음\n## Steps\n- Step 1\n" > "$PHASE_L/phase.md"
# step-1.md TC 필요 → block (TC 없음)
OUT=$(run_plan "$TMPDIR/src/app.py" "")
check "L-04: phase.md OK + no step.md → block (7d)" "$OUT" "block"

# ===== SCENARIO M: 완전한 단일 Phase 워크플로우 =====
echo ""
echo "=== SCENARIO M: 완전한 Single-phase 워크플로우 (처음~끝) ==="

TMPDIR2=$(mktemp -d)
trap "rm -rf '$TMPDIR' '$TMPDIR2'" EXIT
(cd "$TMPDIR2" && git init -q && git config user.email "t@t.com" && git config user.name "T")
mkdir -p "$TMPDIR2/.claude/ai-bouncer"
cat > "$TMPDIR2/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"single","commit_strategy":"per-step"}
EOF

TASK2="$TMPDIR2/.ai-bouncer-tasks/2026-01-01/full-flow"
OWNER_SID2="e2e-owner-sess2"
mkdir -p "$TASK2/verifications"
echo "$OWNER_SID2" > "$TASK2/.active"

run_plan2() {
  local file="$1"
  (cd "$TMPDIR2" && jq -n --arg file "$file" --arg sid "$OWNER_SID2" \
    '{"tool_name":"Write","session_id":$sid,"tool_input":{"file_path":$file,"content":"x"}}' \
    | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null) || true
}
run_bash2() {
  local cmd="$1"
  (cd "$TMPDIR2" && jq -n --arg cmd "$cmd" --arg sid "$OWNER_SID2" \
    '{"tool_name":"Bash","session_id":$sid,"tool_input":{"command":$cmd}}' \
    | bash "$HOOKS_DIR/bash-gate.sh" 2>/dev/null) || true
}
run_stop2() {
  (cd "$TMPDIR2" && jq -n --arg sid "$OWNER_SID2" '{"session_id":$sid}' \
    | bash "$HOOKS_DIR/completion-gate.sh" 2>/dev/null) || true
}

# M-01: 초기 상태 — plan_approved=false → block source, stop block
cat > "$TASK2/state.json" <<'EOF'
{"workflow_phase":"planning","plan_approved":false,"dev_phases":{}}
EOF
OUT=$(run_plan2 "$TMPDIR2/src/app.py"); check "M-01: initial planning → source block" "$OUT" "block"
OUT=$(run_stop2); check_stop "M-02: initial planning → stop continue (gate skips planning)" "$OUT" "continue"

# M-03: plan 작성 (bootstrap)
OUT=$(run_plan2 "$TASK2/plan.md"); check "M-03: plan.md write → allow" "$OUT" "allow"

# M-04: plan 승인 → state.json 업데이트 → allow (exception)
cat > "$TASK2/plan.md" <<'EOF'
# Plan
## 목표
풀 플로우 테스트
## 개발 Phase 계획
### Phase 1: 구현
- Step 1: 코드 작성
EOF
cat > "$TASK2/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF

PH2="$TASK2/phase-1-impl"; mkdir -p "$PH2"

# M-05: dev 시작 — phase.md 없음 → block
OUT=$(run_plan2 "$TMPDIR2/src/app.py"); check "M-05: dev + no phase.md → block" "$OUT" "block"

# M-06: phase.md 작성 (bootstrap)
OUT=$(run_plan2 "$PH2/phase.md"); check "M-06: phase.md bootstrap → allow" "$OUT" "allow"
printf "## 목표\n기능 구현\n## 기술 접근\n- app.py: 없음 → 기능 추가\n## Steps\n- Step 1: 코드 작성\n" > "$PH2/phase.md"

# M-07: step.md 없음 → block
OUT=$(run_plan2 "$TMPDIR2/src/app.py"); check "M-07: dev + no step1.md → block" "$OUT" "block"

# M-08: step.md 작성 (bootstrap)
OUT=$(run_plan2 "$PH2/step-1.md"); check "M-08: step1.md bootstrap → allow" "$OUT" "allow"
printf "## TC\n| TC-1 | happy | app feature exists | returns 200 status | \`curl localhost\` |  |\n" > "$PH2/step-1.md"

# M-09: TC OK → allow source
OUT=$(run_plan2 "$TMPDIR2/src/app.py"); check "M-09: TC OK → allow source" "$OUT" "allow"
OUT=$(run_bash2 "echo 'def app(): pass' > $TMPDIR2/src/app.py"); check "M-10: bash write → allow" "$OUT" "allow"

# M-11: 미완료 → stop block
OUT=$(run_stop2); check_stop "M-11: step TC not done → stop block" "$OUT" "block"

# M-12: TC 완료 마킹 + 실행출력 → stop blocks (all done → verification 전환 강제)
printf "## TC\n| TC-1 | happy | app feature exists | returns 200 status | \`curl localhost\` | ✅ |\n\n## 실행출력\nHTTP/1.1 200 OK\nContent-Type: application/json\n" > "$PH2/step-1.md"
OUT=$(run_stop2); check_stop "M-12: step ✅ + 실행출력 → block (go-to-verification)" "$OUT" "block"

# M-13: verification 전환
cat > "$TASK2/state.json" <<'EOF'
{"workflow_phase":"verification","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"impl","folder":"phase-1-impl","steps":{"1":{}},"team_name":""}}}
EOF

# M-14: e2e 결과 없음 → stop block
OUT=$(run_stop2); check_stop "M-14: verification + no e2e → stop block" "$OUT" "block"

# M-15: e2e 작성 → allow (verifications/ 경로)
OUT=$(run_bash2 "echo ok > $TASK2/verifications/e2e-result.md"); check "M-15: bash e2e write → allow" "$OUT" "allow"
printf "## 결론\n통과\n" > "$TASK2/verifications/e2e-result.md"

# M-16: e2e 통과 → stop continue (completion-gate exits 0 silently)
OUT=$(run_stop2); check_stop "M-16: verification + e2e pass → continue (silent exit)" "$OUT" "continue"

# M-17: done 전환 → continue (e2e-result.md 있음 필수)
cat > "$TASK2/state.json" <<'EOF'
{"workflow_phase":"done","plan_approved":true,"dev_phases":{}}
EOF
printf "## 결론\n통과\n" > "$TASK2/verifications/e2e-result.md"
OUT=$(run_stop2); check_stop "M-17: done + e2e pass → continue (silent exit)" "$OUT" "continue"
OUT=$(run_plan2 "$TMPDIR2/src/app.py"); check "M-18: done + source write → allow" "$OUT" "allow"
OUT=$(run_bash2 "git commit -m 'feat: done'"); check "M-19: done + git commit → allow" "$OUT" "allow"

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
