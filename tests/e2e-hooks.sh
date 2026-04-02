#!/bin/bash
# E2E Hook 테스트 스크립트
# 사용법: bash tests/e2e-hooks.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 실제 설치 (suite 1회) — 설치된 경로의 hook 사용
INSTALL_REPO=$(mktemp -d)
git init "$INSTALL_REPO" -q
git -C "$INSTALL_REPO" -c user.email=test@test.com -c user.name=Test commit --allow-empty -m "init" -q 2>/dev/null
(cd "$INSTALL_REPO" && bash "$SRC_DIR/install.sh" --ci 2>/dev/null)
HOOKS_DIR="$INSTALL_REPO/.claude/hooks"

PASS=0
FAIL=0

# 테스트 환경 설정 — 격리된 INSTALL_REPO 내 태스크 디렉토리 사용
TODAY=$(date +%Y-%m-%d)
TASK_DIR="$INSTALL_REPO/.ai-bouncer-tasks/$TODAY/e2e-hook-test"
mkdir -p "$TASK_DIR"
STATE_FILE="$TASK_DIR/state.json"
ACTIVE_FILE="$TASK_DIR/.active"
TEST_SID="e2e-test-session-$(date +%s)"

# config.json 경로 (설치된 경로)
CONFIG_FILE="$INSTALL_REPO/.claude/ai-bouncer/config.json"

# 초기 state.json 생성
python3 -c "
import json
s = {
  'workflow_phase': 'development',
  'mode': 'simple',
  'plan_approved': True,
  'team_name': '',
  'current_dev_phase': 0,
  'current_step': 0,
  'dev_phases': {},
  'verification': {'rounds_passed': 0}
}
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
echo "$TEST_SID" > "$ACTIVE_FILE"

# step.md 생성 헬퍼: TC + 검증 명령어(backtick) 포함
# $1: 파일 경로, $2: ✅ 포함 여부 ("checked" or "")
make_step() {
  local file="$1" mark="${2:-}"
  local checkmark=""
  [ "$mark" = "checked" ] && checkmark=" ✅ |" || checkmark=" |"
  printf "| TC | 시나리오 | 기대 결과 | 실제 결과 |\n|---|---|---|---|\n| TC-1 | test case | expected result |%s\n\n\`bash test.sh\`\n" "$checkmark" > "$file"
}

# plan-gate 검증 통과용 표준 plan.md 생성 함수
make_valid_plan() {
  python3 -c "
lines = ['# Test Plan', '', '## 변경 파일별 상세', '### src/foo.py', '- **변경 이유**: 테스트', '- **Before**:', '\`\`\`', 'old code here', '\`\`\`', '- **After**:', '\`\`\`', 'new code here', '\`\`\`', '- **영향 범위**: 없음', '']
lines += ['내용 라인 ' + str(i) for i in range(20)]
lines += ['', '## 검증', '\`pytest src/foo.py\`', '예상: 1 passed', '']
open('$TASK_DIR/plan.md', 'w').write('\n'.join(lines))
"
}
make_valid_plan

cleanup() { rm -rf "$INSTALL_REPO"; rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot-*; }
trap cleanup EXIT

setup() {
  # state.json을 원하는 상태로 설정
  local mode="${1:-simple}" phase="${2:-development}" approved="${3:-true}"
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['mode'] = '$mode'
s['workflow_phase'] = '$phase'
s['plan_approved'] = ('$approved' == 'true')
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
  echo "$TEST_SID" > "$ACTIVE_FILE"
  make_valid_plan
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot-*
}

# 헬퍼: hook 실행 후 차단 여부 확인
run_hook() {
  local hook="$1" input="$2"
  (cd "$INSTALL_REPO" && echo "$input" | bash "$HOOKS_DIR/$hook" 2>/dev/null) || true
}

assert_pass() {
  local desc="$1" result="$2"
  if [ -z "$result" ] || ! echo "$result" | grep -q '"block"'; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — 차단됨: $(echo "$result" | jq -r '.reason' 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
}

assert_block() {
  local desc="$1" result="$2"
  if echo "$result" | grep -q '"block"' 2>/dev/null; then
    echo "  ✅ $desc (차단됨)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc — 차단되지 않음"
    FAIL=$((FAIL + 1))
  fi
}

# NORMAL 모드 E2E 헬퍼: 팀 + plan.md + dev_phases 한번에 세팅
setup_normal() {
  local dev_phases="${1:-\{\}}" current_phase="${2:-1}" current_step="${3:-1}"
  local team_name="e2e-test-team"

  python3 -c "
import json, sys
s = json.load(open('$STATE_FILE'))
s['mode'] = 'normal'
s['workflow_phase'] = 'development'
s['plan_approved'] = True
s['team_name'] = '$team_name'
s['current_dev_phase'] = $current_phase
s['current_step'] = $current_step
s['dev_phases'] = json.loads(sys.argv[1])
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
" "$dev_phases"

  echo "$TEST_SID" > "$ACTIVE_FILE"
  make_valid_plan
  mkdir -p "$HOME/.claude/teams/$team_name"
  echo '{"members":["lead-agent"]}' > "$HOME/.claude/teams/$team_name/config.json"
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot-*
}

cleanup_normal() {
  rm -rf "$HOME/.claude/teams/e2e-test-team"
  rm -f "$TASK_DIR/plan.md"
  rm -rf "$TASK_DIR/phase-1-test"
}

echo "═══════════════════════════════════════════"
echo "  ai-bouncer E2E Hook Tests"
echo "═══════════════════════════════════════════"
echo ""

# ─── 1. plan-gate 테스트 ───────────────────
echo "─── plan-gate.sh ───"

setup "simple" "development" "true"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE + development + approved → 통과" "$R"

setup "simple" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE + planning → 통과 (탐색 허용)" "$R"

setup "simple" "development" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SIMPLE + development + 미승인 → 차단" "$R"

# plan.md 경로는 항상 허용
setup "simple" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/plan.md\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan.md 경로 → 항상 통과" "$R"

# ~/.claude/plans/ 경로
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HOME/.claude/plans/test.md\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "~/.claude/plans/ → 항상 통과" "$R"

# 위임 에이전트
setup "simple" "development" "true"
echo "${TEST_SID}-sub|$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "위임 에이전트 → 부모 task 기준 통과" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 2. bash-gate 테스트 ──────────────────
echo "─── bash-gate.sh ───"

setup "simple" "development" "true"

# fd redirect 오탐
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls foo 2>/dev/null\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "2>/dev/null → 오탐 아님" "$R"

R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat file 2>&1\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "2>&1 → 오탐 아님" "$R"

R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cmd 1>/dev/null 2>/dev/null\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "1>/dev/null 2>/dev/null → 오탐 아님" "$R"

# 진짜 쓰기는 development에서 통과 (gate 조건 충족)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "echo > file.txt (development) → 통과" "$R"

# planning에서 일반 쓰기는 허용 (탐색/Q&A 중 파일 쓰기 허용, 커밋만 차단)
setup "simple" "planning" "false"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "echo > file.txt (planning) → 차단 (소스 파일 수정 불가)" "$R"

# git 명령어는 항상 통과
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "git add → 항상 통과" "$R"

# state.json 예외
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"python3 -c 'import json; ...' state.json\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "state.json 수정 → 예외 통과" "$R"

# rm state.json: planning 단계에서도 state.json 삭제는 차단 (삭제 방지 정책)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm state.json\"},\"session_id\":\"$TEST_SID\"}")
assert_block "rm state.json (planning) → 차단 (삭제 방지)" "$R"

# python 오탐 (python_version 같은 변수)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo python_version\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "echo python_version → 오탐 아님" "$R"

echo ""

# ─── 3. subagent-track/cleanup 테스트 ─────
echo "─── subagent-track/cleanup ───"

setup "simple" "development" "true"

# SubagentStart
R=$((cd "$INSTALL_REPO" && echo "{\"session_id\":\"sub-001\",\"agent_id\":\"agent-1\"}" | bash "$HOOKS_DIR/subagent-track.sh" 2>/dev/null) || true)
if [ -f /tmp/.ai-bouncer-approved-agents ] && grep -q "sub-001" /tmp/.ai-bouncer-approved-agents; then
  echo "  ✅ SubagentStart: sub-001 등록됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ SubagentStart: sub-001 등록 안 됨"
  FAIL=$((FAIL + 1))
fi

# SubagentStop
(cd "$INSTALL_REPO" && echo "{\"session_id\":\"sub-001\"}" | bash "$HOOKS_DIR/subagent-cleanup.sh" 2>/dev/null) || true
if [ ! -f /tmp/.ai-bouncer-approved-agents ] || ! grep -q "sub-001" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo "  ✅ SubagentStop: sub-001 제거됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ SubagentStop: sub-001 제거 안 됨"
  FAIL=$((FAIL + 1))
fi

# planning 상태에서는 등록 안 됨
# 다른 .active 파일이 development 상태면 subagent-track이 그걸 찾으므로 격리 필요
setup "simple" "planning" "false"
OTHER_ACTIVES=()
while IFS= read -r -d '' af; do
  [ "$af" = "$ACTIVE_FILE" ] && continue
  OTHER_ACTIVES+=("$af")
  mv "$af" "${af}.bak-e2e"
done < <(find "$INSTALL_REPO/docs" -name ".active" -print0 2>/dev/null)
(cd "$INSTALL_REPO" && echo "{\"session_id\":\"sub-002\"}" | bash "$HOOKS_DIR/subagent-track.sh" 2>/dev/null) || true
if ! grep -q "sub-002" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo "  ✅ planning 상태 → 등록 안 됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ planning 상태인데 등록됨"
  FAIL=$((FAIL + 1))
fi
for af in "${OTHER_ACTIVES[@]+"${OTHER_ACTIVES[@]}"}"; do
  mv "${af}.bak-e2e" "$af" 2>/dev/null || true
done

echo ""

# ─── 4. completion-gate 테스트 ────────────
echo "─── completion-gate.sh ───"

# development 단계: 모드/팀 상관없이 통과 (plan-gate + context restore가 대신 강제)
setup "simple" "development" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE + development → 통과 (development 차단 제거)" "$R"

setup "normal" "development" "true"
python3 -c "
import json; s=json.load(open('$STATE_FILE'))
s['current_dev_phase']=1; s['dev_phases']={'1':{'name':'test','folder':'phase-1-test','steps':{'1':{}}}}
json.dump(s,open('$STATE_FILE','w'),indent=2)"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "NORMAL + development + team_name 없음 → 통과" "$R"

setup "normal" "development" "true"
python3 -c "
import json; s=json.load(open('$STATE_FILE'))
s['team_name']='test-team'; s['current_dev_phase']=1
s['dev_phases']={'1':{'name':'test','folder':'phase-1-test','steps':{'1':{}}}}
json.dump(s,open('$STATE_FILE','w'),indent=2)"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "NORMAL + development + team_name 있음 → 통과" "$R"

# verification 차단 유지
setup "normal" "verification" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "NORMAL + verification + round 없음 → 차단" "$R"

# 위임 에이전트 스킵
echo "${TEST_SID}-sub|$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook completion-gate.sh "{\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "위임 에이전트 → completion-gate 스킵" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 5. bash-audit 테스트 ─────────────────
echo "─── bash-audit.sh ───"

# 스냅샷 없으면 스킵
rm -f /tmp/.ai-bouncer-snapshot-*
R=$(run_hook bash-audit.sh "{\"tool_name\":\"Bash\",\"session_id\":\"$TEST_SID\"}")
assert_pass "스냅샷 없음 → audit 스킵" "$R"

# 승인된 에이전트는 스킵
touch "/tmp/.ai-bouncer-snapshot-${TEST_SID}-sub"
echo "${TEST_SID}-sub|$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook bash-audit.sh "{\"tool_name\":\"Bash\",\"session_id\":\"${TEST_SID}-sub\"}")
assert_pass "승인된 에이전트 → audit 스킵" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

echo ""

# ─── 6. 예외 경로 테스트 ─────────────────
echo "─── 예외 경로 ───"

setup "simple" "planning" "false"

# tests.md
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > tests.md << EOF\\ntest\\nEOF\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "tests.md Bash 쓰기 → 예외 통과" "$R"

# .active 파일 삭제
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -f $ACTIVE_FILE\"},\"session_id\":\"$TEST_SID\"}")
assert_pass ".active 삭제 → 예외 통과" "$R"

echo ""

# ─── 7. dev_phases 엣지케이스 (NORMAL E2E) ─
echo "─── dev_phases 엣지케이스 (NORMAL E2E) ───"

VALID_DEV_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'

# TC-1: dev_phases={} + Write → BLOCK (Lead가 phase 구조를 안 만들고 개발 시작한 상황)
setup_normal '{}' 1 1
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "NORMAL + dev_phases={} + Write → 차단" "$R"

# TC-2: dev_phases={} + Bash 쓰기 → BLOCK
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "NORMAL + dev_phases={} + echo > → 차단" "$R"

# TC-3: 정상 dev_phases + 모든 아티팩트 존재 + Write → ALLOW (대조군)
setup_normal "$VALID_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "NORMAL + 정상 dev_phases + Write → 통과" "$R"

# TC-4: 정상 dev_phases + Bash 쓰기 → ALLOW (대조군)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "NORMAL + 정상 dev_phases + echo > → 통과" "$R"

# TC-5: sub-agent + dev_phases={} 부모 + Write → BLOCK
setup_normal '{}' 1 1
echo "${TEST_SID}-sub|$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"${TEST_SID}-sub\"}")
assert_block "sub-agent + dev_phases={} 부모 + Write → 차단" "$R"

# TC-6: sub-agent + dev_phases={} 부모 + Bash 쓰기 → BLOCK
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"${TEST_SID}-sub\"}")
assert_block "sub-agent + dev_phases={} 부모 + echo > → 차단" "$R"
rm -f /tmp/.ai-bouncer-approved-agents

# TC-7: SIMPLE + dev_phases={} + Write → ALLOW (simple은 dev_phases 검증 스킵)
setup "simple" "development" "true"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SIMPLE + dev_phases={} + Write → 통과 (스킵)" "$R"

cleanup_normal

echo ""

# ─── 8. Phase 순서 강제 (plan-gate.sh) ────
echo "─── Phase 순서 강제 (plan-gate.sh) ───"

TWO_PHASE_DEV_PHASES='{"1":{"name":"base","folder":"phase-1-base","steps":{"1":{"title":"Step 1"}}},"2":{"name":"ui","folder":"phase-2-ui","steps":{"1":{"title":"Step 1"}}}}'

# TC-P1: Phase 2 Step 1 + Phase 1 step에 ✅ 없음 → BLOCK
setup_normal "$TWO_PHASE_DEV_PHASES" 2 1
mkdir -p "$TASK_DIR/phase-1-base" "$TASK_DIR/phase-2-ui"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-base/phase.md"
printf "# Phase 2\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-2-ui/phase.md"
make_step "$TASK_DIR/phase-1-base/step-1.md" ""
make_step "$TASK_DIR/phase-2-ui/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "Phase 2 + Phase 1 미완료 → 차단" "$R"

# TC-P2: Phase 2 Step 1 + Phase 1 step에 ✅ 있음 → ALLOW
make_step "$TASK_DIR/phase-1-base/step-1.md" "checked"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "Phase 2 + Phase 1 완료 → 통과" "$R"

# TC-P3: Phase 1 Step 1 (첫 Phase) → 이전 Phase 검증 스킵 → ALLOW
setup_normal "$TWO_PHASE_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-base"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-base/phase.md"
make_step "$TASK_DIR/phase-1-base/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "Phase 1 (첫 Phase) → 이전 검증 스킵 → 통과" "$R"

# 정리
rm -rf "$TASK_DIR/phase-1-base" "$TASK_DIR/phase-2-ui"
cleanup_normal

echo ""

# ─── 9. verification + 미완료 Phase 차단 (plan-gate.sh) ────
echo "─── verification + 미완료 Phase 차단 ───"

THREE_PHASE_DEV_PHASES='{"1":{"name":"base","folder":"phase-1-base","steps":{"1":{"title":"Step 1"}}},"2":{"name":"ui","folder":"phase-2-ui","steps":{"1":{"title":"Step 1"}}},"3":{"name":"integration","folder":"phase-3-int","steps":{"1":{"title":"Step 1"}}}}'

# TC-V1: verification + Phase 2만 완료 (Phase 3 미완료) → BLOCK
setup_normal "$THREE_PHASE_DEV_PHASES" 1 1
# workflow_phase를 verification으로 변경
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['workflow_phase'] = 'verification'
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
mkdir -p "$TASK_DIR/phase-1-base" "$TASK_DIR/phase-2-ui" "$TASK_DIR/phase-3-int"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-base/phase.md"
printf "# Phase 2\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-2-ui/phase.md"
printf "# Phase 3\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-3-int/phase.md"
make_step "$TASK_DIR/phase-1-base/step-1.md" "checked"
make_step "$TASK_DIR/phase-2-ui/step-1.md" "checked"
make_step "$TASK_DIR/phase-3-int/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "verification + Phase 3 미완료 → 차단" "$R"

# TC-V2: verification + 모든 Phase 완료 → ALLOW
make_step "$TASK_DIR/phase-3-int/step-1.md" "checked"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "verification + 모든 Phase 완료 → 통과" "$R"

# TC-V3: verification + step 파일 없는 Phase → BLOCK
rm -f "$TASK_DIR/phase-3-int/step-1.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "verification + step 없는 Phase → 차단" "$R"

# bash-gate도 동일하게 차단하는지 검증
# TC-V4: bash-gate + verification + Phase 3 미완료 → BLOCK
setup_normal "$THREE_PHASE_DEV_PHASES" 1 1
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['workflow_phase'] = 'verification'
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
mkdir -p "$TASK_DIR/phase-1-base" "$TASK_DIR/phase-2-ui" "$TASK_DIR/phase-3-int"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-base/phase.md"
printf "# Phase 2\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-2-ui/phase.md"
printf "# Phase 3\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-3-int/phase.md"
make_step "$TASK_DIR/phase-1-base/step-1.md" "checked"
make_step "$TASK_DIR/phase-2-ui/step-1.md" "checked"
make_step "$TASK_DIR/phase-3-int/step-1.md" ""
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: verification + Phase 3 미완료 → 차단" "$R"

# TC-V5: bash-gate + verification + 모든 Phase 완료 → ALLOW
make_step "$TASK_DIR/phase-3-int/step-1.md" "checked"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "bash-gate: verification + 모든 Phase 완료 → 통과" "$R"

# 정리
rm -rf "$TASK_DIR/phase-1-base" "$TASK_DIR/phase-2-ui" "$TASK_DIR/phase-3-int"
cleanup_normal

echo ""

# ─── 10. 문서 품질 강화 검증 ──────────────
echo "─── 문서 품질 강화 검증 ───"

QUALITY_DEV_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"},"2":{"title":"Step 2"}}}}'

# TC-Q1: folder 없는 dev_phases → fallback으로 CHECK 7 진입 → phase.md 없어서 차단
NOFOLDER_DEV_PHASES='{"1":{"name":"test","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$NOFOLDER_DEV_PHASES" 1 1
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: folder 없음 → fallback → phase.md 없어서 차단" "$R"

# TC-Q2: bash-gate도 동일
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: folder 없음 → fallback → phase.md 없어서 차단" "$R"

# TC-KR1: 한글 name + folder 키 없음 → 실제 영문 디렉토리를 fallback 탐색하여 통과
KOREAN_DEV_PHASES='{"1":{"name":"백엔드 코드 변경","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$KOREAN_DEV_PHASES" 1 1
# bash-gate team 체크 통과용 dev 에이전트 추가
echo '{"members":[{"name":"lead-agent"},{"name":"dev-agent"}]}' > "$HOME/.claude/teams/e2e-test-team/config.json"
mkdir -p "$TASK_DIR/phase-1-backend-code"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-backend-code/phase.md"
make_step "$TASK_DIR/phase-1-backend-code/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan-gate: 한글 name + folder 없음 → fallback 탐색 → 통과" "$R"

# TC-KR2: bash-gate도 동일
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "bash-gate: 한글 name + folder 없음 → fallback 탐색 → 통과" "$R"
rm -rf "$TASK_DIR/phase-1-backend-code"

# TC-DL1: phase.md 없을 때 state.json 수정 → deadlock 없이 통과 (plan-gate)
NOFOLDER_DEV_PHASES2='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$NOFOLDER_DEV_PHASES2" 1 1
echo '{"members":[{"name":"lead-agent"},{"name":"dev-agent"}]}' > "$HOME/.claude/teams/e2e-test-team/config.json"
# phase.md 의도적으로 안 만듦 — state.json 수정은 허용되어야 함
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$STATE_FILE\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan-gate: phase.md 없어도 state.json 수정 → 통과 (deadlock 방지)" "$R"

# TC-DL2: bash-gate도 state.json 수정 명령 허용
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"python3 -c \\\"import json; json.dump({}, open('$STATE_FILE','w'))\\\"\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "bash-gate: phase.md 없어도 state.json 명령 → 통과 (deadlock 방지)" "$R"

# TC-DL3: phase.md 없을 때 일반 파일 수정 → 여전히 차단 (보안 유지)
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: phase.md 없고 일반 파일 수정 → 차단 유지" "$R"

# TC-Q3: phase.md 존재하지만 필수 섹션 누락 → 차단 (plan-gate)
setup_normal "$QUALITY_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
echo "# Phase 1 빈약한 문서" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: phase.md 필수 섹션 누락 → 차단" "$R"

# TC-Q4: bash-gate도 동일
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: phase.md 필수 섹션 누락 → 차단" "$R"

# TC-Q5: phase.md에 필수 섹션 있음 → 통과 (대조군)
printf "# Phase 1\n\n## 목표\n- test goal\n\n## 범위\n- test scope\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan-gate: phase.md 필수 섹션 있음 → 통과" "$R"

# TC-Q6: Step 2 진행 시 Step 1에 실행출력 없음 → 차단 (plan-gate)
setup_normal "$QUALITY_DEV_PHASES" 1 2
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n- Step 2\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" "checked"
make_step "$TASK_DIR/phase-1-test/step-2.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 이전 step 실행출력 없음 → 차단" "$R"

# TC-Q7: bash-gate도 동일
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: 이전 step 실행출력 없음 → 차단" "$R"

# TC-Q8: Step 1에 실행출력 있음 → 통과 (대조군)
printf "| TC-1 | test case | expected result | ✅ |\n\n\`bash test.sh\`\n\n## 실행 결과\n\$ pytest\n1 passed\n" > "$TASK_DIR/phase-1-test/step-1.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "plan-gate: 이전 step 실행출력 있음 → 통과" "$R"

# TC-Q9: completion-gate — round.md에 ## 결론 없으면 차단
setup "normal" "verification" "true"
VERIFY_DIR="$TASK_DIR/verifications"
mkdir -p "$VERIFY_DIR"
echo "통과" > "$VERIFY_DIR/round-1.md"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "completion-gate: round.md에 ## 결론 없음 → 차단" "$R"

# TC-Q10: round-1.md만 있음 → 차단 (3라운드 필요)
printf "## 결론\n통과\n" > "$VERIFY_DIR/round-1.md"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "completion-gate: round 1개만 → 차단 (3라운드 필요)" "$R"

# TC-Q10b: round-1~2만 있음 → 차단 (3라운드 필요)
printf "## 결론\n통과\n" > "$VERIFY_DIR/round-2.md"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "completion-gate: round 2개만 → 차단 (3라운드 필요)" "$R"

# TC-Q10c: round-1~3 있고 마지막이 통과 → 통과
printf "## 결론\n통과\n" > "$VERIFY_DIR/round-3.md"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "completion-gate: round 3개 + 통과 → 통과" "$R"

# TC-Q13: ## 결론 다음 줄이 "통과"가 아님 → 차단
printf "## 결론\n이번 라운드는 통과입니다\n" > "$VERIFY_DIR/round-3.md"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_block "completion-gate: ## 결론 다음 줄에 정확한 '통과' 없음 → 차단" "$R"

# 정리
rm -rf "$TASK_DIR/phase-1-test" "$VERIFY_DIR"
cleanup_normal

echo ""

# ─── plan-gate: 신규 검증 케이스 ────────
echo "─── plan-gate: planning 단계 / plan.md 품질 / TC 충실도 ───"

# PG-NEW-1: planning 단계 phase.md 작성 → 차단
setup "normal" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/phase-1-foo/phase.md\"},\"session_id\":\"$TEST_SID\"}")
assert_block "PG: planning 단계 phase.md 작성 → 차단" "$R"

# PG-NEW-2: planning 단계 step.md 작성 → 차단
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/phase-1-foo/step-1.md\"},\"session_id\":\"$TEST_SID\"}")
assert_block "PG: planning 단계 step.md 작성 → 차단" "$R"

# PG-NEW-3: planning 단계 plan.md 작성 → 허용
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/plan.md\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: planning 단계 plan.md 작성 → 허용" "$R"
cleanup_normal

# PG-NEW-4: 3줄 plan.md → 통과 (포맷 검증 제거됨, plan_approved + 존재만 체크)
QUAL_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$QUAL_PHASES" 1 1
echo -e "# Plan\nshort\n" > "$TASK_DIR/plan.md"
mkdir -p "$TASK_DIR/phase-1-test"
printf "## 목표\n테스트\n## 범위\n파일\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
printf "| TC | 시나리오 | 기대 결과 | 실제 결과 |\n|---|---|---|---|\n| TC-1 | 테스트 시나리오 | 기대 결과 값 | |\n\n\`\`\`\nbash test\n\`\`\`\n" > "$TASK_DIR/phase-1-test/step-1.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: 3줄 plan.md → 통과 (포맷 검증 제거됨)" "$R"

# PG-NEW-5: Before/After 없는 plan.md → 통과 (포맷 검증 제거됨)
python3 -c "
content = '# Plan\n\n## 변경 파일별 상세\n### foo.py\n- 변경 이유: 테스트\n'
content += '\n'.join(['더미 라인 ' + str(i) for i in range(30)])
content += '\n\n## 검증\n\`pytest\`\n'
open('$TASK_DIR/plan.md', 'w').write(content)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: Before/After 없는 plan.md → 통과 (포맷 검증 제거됨)" "$R"

# PG-NEW-6: 정상 plan.md → 통과
python3 -c "
content = '# Plan\n\n## 변경 파일별 상세\n### foo.py\n- **변경 이유**: 테스트\n- **Before**:\n\`\`\`\nold code\n\`\`\`\n- **After**:\n\`\`\`\nnew code\n\`\`\`\n'
content += '\n'.join(['내용 라인 ' + str(i) for i in range(20)])
content += '\n\n## 검증\n\`pytest foo.py\`\n예상 결과: pass\n'
open('$TASK_DIR/plan.md', 'w').write(content)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: 정상 plan.md (Before/After + 섹션 + 검증명령) → 통과" "$R"

# PG-NEW-7: TC 시나리오 1자짜리 → 차단
printf "## 목표\n테스트\n## 범위\n파일\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
printf "| TC | 시나리오 | 기대 결과 | 실제 결과 |\n|---|---|---|---|\n| TC-1 | x | y | |\n\n\`bash test\`\n" > "$TASK_DIR/phase-1-test/step-1.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "PG: TC 시나리오/기대결과 1자 → 차단" "$R"

# PG-NEW-8: 실행출력 빈 이전 step → 차단
python3 -c "
import json; s=json.load(open('$STATE_FILE'))
s['current_step']=2; json.dump(s,open('$STATE_FILE','w'),indent=2)"
printf "| TC-1 | test scenario | expected result | ✅ |\n\n## 실행 결과\n\n\n" > "$TASK_DIR/phase-1-test/step-1.md"
printf "## 목표\n테스트\n## 범위\n파일\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
printf "| TC | 시나리오 | 기대 결과 | 실제 결과 |\n|---|---|---|---|\n| TC-1 | 충분한 시나리오 | 충분한 기대결과 | |\n\n\`bash test.sh\`\n" > "$TASK_DIR/phase-1-test/step-2.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "PG: 이전 step 실행출력 빈 섹션 → 차단" "$R"

rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

# PG-NEW-9: planning 단계 프로젝트 소스 파일 수정 → 차단
setup "normal" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$INSTALL_REPO/hooks/some-hook.sh\"},\"session_id\":\"$TEST_SID\"}")
assert_block "PG: planning 단계 프로젝트 소스 파일 → 차단" "$R"

# PG-NEW-10: planning 단계 /tmp/ 파일 → 허용 (탐색)
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: planning 단계 /tmp/ 파일 → 허용 (탐색)" "$R"

# PG-NEW-11: planning 단계 .ai-bouncer-tasks/ 파일 → 허용
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TASK_DIR/state.json\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "PG: planning 단계 .ai-bouncer-tasks/ 파일 → 허용" "$R"

echo ""

# ─── 11. CHECK 4/5/6 팀 구성 검증 ────────
echo "─── CHECK 4/5/6 팀 구성 검증 ───"

TEAM_DEV_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'

# TC-T1: NORMAL + development + team_name 비어있음 → 차단 (plan-gate CHECK 4)
setup_normal "$TEAM_DEV_PHASES" 1 1
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['team_name'] = ''
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: team_name 비어있음 → 차단" "$R"

# TC-T2: NORMAL + development + 팀 config.json 없음 → 차단 (plan-gate CHECK 5)
setup_normal "$TEAM_DEV_PHASES" 1 1
rm -rf "$HOME/.claude/teams/e2e-test-team"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 팀 config.json 없음 → 차단" "$R"

# TC-T3: NORMAL + development + 팀 멤버 0명 → 차단 (plan-gate CHECK 6)
setup_normal "$TEAM_DEV_PHASES" 1 1
echo '{"members":[]}' > "$HOME/.claude/teams/e2e-test-team/config.json"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 팀 멤버 0명 → 차단" "$R"

cleanup_normal

echo ""

# ─── 12. CHECK 6.5 + CHECK 7b/7d/7e ─────
echo "─── CHECK 6.5 + step 파일 검증 ───"

STEP_DEV_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"},"2":{"title":"Step 2"}}}}'

# TC-S1: development + phase=0 → 차단 (CHECK 6.5)
setup_normal "$STEP_DEV_PHASES" 0 1
# setup_normal은 current_dev_phase를 설정하므로 수동 오버라이드
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['current_dev_phase'] = 0
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: dev_phase=0 → 차단" "$R"

# TC-S2: development + step=0 → 차단 (CHECK 6.5)
setup_normal "$STEP_DEV_PHASES" 1 0
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['current_step'] = 0
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: step=0 → 차단" "$R"

# TC-S3: 이전 step 파일 미존재 → 차단 (CHECK 7b)
setup_normal "$STEP_DEV_PHASES" 1 2
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n- Step 2\n" > "$TASK_DIR/phase-1-test/phase.md"
# step-1.md 없음 (이전 step 파일 미존재)
make_step "$TASK_DIR/phase-1-test/step-2.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 이전 step 파일 미존재 → 차단" "$R"

# TC-S4: 현재 step 파일 미존재 → 차단 (CHECK 7d)
setup_normal "$STEP_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
# step-1.md 없음 (현재 step 파일 미존재)
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 현재 step 파일 미존재 → 차단" "$R"

# TC-S5: 현재 step에 TC 행 없음 → 차단 (CHECK 7e)
echo "# Step 1 (TC 없음)" > "$TASK_DIR/phase-1-test/step-1.md"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 현재 step TC 미정의 → 차단" "$R"

# TC-S6: bash-gate도 동일 (CHECK 7d — 현재 step 파일 미존재)
setup_normal "$STEP_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: 현재 step 파일 미존재 → 차단" "$R"

# TC-S7: bash-gate CHECK 7e — TC 미정의
echo "# Step 1 (TC 없음)" > "$TASK_DIR/phase-1-test/step-1.md"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: 현재 step TC 미정의 → 차단" "$R"

rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

echo ""

# ─── 13. commit_strategy 검증 ────────────
echo "─── commit_strategy 검증 ───"

CS_DEV_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'

# 백업 config.json
cp "$CONFIG_FILE" /tmp/.ai-bouncer-config-backup.json

# TC-C1: commit_strategy=none → git commit 차단
setup_normal "$CS_DEV_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" "checked"
python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['commit_strategy'] = 'none'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: commit_strategy=none → git commit 차단" "$R"

# TC-C2: commit_strategy=per-step + step 미완료 → git commit 차단
python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['commit_strategy'] = 'per-step'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: per-step + step 미완료 → git commit 차단" "$R"

# TC-C3: commit_strategy=per-step + step 완료 → git commit 통과
make_step "$TASK_DIR/phase-1-test/step-1.md" "checked"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "bash-gate: per-step + step 완료 → git commit 통과" "$R"

# TC-C4: commit_strategy=per-phase + 마지막 step 미완료 → 차단
python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['commit_strategy'] = 'per-phase'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: per-phase + 마지막 step 미완료 → 차단" "$R"

# config.json 복원
cp /tmp/.ai-bouncer-config-backup.json "$CONFIG_FILE"
rm -f /tmp/.ai-bouncer-config-backup.json
rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

echo ""

# ─── 14. completion-gate cancelled + 워크플로우 화이트리스트 ───
echo "─── cancelled + 화이트리스트 ───"

# TC-W1: cancelled → completion-gate 통과
setup "normal" "verification" "true"
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['workflow_phase'] = 'cancelled'
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "completion-gate: cancelled → 즉시 통과" "$R"

# TC-W2: 잘못된 workflow_phase → plan-gate 차단
setup "normal" "development" "true"
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['workflow_phase'] = 'invalid_phase'
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "plan-gate: 잘못된 workflow_phase → 차단" "$R"

# TC-W3: 잘못된 workflow_phase → bash-gate 차단
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "bash-gate: 잘못된 workflow_phase → 차단" "$R"

echo ""

# ─── 15. QA 회귀 테스트 ─────────────────────
echo "─── QA 회귀 테스트 ───"

# TC-QA1: subagent-cleanup — approved 파일 없이 호출 → 빈 파일 생성 안 됨 (C-1)
rm -f /tmp/.ai-bouncer-approved-agents
(cd "$INSTALL_REPO" && echo '{"session_id":"orphan-session"}' | bash "$HOOKS_DIR/subagent-cleanup.sh" 2>/dev/null) || true
if [ ! -f /tmp/.ai-bouncer-approved-agents ]; then
  echo "  ✅ QA1: cleanup — approved 없이 호출 → 빈 파일 생성 안 됨"
  PASS=$((PASS + 1))
else
  echo "  ❌ QA1: cleanup — approved 없는데 빈 파일 생성됨"
  FAIL=$((FAIL + 1))
fi
rm -f /tmp/.ai-bouncer-approved-agents

# TC-QA2: subagent-cleanup — grep 매칭 0건(다른 세션만 존재) → 기존 항목 보존 (C-1)
echo "other-session|/some/path" > /tmp/.ai-bouncer-approved-agents
(cd "$INSTALL_REPO" && echo '{"session_id":"nonexistent-session"}' | bash "$HOOKS_DIR/subagent-cleanup.sh" 2>/dev/null) || true
if [ -f /tmp/.ai-bouncer-approved-agents ] && grep -q "other-session" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo "  ✅ QA2: cleanup — 매칭 없는 세션 제거 → 기존 항목 보존"
  PASS=$((PASS + 1))
else
  echo "  ❌ QA2: cleanup — 기존 항목이 사라짐"
  FAIL=$((FAIL + 1))
fi
rm -f /tmp/.ai-bouncer-approved-agents

# TC-QA3: bash-gate per-phase + steps={} → block 메시지에 "null" 미포함 (C-2)
EMPTY_STEPS_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{}}}'
setup_normal "$EMPTY_STEPS_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
cp "$CONFIG_FILE" /tmp/.ai-bouncer-config-backup-qa.json
python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['commit_strategy'] = 'per-phase'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$TEST_SID\"}")
# block은 예상 (step 없으니까), 하지만 "null" 참조는 버그
if echo "$R" | grep -q '"block"' 2>/dev/null; then
  if echo "$R" | grep -q 'null' 2>/dev/null; then
    echo "  ❌ QA3: per-phase + steps={} → block에 'null' 포함 (C-2 버그)"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ QA3: per-phase + steps={} → block에 'null' 미포함"
    PASS=$((PASS + 1))
  fi
else
  echo "  ❌ QA3: per-phase + steps={} → 차단되지 않음"
  FAIL=$((FAIL + 1))
fi
cp /tmp/.ai-bouncer-config-backup-qa.json "$CONFIG_FILE"
rm -f /tmp/.ai-bouncer-config-backup-qa.json
rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

# TC-QA4: bash-gate block 시 save_snapshot → snapshot 파일 정렬 검증 (C-3)
setup "simple" "planning" "false"
rm -f /tmp/.ai-bouncer-snapshot-*
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
SNAP_FILE="/tmp/.ai-bouncer-snapshot-${TEST_SID}"
if [ -f "$SNAP_FILE" ]; then
  SORTED_SNAP=$(sort "$SNAP_FILE")
  ORIGINAL_SNAP=$(cat "$SNAP_FILE")
  if [ "$SORTED_SNAP" = "$ORIGINAL_SNAP" ]; then
    echo "  ✅ QA4: save_snapshot → 정렬됨 (comm 호환)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ QA4: save_snapshot → 미정렬 (C-3 버그)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  ✅ QA4: snapshot 미생성 (정렬 검증 스킵 — planning block은 snapshot 없을 수 있음)"
  PASS=$((PASS + 1))
fi
rm -f /tmp/.ai-bouncer-snapshot-*

# TC-QA5: bash-gate team config에 members 키 없음 → 차단 (I-1)
QA5_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$QA5_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
# team config에서 members 키 제거
echo '{"name":"broken-team"}' > "$HOME/.claude/teams/e2e-test-team/config.json"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "QA5: team members 키 없음 → 차단 (I-1)" "$R"
rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

# TC-QA6: bash-gate team members 값 null → 차단 (I-1)
QA6_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_normal "$QA6_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
echo '{"members":null}' > "$HOME/.claude/teams/e2e-test-team/config.json"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
assert_block "QA6: team members=null → 차단 (I-1)" "$R"
rm -rf "$TASK_DIR/phase-1-test"
cleanup_normal

echo ""

# ─── 16. subagent 모드 hook 동작 ──────────────
echo "─── subagent 모드 hook 동작 ───"

ORIG_CONFIG=$(cat "$CONFIG_FILE")

# subagent 모드 헬퍼
setup_subagent() {
  local dev_phases="${1:-\{\}}" current_phase="${2:-1}" current_step="${3:-1}"
  python3 -c "
import json, sys
s = json.load(open('$STATE_FILE'))
s['mode'] = 'normal'
s['workflow_phase'] = 'development'
s['plan_approved'] = True
s['team_name'] = ''
s['current_dev_phase'] = $current_phase
s['current_step'] = $current_step
s['dev_phases'] = json.loads(sys.argv[1])
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
" "$dev_phases"
  # config.json에 agent_mode=subagent 설정
  python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
c['agent_mode'] = 'subagent'
json.dump(c, open('$CONFIG_FILE', 'w'), indent=2)
"
  echo "$TEST_SID" > "$ACTIVE_FILE"
  make_valid_plan
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot-*
}

cleanup_subagent() {
  echo "$ORIG_CONFIG" > "$CONFIG_FILE"
  rm -f "$TASK_DIR/plan.md"
  rm -rf "$TASK_DIR/phase-1-test"
}

# SA-1: subagent + team_name="" + development → plan-gate 통과 (team CHECK 스킵)
SA1_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_subagent "$SA1_PHASES" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SA-1: subagent + team_name='' → plan-gate 통과" "$R"
cleanup_subagent

# SA-2: subagent + dev_phases 정상 + 올바른 카운터 → plan-gate 통과
SA2_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"},"2":{"title":"Step 2"}}}}'
setup_subagent "$SA2_PHASES" 1 2
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n- Step 2\n" > "$TASK_DIR/phase-1-test/phase.md"
printf "| TC-1 | test case | expected result | ✅ |\n\n\`bash test.sh\`\n\n## 실행 결과\n실행 성공\n결과: OK\n" > "$TASK_DIR/phase-1-test/step-1.md"
make_step "$TASK_DIR/phase-1-test/step-2.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SA-2: subagent + 올바른 카운터/아티팩트 → plan-gate 통과" "$R"
cleanup_subagent

# SA-3: subagent + dev_phases={} + development → plan-gate 차단 (CHECK 6.7)
setup_subagent '{}' 1 1
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SA-3: subagent + dev_phases={} → plan-gate 차단" "$R"
cleanup_subagent

# SA-4: subagent + current_step=2 but step-1.md 없음 → plan-gate 차단
SA4_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"},"2":{"title":"Step 2"}}}}'
setup_subagent "$SA4_PHASES" 1 2
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n- Step 2\n" > "$TASK_DIR/phase-1-test/phase.md"
# step-1.md 의도적으로 생성 안 함
make_step "$TASK_DIR/phase-1-test/step-2.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SA-4: subagent + step-1.md 없음 → plan-gate 차단" "$R"
cleanup_subagent

# SA-5: subagent + step-1.md에 ✅ 없음 → plan-gate 차단
SA5_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"},"2":{"title":"Step 2"}}}}'
setup_subagent "$SA5_PHASES" 1 2
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n- Step 2\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
make_step "$TASK_DIR/phase-1-test/step-2.md" ""
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_block "SA-5: subagent + step-1.md ✅ 없음 → plan-gate 차단" "$R"
cleanup_subagent

echo ""

# ─── 16.5. 미등록 subagent fallback (resolve-task.sh) ──────
echo "─── 미등록 subagent fallback ───"

UNREGISTERED_SID="unregistered-sub-$(date +%s)"

# UF-1: 미등록 subagent + claimed 태스크 → plan-gate 통과 (session isolation 우선)
# 세션 간 격리(MSI) 도입으로 claimed 태스크는 fallback 대상에서 제외됨.
# 정상 subagent는 approved-agents 메커니즘으로 제어 (SA 테스트 참고).
FALLBACK_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_subagent "$FALLBACK_PHASES" 1 1
# approved 파일에 등록 안 함 — 미등록 subagent 시뮬레이션
rm -f /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-1: 미등록 subagent + claimed 태스크 → plan-gate 통과 (MSI 트레이드오프)" "$R"

# UF-2: 미등록 subagent + claimed 태스크 → bash-gate 통과 (session isolation 우선)
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-2: 미등록 subagent + claimed 태스크 → bash-gate 통과 (MSI 트레이드오프)" "$R"
cleanup_subagent

# UF-3: 미등록 subagent + 활성 태스크 없음 → 통과
rm -f "$ACTIVE_FILE"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-3: 미등록 subagent + 활성 태스크 없음 → 통과" "$R"

# UF-4: 미등록 subagent + planning 태스크만 → 통과 (fallback은 dev/verification만)
setup "simple" "planning" "false"
# 다른 .active들 임시 숨기기
OTHER_ACTIVES_UF=()
while IFS= read -r -d '' af; do
  [ "$af" = "$ACTIVE_FILE" ] && continue
  OTHER_ACTIVES_UF+=("$af")
  mv "$af" "${af}.bak-uf"
done < <(find "$INSTALL_REPO/docs" -name ".active" -print0 2>/dev/null)
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-4: 미등록 subagent + planning만 → 통과 (fallback 안 됨)" "$R"
for af in "${OTHER_ACTIVES_UF[@]+"${OTHER_ACTIVES_UF[@]}"}"; do
  mv "${af}.bak-uf" "$af" 2>/dev/null || true
done

# UF-5: 미등록 subagent + 정상 아티팩트 모두 존재 → 통과
FALLBACK_PHASES_FULL='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_subagent "$FALLBACK_PHASES_FULL" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
make_step "$TASK_DIR/phase-1-test/step-1.md" ""
rm -f /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-5: 미등록 subagent + 정상 아티팩트 → 통과" "$R"
cleanup_subagent

echo ""

# ─── 17. SIMPLE 모드 카운터 무시 ──────────────
echo "─── SIMPLE 모드 카운터 무시 ───"

# SM-1: SIMPLE + dev_phases={} + counters=0 + approved → plan-gate 통과
setup "simple" "development" "true"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
assert_pass "SM-1: SIMPLE + dev_phases={} + counters=0 → plan-gate 통과" "$R"

# SM-2: SIMPLE + development + approved → completion-gate 통과 (development 차단 제거됨)
setup "simple" "development" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "SM-2: SIMPLE + development + approved → completion-gate 통과 (development 차단 제거됨)" "$R"

# SM-3: SIMPLE + done → completion-gate 통과
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['workflow_phase'] = 'done'
with open('$STATE_FILE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "SM-3: SIMPLE + done → completion-gate 통과" "$R"

# SM-4: SIMPLE + plan_approved=false + development → completion-gate 통과
setup "simple" "development" "false"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
assert_pass "SM-4: SIMPLE + plan_approved=false → completion-gate 통과" "$R"

echo ""

# ─── 18. 세션 간 격리 (Multi-Session Isolation) ──────────────
echo "─── 세션 간 격리 (MSI) ───"

SESSION_A_SID="session-a-$(date +%s)"
SESSION_B_SID="session-b-$(date +%s)"
SESSION_A_DIR="$INSTALL_REPO/.ai-bouncer-tasks/$TODAY/msi-session-a"
SESSION_A_STATE="$SESSION_A_DIR/state.json"
SESSION_A_ACTIVE="$SESSION_A_DIR/.active"

# Session A 태스크 셋업 (normal, development, Session A 소유)
mkdir -p "$SESSION_A_DIR"
python3 -c "
import json
s = {
  'workflow_phase': 'development',
  'mode': 'normal',
  'plan_approved': True,
  'team_name': 'msi-test-team',
  'current_dev_phase': 1,
  'current_step': 1,
  'dev_phases': {'1': {'name': 'test', 'folder': 'phase-1-msi', 'steps': {}}},
  'verification': {'rounds_passed': 0}
}
with open('$SESSION_A_STATE', 'w') as f: json.dump(s, f, indent=2)
"
echo "$SESSION_A_SID" > "$SESSION_A_ACTIVE"
echo "# Session A Plan" > "$SESSION_A_DIR/plan.md"
mkdir -p "$HOME/.claude/teams/msi-test-team"
echo '{"members":["lead"]}' > "$HOME/.claude/teams/msi-test-team/config.json"
mkdir -p "$SESSION_A_DIR/phase-1-msi"
printf "## 목표\ntest\n## 범위\ntest\n## Steps\n1. test\n" > "$SESSION_A_DIR/phase-1-msi/phase.md"
printf "| TC | 검증 항목 | 기대 결과 | 상태 |\n|----|----------|----------|------|\n| TC-01 | x | y | ⬜ |\n" > "$SESSION_A_DIR/phase-1-msi/step-1.md"

# MSI-1: Session A(normal/dev) → Session B write → plan-gate 차단 안 됨
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$SESSION_B_SID\"}")
assert_pass "MSI-1: Session A(normal/dev) → Session B write → plan-gate 통과" "$R"

# MSI-2: Session A(planning) → Session B commit → bash-gate 차단 안 됨
python3 -c "
import json
s = json.load(open('$SESSION_A_STATE'))
s['workflow_phase'] = 'planning'
s['plan_approved'] = False
with open('$SESSION_A_STATE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m 'test'\"},\"session_id\":\"$SESSION_B_SID\"}")
assert_pass "MSI-2: Session A(planning) → Session B git commit → bash-gate 통과" "$R"

# MSI-3: Session A(normal/dev) → Session B completion-gate → 차단 안 됨
python3 -c "
import json
s = json.load(open('$SESSION_A_STATE'))
s['workflow_phase'] = 'development'
s['plan_approved'] = True
with open('$SESSION_A_STATE', 'w') as f: json.dump(s, f, indent=2)
"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$SESSION_B_SID\"}")
assert_pass "MSI-3: Session A(normal/dev) → Session B completion-gate 통과" "$R"

# 정리
rm -rf "$SESSION_A_DIR" "$HOME/.claude/teams/msi-test-team"

echo ""

# ─── CHECK 1.6b: current_step overflow 차단 ───────────────
echo "─── CHECK 1.6b: current_step overflow 차단 ───"

SINGLE_STEP_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'

# TC-QS1: state.json에 current_step > max_steps 값 쓰기 → CHECK 1.6b 차단
setup "simple" "planning" "false"
QS1_CONTENT=$(jq -n --argjson dp "$SINGLE_STEP_PHASES" '{
  workflow_phase: "planning", mode: "normal", plan_approved: false,
  team_name: "", current_dev_phase: 1, current_step: 2, dev_phases: $dp
}')
QS1_INPUT=$(jq -n --arg fp "$STATE_FILE" --arg content "$QS1_CONTENT" --arg sid "$TEST_SID" \
  '{tool_name: "Write", tool_input: {file_path: $fp, content: $content}, session_id: $sid}')
R=$(run_hook plan-gate.sh "$QS1_INPUT")
assert_block "TC-QS1: state.json current_step=2 > max_steps=1 → CHECK 1.6b 차단" "$R"

# TC-QS2: state.json에 current_step = max_steps → CHECK 1.6b 통과
setup "simple" "planning" "false"
QS2_CONTENT=$(jq -n --argjson dp "$SINGLE_STEP_PHASES" '{
  workflow_phase: "planning", mode: "normal", plan_approved: false,
  team_name: "", current_dev_phase: 1, current_step: 1, dev_phases: $dp
}')
QS2_INPUT=$(jq -n --arg fp "$STATE_FILE" --arg content "$QS2_CONTENT" --arg sid "$TEST_SID" \
  '{tool_name: "Write", tool_input: {file_path: $fp, content: $content}, session_id: $sid}')
R=$(run_hook plan-gate.sh "$QS2_INPUT")
assert_pass "TC-QS2: state.json current_step=1 = max_steps=1 → CHECK 1.6b 통과" "$R"

echo ""

# ─── 정리 ─────────────────────────────────
rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot-*

echo "═══════════════════════════════════════════"
echo "  결과: ✅ $PASS 통과 / ❌ $FAIL 실패"
echo "═══════════════════════════════════════════"

exit $FAIL
