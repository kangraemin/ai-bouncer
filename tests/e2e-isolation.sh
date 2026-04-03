#!/bin/bash
# E2E Isolation Test — hooks/scripts가 ai-bouncer/ 하위에 격리 설치되는지 검증
# Usage: bash tests/e2e-isolation.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✅${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}❌${NC} $1"; FAIL=$((FAIL + 1)); }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_no() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc — 존재하면 안 됨"; fi
}

SRC_DIR="$(git rev-parse --show-toplevel)"

echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer Isolation E2E Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

# ── 테스트 환경 ─────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

setup_local_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init "$repo" -q
  git -C "$repo" -c user.email=test@test.com -c user.name=Test commit --allow-empty -m "init" -q 2>/dev/null
}

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 1. 로컬 신규 설치 ───${NC}"

REPO1="$TEST_DIR/local-install"
setup_local_repo "$REPO1"
(cd "$REPO1" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null

T="$REPO1/.claude"

# hooks in ai-bouncer/
check "L1: plan-gate.sh in ai-bouncer/hooks" test -f "$T/ai-bouncer/hooks/plan-gate.sh"
check "L2: bash-gate.sh in ai-bouncer/hooks" test -f "$T/ai-bouncer/hooks/bash-gate.sh"
check "L3: completion-gate.sh in ai-bouncer/hooks" test -f "$T/ai-bouncer/hooks/completion-gate.sh"

# lib in ai-bouncer/hooks/lib/
check "L4: resolve-task.sh in ai-bouncer/hooks/lib" test -f "$T/ai-bouncer/hooks/lib/resolve-task.sh"

# scripts in ai-bouncer/scripts/
check "L5: update-check.sh in ai-bouncer/scripts" test -f "$T/ai-bouncer/scripts/update-check.sh"

# config/manifest
check "L6: config.json in ai-bouncer" test -f "$T/ai-bouncer/config.json"
check "L7: manifest.json in ai-bouncer" test -f "$T/ai-bouncer/manifest.json"

# hooks.json
check "L8: hooks.json in ai-bouncer/hooks" test -f "$T/ai-bouncer/hooks/hooks.json"

# agents/skills in original location
check "L9: intent.md in agents/" test -f "$T/agents/intent.md"
check "L10: SKILL.md in skills/" test -f "$T/skills/dev-bounce/SKILL.md"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 2. 격리 검증 (구 경로에 bouncer 파일 없음) ───${NC}"

# .claude/hooks/에 bouncer 파일 0개
check_no "ISO1: 구 경로 hooks/plan-gate.sh 없음" test -f "$T/hooks/plan-gate.sh"
check_no "ISO2: 구 경로 hooks/bash-gate.sh 없음" test -f "$T/hooks/bash-gate.sh"
check_no "ISO3: 구 경로 hooks/hooks.json 없음" test -f "$T/hooks/hooks.json"

# .claude/scripts/에 bouncer 파일 0개
check_no "ISO4: 구 경로 scripts/update-check.sh 없음" test -f "$T/scripts/update-check.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 3. settings.json hook 경로 검증 ───${NC}"

SETTINGS="$T/settings.json"
check "S1: settings.json에 ai-bouncer/hooks/plan-gate 포함" grep -q "ai-bouncer/hooks/plan-gate" "$SETTINGS"
check "S2: settings.json에 ai-bouncer/hooks/bash-gate 포함" grep -q "ai-bouncer/hooks/bash-gate" "$SETTINGS"
check "S3: settings.json에 ai-bouncer/scripts/update-check 포함" grep -q "ai-bouncer/scripts/update-check" "$SETTINGS"

# 모든 hook 경로에 ai-bouncer 포함 확인
HOOK_COUNT=$(python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {})
total = 0
has_bouncer = 0
for ht, groups in hooks.items():
    for g in groups:
        for h in g.get('hooks', []):
            cmd = h.get('command', '')
            if cmd:
                total += 1
                if 'ai-bouncer/' in cmd:
                    has_bouncer += 1
print(f'{has_bouncer}/{total}')
" 2>/dev/null)
if [ "$HOOK_COUNT" != "0/0" ] && [ "${HOOK_COUNT%/*}" = "${HOOK_COUNT#*/}" ]; then
  pass "S4: 모든 hook 경로에 ai-bouncer/ 포함 ($HOOK_COUNT)"
else
  fail "S4: 일부 hook 경로에 ai-bouncer/ 미포함 ($HOOK_COUNT)"
fi

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 4. Hook 실행 가능 검증 ───${NC}"

check "H1: plan-gate.sh 실행 권한" test -x "$T/ai-bouncer/hooks/plan-gate.sh"
check "H2: bash-gate.sh 실행 권한" test -x "$T/ai-bouncer/hooks/bash-gate.sh"
check "H3: completion-gate.sh 실행 권한" test -x "$T/ai-bouncer/hooks/completion-gate.sh"
check "H4: resolve-task.sh 실행 권한" test -x "$T/ai-bouncer/hooks/lib/resolve-task.sh"
check "H5: update-check.sh 실행 권한" test -x "$T/ai-bouncer/scripts/update-check.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 5. 로컬 uninstall — 완전 삭제 ───${NC}"

# 사용자 파일 생성 (보존 확인용)
mkdir -p "$T/hooks" "$T/agents" "$T/skills/user-skill"
echo "user hook" > "$T/hooks/user-hook.sh"
echo "user agent" > "$T/agents/user-agent.md"
echo "user skill" > "$T/skills/user-skill/SKILL.md"

(cd "$REPO1" && bash "$SRC_DIR/uninstall.sh") 2>&1 >/dev/null

# ai-bouncer/ 디렉토리 완전 삭제
check_no "UL1: ai-bouncer/ 디렉토리 삭제됨" test -d "$T/ai-bouncer"

# agents/skills 삭제
check_no "UL2: intent.md 삭제됨" test -f "$T/agents/intent.md"
check_no "UL3: dev-bounce SKILL.md 삭제됨" test -f "$T/skills/dev-bounce/SKILL.md"

# settings.json 정리
if [ -f "$SETTINGS" ]; then
  check_no "UL4: settings.json에 plan-gate 없음" grep -q "plan-gate" "$SETTINGS"
else
  pass "UL4: settings.json에 plan-gate 없음 (파일 자체 정리됨)"
fi

# 사용자 파일 보존
check "UL5: 사용자 hook 보존됨" test -f "$T/hooks/user-hook.sh"
check "UL6: 사용자 agent 보존됨" test -f "$T/agents/user-agent.md"
check "UL7: 사용자 skill 보존됨" test -f "$T/skills/user-skill/SKILL.md"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 6. 마이그레이션 (구 경로 → 신 경로) ───${NC}"

REPO2="$TEST_DIR/migrate-test"
setup_local_repo "$REPO2"
T2="$REPO2/.claude"

# 구 레이아웃 시뮬레이션: hooks를 .claude/hooks/에 직접 배치
mkdir -p "$T2/hooks/lib" "$T2/scripts" "$T2/ai-bouncer" "$T2/agents"
cp "$SRC_DIR/hooks/hooks.json" "$T2/hooks/hooks.json"
for hook in plan-gate.sh bash-gate.sh bash-audit.sh doc-reminder.sh completion-gate.sh subagent-track.sh subagent-cleanup.sh stop-active-cleanup.sh; do
  [ -f "$SRC_DIR/hooks/$hook" ] && cp "$SRC_DIR/hooks/$hook" "$T2/hooks/$hook" && chmod +x "$T2/hooks/$hook"
done
for lib in "$SRC_DIR/hooks/lib/"*.sh; do
  [ -f "$lib" ] && cp "$lib" "$T2/hooks/lib/$(basename "$lib")" && chmod +x "$T2/hooks/lib/$(basename "$lib")"
done
cp "$SRC_DIR/scripts/update-check.sh" "$T2/scripts/update-check.sh" && chmod +x "$T2/scripts/update-check.sh"

# 사용자 hook (마이그레이션 중 보존 확인)
echo "my hook" > "$T2/hooks/on-commit.sh"
chmod +x "$T2/hooks/on-commit.sh"

# manifest.json 시뮬레이션 (update 모드 감지용)
cat > "$T2/ai-bouncer/manifest.json" <<'JSON'
{"version":"test","files":["hooks/plan-gate.sh"]}
JSON
cat > "$T2/ai-bouncer/config.json" <<'JSON'
{"enforcement_mode":"hooks","agent_mode":"team","commit_strategy":"per-step"}
JSON

# install --update 실행 → 마이그레이션 트리거
(cd "$REPO2" && bash "$SRC_DIR/install.sh" --ci --update) 2>&1 >/dev/null

# 신 경로에 hook 이동
check "M1: 마이그레이션 후 ai-bouncer/hooks/plan-gate.sh 존재" test -f "$T2/ai-bouncer/hooks/plan-gate.sh"

# 구 경로에서 bouncer hook 제거
check_no "M2: 마이그레이션 후 hooks/plan-gate.sh 없음" test -f "$T2/hooks/plan-gate.sh"
check_no "M3: 마이그레이션 후 hooks/hooks.json 없음" test -f "$T2/hooks/hooks.json"

# settings.json 경로 갱신
M_SETTINGS="$T2/settings.json"
check "M4: 마이그레이션 후 settings.json에 ai-bouncer/hooks 포함" grep -q "ai-bouncer/hooks" "$M_SETTINGS"

# 사용자 hook 보존
check "M5: 마이그레이션 후 사용자 hook(on-commit.sh) 보존" test -f "$T2/hooks/on-commit.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 7. 재설치/업데이트 사이클 ───${NC}"

REPO3="$TEST_DIR/cycle-test"
setup_local_repo "$REPO3"
T3="$REPO3/.claude"

# install → uninstall → install
(cd "$REPO3" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
(cd "$REPO3" && bash "$SRC_DIR/uninstall.sh") 2>&1 >/dev/null
(cd "$REPO3" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
check "R1: install→uninstall→install 후 plan-gate.sh 존재" test -f "$T3/ai-bouncer/hooks/plan-gate.sh"
check "R2: install→uninstall→install 후 config.json 존재" test -f "$T3/ai-bouncer/config.json"

# install → install(update) → uninstall → 잔여물 0
(cd "$REPO3" && bash "$SRC_DIR/install.sh" --ci --update) 2>&1 >/dev/null
(cd "$REPO3" && bash "$SRC_DIR/uninstall.sh") 2>&1 >/dev/null
check_no "R3: update→uninstall 후 ai-bouncer/ 없음" test -d "$T3/ai-bouncer"
check_no "R4: update→uninstall 후 agents/intent.md 없음" test -f "$T3/agents/intent.md"

# update.sh 실행 후 경로 유지
(cd "$REPO3" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
(cd "$REPO3" && bash "$SRC_DIR/update.sh") 2>&1 >/dev/null
check "R5: update.sh 후 ai-bouncer/hooks/plan-gate.sh 존재" test -f "$T3/ai-bouncer/hooks/plan-gate.sh"
check "R6: update.sh 후 ai-bouncer/hooks/hooks.json 존재" test -f "$T3/ai-bouncer/hooks/hooks.json"

# manifest.json files 배열 확인
check "R7: update.sh 후 manifest.json 존재" test -f "$T3/ai-bouncer/manifest.json"
MANIFEST_HAS_BOUNCER=$(python3 -c "
import json
m = json.load(open('$T3/ai-bouncer/manifest.json'))
files = m.get('files', [])
has = any('ai-bouncer/hooks/' in f for f in files)
print('yes' if has else 'no')
" 2>/dev/null)
if [ "$MANIFEST_HAS_BOUNCER" = "yes" ]; then
  pass "R8: manifest files에 ai-bouncer/hooks/ 경로 포함"
else
  fail "R8: manifest files에 ai-bouncer/hooks/ 경로 미포함"
fi

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 8. --config 모드 ───${NC}"

REPO4="$TEST_DIR/config-test"
setup_local_repo "$REPO4"
T4="$REPO4/.claude"

(cd "$REPO4" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null

# --config로 설정 변경
(cd "$REPO4" && echo "2" | bash "$SRC_DIR/install.sh" --config) 2>&1 >/dev/null || true

# config 후 config.json 존재
check "C1: --config 후 config.json 존재" test -f "$T4/ai-bouncer/config.json"

# config 후 hook 파일은 그대로
check "C2: --config 후 plan-gate.sh 그대로 존재" test -f "$T4/ai-bouncer/hooks/plan-gate.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 9. 에지케이스 ───${NC}"

# --ci 플래그 비대화형 설치
REPO6="$TEST_DIR/ci-test"
setup_local_repo "$REPO6"
(cd "$REPO6" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
check "E1: --ci 플래그 비대화형 설치 성공" test -f "$REPO6/.claude/ai-bouncer/config.json"

# 이미 설치된 상태에서 재설치 → 업데이트 모드
(cd "$REPO6" && bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
check "E2: 재설치 시 config.json 유지" test -f "$REPO6/.claude/ai-bouncer/config.json"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 결과 ───${NC}"

echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${GREEN}✅ $PASS 통과${NC} / ${RED}❌ $FAIL 실패${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
