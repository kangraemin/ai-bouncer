#!/bin/bash
# E2E Full Test — 설치 → 파일 검증 → hook 테스트 → 정리
# Usage: bash tests/e2e-full.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() {
  local desc="$1"
  echo -e "  ${GREEN}✅${NC} $desc"
  PASS=$((PASS + 1))
}

fail() {
  local desc="$1"
  echo -e "  ${RED}❌${NC} $desc"
  FAIL=$((FAIL + 1))
}

assert_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    echo -e "  ${GREEN}✅${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌${NC} $desc — $path 없음"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_file() {
  local desc="$1" path="$2"
  if [ ! -f "$path" ]; then
    echo -e "  ${GREEN}✅${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌${NC} $desc — $path 존재"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}✅${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌${NC} $desc — '$pattern' not in $file"
    FAIL=$((FAIL + 1))
  fi
}

# ── 테스트 환경 준비 ─────────────────────────────────────────
echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer E2E Full Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

# 임시 git repo에서 설치 테스트
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

git init "$TEST_DIR/test-repo" -q
REPO_DIR="$TEST_DIR/test-repo"
TARGET="$REPO_DIR/.claude"

# 소스 경로 (이 스크립트가 실행된 레포)
SRC_DIR="$(git rev-parse --show-toplevel)"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 1. 설치 (--ci) ───${NC}"

(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --ci) 2>&1 | tail -3

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 2. 설치 파일 검증 ───${NC}"

# hooks
assert_file "plan-gate.sh 설치됨"         "$TARGET/ai-bouncer/hooks/plan-gate.sh"
assert_file "bash-gate.sh 설치됨"         "$TARGET/ai-bouncer/hooks/bash-gate.sh"
assert_file "bash-audit.sh 설치됨"        "$TARGET/ai-bouncer/hooks/bash-audit.sh"
assert_file "doc-reminder.sh 설치됨"      "$TARGET/ai-bouncer/hooks/doc-reminder.sh"
assert_file "completion-gate.sh 설치됨"   "$TARGET/ai-bouncer/hooks/completion-gate.sh"
assert_file "subagent-track.sh 설치됨"    "$TARGET/ai-bouncer/hooks/subagent-track.sh"
assert_file "subagent-cleanup.sh 설치됨"  "$TARGET/ai-bouncer/hooks/subagent-cleanup.sh"
assert_file "resolve-task.sh 설치됨"      "$TARGET/ai-bouncer/hooks/lib/resolve-task.sh"

# agents
assert_file "intent.md 설치됨"       "$TARGET/agents/intent.md"
assert_file "verifier.md 설치됨"     "$TARGET/agents/verifier.md"
assert_file "lead.md 설치됨"         "$TARGET/agents/lead.md"
assert_file "dev.md 설치됨"          "$TARGET/agents/dev.md"
assert_file "qa.md 설치됨"           "$TARGET/agents/qa.md"

# skill
assert_file "dev-bounce SKILL.md 설치됨"  "$TARGET/skills/dev-bounce/SKILL.md"

# guides
assert_file "tc-guide.md 설치됨"  "$TARGET/agents/guides/tc-guide.md"

# scripts
assert_file "bouncer-update-check.sh 설치됨"  "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh"
assert_ok "bouncer-update-check.sh 실행 가능"  test -x "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh"

# hooks.json
assert_file "hooks.json 설치됨"  "$TARGET/ai-bouncer/hooks/hooks.json"

# settings.json
assert_file "settings.json 생성됨"  "$TARGET/settings.json"
assert_contains "plan-gate hook 등록됨"   "$TARGET/settings.json" "plan-gate.sh"
assert_contains "bash-gate hook 등록됨"   "$TARGET/settings.json" "bash-gate.sh"
assert_contains "bash-audit hook 등록됨"  "$TARGET/settings.json" "bash-audit.sh"
assert_contains "completion-gate 등록됨"  "$TARGET/settings.json" "completion-gate.sh"
assert_contains "subagent-track 등록됨"   "$TARGET/settings.json" "subagent-track.sh"
assert_contains "subagent-cleanup 등록됨" "$TARGET/settings.json" "subagent-cleanup.sh"
assert_contains "AGENT_TEAMS env 등록됨"  "$TARGET/settings.json" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
assert_contains "SessionStart hook 등록됨"  "$TARGET/settings.json" "bouncer-update-check.sh"

# CLAUDE.md
assert_file "CLAUDE.md 생성됨"  "$TARGET/CLAUDE.md"
assert_contains "bouncer 규칙 주입됨"  "$TARGET/CLAUDE.md" "ai-bouncer-rule"

# executable
assert_ok "plan-gate.sh 실행 가능"    test -x "$TARGET/ai-bouncer/hooks/plan-gate.sh"
assert_ok "bash-gate.sh 실행 가능"    test -x "$TARGET/ai-bouncer/hooks/bash-gate.sh"
assert_ok "subagent-track.sh 실행 가능" test -x "$TARGET/ai-bouncer/hooks/subagent-track.sh"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 3. 설치된 hooks로 기능 테스트 ───${NC}"

HOOKS_DIR="$TARGET/ai-bouncer/hooks"

# 테스트용 task 디렉토리 생성
TASK_DIR="$REPO_DIR/.ai-bouncer-tasks/2099-01-01/e2e-test"
mkdir -p "$TASK_DIR"
TEST_SID="e2e-test-$$"

setup_state() {
  local mode="$1" phase="$2" approved="$3"
  python3 -c "
import json, os
d = '$TASK_DIR'
s = {'mode':'$mode','workflow_phase':'$phase','plan_approved':('$approved'=='true'),
     'planning':{'no_question_streak':0},'team_name':'','current_dev_phase':0,'current_step':0,
     'dev_phases':{},'verification':{'rounds_passed':0},'task_dir':d,'active_file':d+'/.active','persistent_mode':False}
with open(os.path.join(d,'state.json'),'w') as f: json.dump(s,f,indent=2)
"
  echo "$TEST_SID" > "$TASK_DIR/.active"
  # plan.md 생성 (plan-gate가 파일 존재 검증)
  echo "# Test Plan" > "$TASK_DIR/plan.md"
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot
}

run_hook() {
  local hook="$1" input="$2"
  (cd "$REPO_DIR" && echo "$input" | bash "$HOOKS_DIR/$hook" 2>/dev/null) || true
}

is_blocked() {
  echo "$1" | grep -q '"block"' 2>/dev/null
}

# plan-gate 테스트
setup_state "simple" "development" "true"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$TEST_SID\"}")
if is_blocked "$R"; then fail "plan-gate: approved → 통과"; else pass "plan-gate: approved → 통과"; fi

setup_state "simple" "planning" "false"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO_DIR/src/test.py\"},\"session_id\":\"$TEST_SID\"}")
if is_blocked "$R"; then pass "plan-gate: planning → 차단"; else fail "plan-gate: planning → 차단"; fi

# bash-gate 테스트
setup_state "simple" "development" "true"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls 2>/dev/null\"},\"session_id\":\"$TEST_SID\"}")
if is_blocked "$R"; then fail "bash-gate: 2>/dev/null → 오탐 아님"; else pass "bash-gate: 2>/dev/null → 오탐 아님"; fi

setup_state "simple" "planning" "false"
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$TEST_SID\"}")
if is_blocked "$R"; then pass "bash-gate: planning + 쓰기 → 차단"; else fail "bash-gate: planning + 쓰기 → 차단"; fi

# subagent-track 테스트
setup_state "simple" "development" "true"
(cd "$REPO_DIR" && echo "{\"session_id\":\"sub-e2e-001\",\"agent_id\":\"a1\"}" | bash "$HOOKS_DIR/subagent-track.sh" 2>/dev/null) || true
if grep -q "sub-e2e-001" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo -e "  ${GREEN}✅${NC} subagent-track: 등록됨"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}❌${NC} subagent-track: 등록 안 됨"
  FAIL=$((FAIL + 1))
fi

(cd "$REPO_DIR" && echo "{\"session_id\":\"sub-e2e-001\"}" | bash "$HOOKS_DIR/subagent-cleanup.sh" 2>/dev/null) || true
if ! grep -q "sub-e2e-001" /tmp/.ai-bouncer-approved-agents 2>/dev/null; then
  echo -e "  ${GREEN}✅${NC} subagent-cleanup: 제거됨"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}❌${NC} subagent-cleanup: 제거 안 됨"
  FAIL=$((FAIL + 1))
fi

# completion-gate 테스트
setup_state "simple" "development" "true"
R=$(run_hook completion-gate.sh "{\"session_id\":\"$TEST_SID\"}")
if is_blocked "$R"; then fail "completion-gate: SIMPLE → 스킵"; else pass "completion-gate: SIMPLE → 스킵"; fi

# 위임 에이전트 테스트
setup_state "simple" "development" "true"
echo "${TEST_SID}-sub|$TASK_DIR" > /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"${TEST_SID}-sub\"}")
if is_blocked "$R"; then fail "plan-gate: 위임 에이전트 → 통과"; else pass "plan-gate: 위임 에이전트 → 통과"; fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 4. Update (--update) ───${NC}"

(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -3

# 업데이트 후에도 파일이 존재하는지 확인
assert_file "update 후 plan-gate.sh 존재"   "$TARGET/ai-bouncer/hooks/plan-gate.sh"
assert_file "update 후 intent.md 존재"      "$TARGET/agents/intent.md"
assert_file "update 후 SKILL.md 존재"       "$TARGET/skills/dev-bounce/SKILL.md"
assert_file "update 후 settings.json 존재"  "$TARGET/settings.json"
assert_contains "update 후 hook 유지됨"     "$TARGET/settings.json" "plan-gate.sh"
assert_file "update 후 tc-guide.md 존재"    "$TARGET/agents/guides/tc-guide.md"
assert_file "update 후 hooks.json 존재"     "$TARGET/ai-bouncer/hooks/hooks.json"
assert_file "update 후 bouncer-update-check.sh 존재"  "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh"

# 커스텀 agent 보호 테스트
echo "custom agent" > "$TARGET/agents/my-custom-agent.md"
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -3
assert_file "update 후 커스텀 agent 보호됨" "$TARGET/agents/my-custom-agent.md"
rm -f "$TARGET/agents/my-custom-agent.md"

# 소스에 없는 agent 파일이 update 시 삭제되지 않는지 검증
echo "former-bouncer-agent" > "$TARGET/agents/old-removed-agent.md"
# manifest에 등록 (이전 버전에서 설치된 것처럼)
python3 -c "
import json
m = json.load(open('$TARGET/ai-bouncer/manifest.json'))
m['files'].append('agents/old-removed-agent.md')
json.dump(m, open('$TARGET/ai-bouncer/manifest.json', 'w'), indent=2)
"
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -3
assert_file "update 후 소스에 없는 agent 파일 유지됨" "$TARGET/agents/old-removed-agent.md"
rm -f "$TARGET/agents/old-removed-agent.md"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 5. Uninstall ───${NC}"

(cd "$REPO_DIR" && bash "$SRC_DIR/uninstall.sh") 2>&1 | tail -5

# 파일이 삭제되었는지 확인
assert_no_file "uninstall 후 plan-gate.sh 없음"    "$TARGET/ai-bouncer/hooks/plan-gate.sh"
assert_no_file "uninstall 후 bash-gate.sh 없음"    "$TARGET/ai-bouncer/hooks/bash-gate.sh"
assert_no_file "uninstall 후 bash-audit.sh 없음"   "$TARGET/ai-bouncer/hooks/bash-audit.sh"
assert_no_file "uninstall 후 intent.md 없음"       "$TARGET/agents/intent.md"
assert_no_file "uninstall 후 SKILL.md 없음"        "$TARGET/skills/dev-bounce/SKILL.md"
assert_no_file "uninstall 후 tc-guide.md 없음"     "$TARGET/agents/guides/tc-guide.md"
assert_no_file "uninstall 후 manifest.json 없음"   "$TARGET/ai-bouncer/manifest.json"
assert_no_file "uninstall 후 config.json 없음"     "$TARGET/ai-bouncer/config.json"
assert_no_file "uninstall 후 bouncer-update-check.sh 없음"  "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh"

# settings.json에서 bouncer hook이 제거되었는지 확인
if [ -f "$TARGET/settings.json" ]; then
  if grep -q "plan-gate.sh" "$TARGET/settings.json" 2>/dev/null; then
    fail "uninstall 후 settings.json에 hook 남아있음"
  else
    pass "uninstall 후 settings.json에서 hook 제거됨"
  fi
  if grep -q "bouncer-update-check.sh" "$TARGET/settings.json" 2>/dev/null; then
    fail "uninstall 후 settings.json에 SessionStart hook 남아있음"
  else
    pass "uninstall 후 settings.json에서 SessionStart hook 제거됨"
  fi
else
  pass "uninstall 후 settings.json 정리됨"
fi

# CLAUDE.md에서 bouncer 규칙이 제거되었는지 확인
if [ -f "$TARGET/CLAUDE.md" ]; then
  if grep -q "ai-bouncer-rule" "$TARGET/CLAUDE.md" 2>/dev/null; then
    fail "uninstall 후 CLAUDE.md에 bouncer 규칙 남아있음"
  else
    pass "uninstall 후 CLAUDE.md에서 bouncer 규칙 제거됨"
  fi
else
  pass "uninstall 후 CLAUDE.md 정리됨"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 6. Re-install (uninstall 후 재설치) ───${NC}"

(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --ci) 2>&1 | tail -3

assert_file "재설치 후 plan-gate.sh 존재"     "$TARGET/ai-bouncer/hooks/plan-gate.sh"
assert_file "재설치 후 settings.json 존재"    "$TARGET/settings.json"
assert_file "재설치 후 CLAUDE.md 존재"        "$TARGET/CLAUDE.md"
assert_contains "재설치 후 hook 등록됨"       "$TARGET/settings.json" "plan-gate.sh"
assert_contains "재설치 후 bouncer 규칙 주입" "$TARGET/CLAUDE.md" "ai-bouncer-rule"
assert_file "재설치 후 bouncer-update-check.sh 존재"  "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh"
assert_contains "재설치 후 SessionStart hook 등록됨"  "$TARGET/settings.json" "bouncer-update-check.sh"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 7. CLAUDE.md 콘텐츠 보존 ───${NC}"

# 깨끗한 상태에서 다시 시작: uninstall → 사용자 콘텐츠 작성 → install → 검증
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --uninstall) 2>&1 | tail -2

# 사용자 고유 콘텐츠가 있는 CLAUDE.md 작성
mkdir -p "$TARGET"
cat > "$TARGET/CLAUDE.md" <<'USEREOF'
# My Project Rules

## UI 버그 수정 원칙
- 진단 먼저 → 단일 수정 → 테스트 → 커밋

## CSS 원칙
- 전체 parent→child chain 분석 후 수정
USEREOF

# CM-1: install 후 기존 콘텐츠 보존
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --ci) 2>&1 | tail -2
if grep -q "UI 버그 수정 원칙" "$TARGET/CLAUDE.md" 2>/dev/null && \
   grep -q "ai-bouncer-rule" "$TARGET/CLAUDE.md" 2>/dev/null; then
  pass "CM-1: install 후 사용자 콘텐츠 + bouncer 규칙 공존"
else
  fail "CM-1: install 후 사용자 콘텐츠가 사라짐"
fi

# CM-2: update 후 기존 콘텐츠 보존
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -2
if grep -q "CSS 원칙" "$TARGET/CLAUDE.md" 2>/dev/null && \
   grep -q "ai-bouncer-rule" "$TARGET/CLAUDE.md" 2>/dev/null; then
  pass "CM-2: update 후 사용자 콘텐츠 보존"
else
  fail "CM-2: update 후 사용자 콘텐츠가 사라짐"
fi

# CM-3: uninstall 후 사용자 콘텐츠 보존 + bouncer 규칙 제거
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --uninstall) 2>&1 | tail -2
if grep -q "UI 버그 수정 원칙" "$TARGET/CLAUDE.md" 2>/dev/null && \
   ! grep -q "ai-bouncer-rule" "$TARGET/CLAUDE.md" 2>/dev/null; then
  pass "CM-3: uninstall 후 사용자 콘텐츠 보존 + bouncer 제거"
else
  fail "CM-3: uninstall 후 사용자 콘텐츠 손실 또는 bouncer 잔존"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 8. 백업 파일 정리 ───${NC}"

# 다시 install
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --ci) 2>&1 | tail -2

# BK-1: 최초 install 후 backup 파일 없음
BK_COUNT=$(find "$TARGET" -name "*.backup-*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$BK_COUNT" = "0" ]; then
  pass "BK-1: 최초 install 후 backup 파일 없음"
else
  fail "BK-1: 최초 install 후 backup 파일 ${BK_COUNT}개 잔존"
fi

# BK-2: update 후 backup 파일 정리됨
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -2
BK_COUNT=$(find "$TARGET" -name "*.backup-*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$BK_COUNT" = "0" ]; then
  pass "BK-2: update 후 backup 파일 정리됨"
else
  fail "BK-2: update 후 backup 파일 ${BK_COUNT}개 잔존"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 9. 기존 hook 보존 ───${NC}"

# uninstall → 기존 non-bouncer Stop hook 등록 → install → 보존 확인
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --uninstall) 2>&1 | tail -2

# 사용자의 기존 Stop hook을 settings.json에 등록
python3 -c "
import json, os
sf = '$TARGET/settings.json'
cfg = {}
if os.path.exists(sf):
    cfg = json.load(open(sf))
hooks = cfg.setdefault('hooks', {})
stop = hooks.setdefault('Stop', [])
stop.append({'hooks': [{'type': 'command', 'command': '/tmp/test-user-stop-hook.sh', 'timeout': 10}]})
with open(sf, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"

# HP-1: install 후 기존 Stop hook 보존
(cd "$REPO_DIR" && bash "$SRC_DIR/install.sh" --ci) 2>&1 | tail -3
if grep -q "test-user-stop-hook.sh" "$TARGET/settings.json" 2>/dev/null; then
  pass "HP-1: install 후 기존 non-bouncer Stop hook 보존됨"
else
  fail "HP-1: install 후 기존 non-bouncer Stop hook 유실됨"
fi

# HP-2: install 후 bouncer Stop hook도 등록됨
if grep -q "completion-gate.sh" "$TARGET/settings.json" 2>/dev/null; then
  pass "HP-2: install 후 bouncer Stop hook 등록됨"
else
  fail "HP-2: install 후 bouncer Stop hook 미등록"
fi

# HP-3: update 후 기존 Stop hook 보존
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -2
if grep -q "test-user-stop-hook.sh" "$TARGET/settings.json" 2>/dev/null; then
  pass "HP-3: update 후 기존 non-bouncer Stop hook 보존됨"
else
  fail "HP-3: update 후 기존 non-bouncer Stop hook 유실됨"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 10. 헬스체크 ───${NC}"

# HC-1: 정상 설치 후 --health 경고 없음
HC_OUT=$((cd "$REPO_DIR" && bash "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh" --health) 2>&1) || true
if echo "$HC_OUT" | grep -q "손상 감지"; then
  fail "HC-1: 정상 설치인데 헬스체크 경고 발생: $HC_OUT"
else
  pass "HC-1: 정상 설치 후 헬스체크 통과"
fi

# HC-2: hook 파일 삭제 후 --health 경고 출력
mv "$TARGET/ai-bouncer/hooks/plan-gate.sh" "$TARGET/ai-bouncer/hooks/plan-gate.sh.bak"
HC_OUT=$((cd "$REPO_DIR" && bash "$TARGET/ai-bouncer/scripts/bouncer-update-check.sh" --health) 2>&1) || true
if echo "$HC_OUT" | grep -q "plan-gate.sh"; then
  pass "HC-2: hook 삭제 후 헬스체크 경고 출력됨"
else
  fail "HC-2: hook 삭제 후 헬스체크 경고 미출력"
fi
mv "$TARGET/ai-bouncer/hooks/plan-gate.sh.bak" "$TARGET/ai-bouncer/hooks/plan-gate.sh"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 11. 업데이트 백업 ───${NC}"

# BU-1: agent 파일 수정 후 update.sh → .pre-update 백업 존재
echo "# custom modification" >> "$TARGET/agents/dev.md"
(cd "$REPO_DIR" && bash "$SRC_DIR/update.sh") 2>&1 | tail -3
if [ -f "$TARGET/agents/dev.md.pre-update" ]; then
  pass "BU-1: update 후 수정된 agent 백업 생성됨"
else
  fail "BU-1: update 후 .pre-update 백업 없음"
fi
rm -f "$TARGET/agents/dev.md.pre-update"

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 12. 전역 gitignore ───${NC}"

# GG-1: --global 설치 시 전역 gitignore에 .ai-bouncer-tasks/ 추가
GLOBAL_REPO_DIR="$TEST_DIR/global-test-repo"
git init "$GLOBAL_REPO_DIR" -q
FAKE_HOME="$TEST_DIR/fake-home"
mkdir -p "$FAKE_HOME"
# 전역 설치 시뮬레이션 (HOME 오버라이드, TARGET_DIR 오버라이드)
(cd "$GLOBAL_REPO_DIR" && HOME="$FAKE_HOME" TARGET_DIR="$FAKE_HOME/.claude" \
   bash "$SRC_DIR/install.sh" --global --ci) 2>&1 | tail -3

GLOBAL_GI=$(HOME="$FAKE_HOME" git config --global core.excludesfile 2>/dev/null || echo "")
GLOBAL_GI="${GLOBAL_GI/#\~/$FAKE_HOME}"
if [ -z "$GLOBAL_GI" ]; then
  GLOBAL_GI="$FAKE_HOME/.gitignore_global"
fi

if grep -qF ".ai-bouncer-tasks/" "$GLOBAL_GI" 2>/dev/null; then
  pass "GG-1: 전역 설치 시 .ai-bouncer-tasks/ → 전역 gitignore 추가됨"
else
  fail "GG-1: 전역 설치 시 .ai-bouncer-tasks/ 전역 gitignore 미추가 (file: $GLOBAL_GI)"
fi

# GG-2: 중복 실행 시 .ai-bouncer-tasks/ 중복 추가 안 됨
(cd "$GLOBAL_REPO_DIR" && HOME="$FAKE_HOME" TARGET_DIR="$FAKE_HOME/.claude" \
   bash "$SRC_DIR/install.sh" --global --ci) 2>&1 | tail -1
COUNT=$(grep -c "\.ai-bouncer-tasks/" "$GLOBAL_GI" 2>/dev/null || echo 0)
if [ "$COUNT" -eq 1 ]; then
  pass "GG-2: 중복 설치 시 .ai-bouncer-tasks/ 중복 없음"
else
  fail "GG-2: .ai-bouncer-tasks/ 중복 추가됨 (count: $COUNT)"
fi

# GG-3: 로컬 설치 시 전역 gitignore 건드리지 않음
# (로컬 설치는 이미 위에서 완료됨 — FAKE_HOME 전역 gi와 무관해야 함)
LOCAL_FAKE_HOME="$TEST_DIR/local-fake-home"
mkdir -p "$LOCAL_FAKE_HOME"
if grep -qF ".ai-bouncer-tasks/" "$LOCAL_FAKE_HOME/.gitignore_global" 2>/dev/null; then
  fail "GG-3: 로컬 설치가 전역 gitignore를 수정함"
else
  pass "GG-3: 로컬 설치는 전역 gitignore 미수정"
fi

# ═══════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 13. 정리 ───${NC}"

rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot
# TEST_DIR은 trap이 정리

echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${GREEN}✅ $PASS 통과${NC} / ${RED}❌ $FAIL 실패${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

exit $FAIL
