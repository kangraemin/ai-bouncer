#!/bin/bash
# E2E Recovery Test — 문제 상황 시뮬레이션 → install/update/uninstall 복구 검증
# Usage: bash tests/e2e-recovery.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
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
  if ! "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

SRC_DIR="$(git rev-parse --show-toplevel)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

setup_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init "$repo" -q
  git -C "$repo" -c user.email=test@test.com -c user.name=Test commit --allow-empty -m "init" -q 2>/dev/null
}

# HOME을 격리하여 글로벌 설치 간섭 방지
fresh_install() {
  local repo="$1"
  local fake_home="$TEST_DIR/home-$(basename "$repo")"
  mkdir -p "$fake_home/.claude"
  setup_repo "$repo"
  (cd "$repo" && HOME="$fake_home" bash "$SRC_DIR/install.sh" --ci) 2>&1 >/dev/null
}

run_update() {
  local repo="$1"
  local fake_home="$TEST_DIR/home-$(basename "$repo")"
  (cd "$repo" && HOME="$fake_home" bash "$SRC_DIR/update.sh") 2>&1
}

run_uninstall() {
  local repo="$1"
  local fake_home="$TEST_DIR/home-$(basename "$repo")"
  (cd "$repo" && HOME="$fake_home" bash "$SRC_DIR/uninstall.sh") 2>&1
}

run_install_update() {
  local repo="$1"
  local fake_home="$TEST_DIR/home-$(basename "$repo")"
  (cd "$repo" && HOME="$fake_home" bash "$SRC_DIR/install.sh" --ci --update) 2>&1
}

run_install_fresh() {
  local repo="$1"
  local fake_home="$TEST_DIR/home-$(basename "$repo")"
  (cd "$repo" && HOME="$fake_home" bash "$SRC_DIR/install.sh" --ci) 2>&1
}

echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer Recovery E2E Tests (43 TC)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── A. config.json 손상/누락 ───${NC}"

# A1: config.json 삭제 → update.sh → 에러
R="$TEST_DIR/a1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/config.json"
if ! run_update "$R" >/dev/null; then
  pass "A1: config.json 삭제 → update.sh 에러 (exit 1)"
else
  fail "A1: config.json 삭제 → update.sh가 에러 없이 성공함"
fi

# A2: config 필드 누락 → install --ci --update (기본값 폴백)
R="$TEST_DIR/a2"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/ai-bouncer/config.json'
c = json.load(open(p))
c.pop('enforcement_mode', None)
c.pop('agent_mode', None)
json.dump(c, open(p, 'w'))
"
run_install_update "$R" >/dev/null || true
check "A2: 필드 누락 → --update 후 enforcement_mode 존재" python3 -c "
import json; c=json.load(open('$R/.claude/ai-bouncer/config.json'))
assert 'enforcement_mode' in c, 'missing'
"

# A3: config 깨진 JSON → install --update
R="$TEST_DIR/a3"; fresh_install "$R"
echo '{invalid' > "$R/.claude/ai-bouncer/config.json"
run_install_update "$R" >/dev/null || true
check "A3: 깨진 config → --update 후 유효 JSON" python3 -c "
import json; json.load(open('$R/.claude/ai-bouncer/config.json'))
"
check "A3: hook 파일 정상 존재" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"

# A4: config 빈 파일 → install --update
R="$TEST_DIR/a4"; fresh_install "$R"
: > "$R/.claude/ai-bouncer/config.json"
run_install_update "$R" >/dev/null || true
check "A4: 빈 config → --update 후 enforcement_mode 존재" python3 -c "
import json; c=json.load(open('$R/.claude/ai-bouncer/config.json'))
assert 'enforcement_mode' in c
"

# A5: 알 수 없는 필드만 → install --ci --update
R="$TEST_DIR/a5"; fresh_install "$R"
python3 -c "
import json
json.dump({'unknown_field': 'test_value'}, open('$R/.claude/ai-bouncer/config.json', 'w'))
"
run_install_update "$R" >/dev/null || true
check "A5: unknown 필드 → --update 후 기본값 폴백" python3 -c "
import json; c=json.load(open('$R/.claude/ai-bouncer/config.json'))
assert c.get('enforcement_mode') == 'hooks'
"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── B. manifest.json 손상/누락 ───${NC}"

# B1: manifest 삭제 → install
R="$TEST_DIR/b1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/manifest.json"
run_install_fresh "$R" >/dev/null
check "B1: manifest 삭제 → install 후 재생성" test -f "$R/.claude/ai-bouncer/manifest.json"
check "B1: hook 파일도 존재" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"

# B2: manifest 깨진 JSON → uninstall
R="$TEST_DIR/b2"; fresh_install "$R"
echo '{broken' > "$R/.claude/ai-bouncer/manifest.json"
UNINSTALL_OUT=$( run_uninstall "$R" || true )
if echo "$UNINSTALL_OUT" | grep -q "매니페스트 읽기 실패"; then
  pass "B2: 깨진 manifest → uninstall 경고 출력"
else
  fail "B2: 깨진 manifest → uninstall 경고 미출력"
fi
check "B2: settings.json에서 hook 제거됨" python3 -c "
import json; c=json.load(open('$R/.claude/settings.json'))
hooks = c.get('hooks', {})
for ht in ['PreToolUse', 'PostToolUse']:
    assert ht not in hooks, f'{ht} still exists'
"

# B3: manifest files 빈 배열 → uninstall
R="$TEST_DIR/b3"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/ai-bouncer/manifest.json'
m = json.load(open(p)); m['files'] = []
json.dump(m, open(p, 'w'))
"
run_uninstall "$R" 2>&1 >/dev/null
check_no "B3: files 비어있음 → uninstall 후 ai-bouncer/ 삭제" test -d "$R/.claude/ai-bouncer"

# B4: manifest에 없는 파일 추가 → uninstall
R="$TEST_DIR/b4"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/ai-bouncer/manifest.json'
m = json.load(open(p)); m['files'].append('nonexistent/fake-file.sh')
json.dump(m, open(p, 'w'))
"
run_uninstall "$R" 2>&1 >/dev/null
RET=$?
check "B4: 없는 파일 → uninstall 정상 완료" test "$RET" -eq 0

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── C. Hook 파일 누락/손상 ───${NC}"

# C1: hook 2개 삭제 → update
R="$TEST_DIR/c1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh" "$R/.claude/ai-bouncer/hooks/bash-gate.sh"
run_update "$R" 2>&1 >/dev/null
check "C1: hook 삭제 → update 후 plan-gate.sh 복원" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"
check "C1: hook 삭제 → update 후 bash-gate.sh 복원" test -f "$R/.claude/ai-bouncer/hooks/bash-gate.sh"
check "C1: 실행 권한 복원" test -x "$R/.claude/ai-bouncer/hooks/plan-gate.sh"

# C2: hooks.json 삭제 → update
R="$TEST_DIR/c2"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/hooks/hooks.json"
run_update "$R" 2>&1 >/dev/null
check "C2: hooks.json 삭제 → update 후 복원" test -f "$R/.claude/ai-bouncer/hooks/hooks.json"

# C3: hooks/lib/ 통째 삭제 → update
R="$TEST_DIR/c3"; fresh_install "$R"
rm -rf "$R/.claude/ai-bouncer/hooks/lib"
run_update "$R" 2>&1 >/dev/null
check "C3: lib/ 삭제 → update 후 resolve-task.sh 복원" test -f "$R/.claude/ai-bouncer/hooks/lib/resolve-task.sh"
check "C3: 실행 권한" test -x "$R/.claude/ai-bouncer/hooks/lib/resolve-task.sh"

# C4: 모든 hook 삭제 → update
R="$TEST_DIR/c4"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/hooks/"*.sh
run_update "$R" 2>&1 >/dev/null
check "C4: 전체 hook 삭제 → update 후 plan-gate.sh 존재" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"
check "C4: bash-audit.sh 존재" test -f "$R/.claude/ai-bouncer/hooks/bash-audit.sh"
check "C4: completion-gate.sh 존재" test -f "$R/.claude/ai-bouncer/hooks/completion-gate.sh"

# C5: hook 내용 비우기 → update
R="$TEST_DIR/c5"; fresh_install "$R"
: > "$R/.claude/ai-bouncer/hooks/plan-gate.sh"
run_update "$R" 2>&1 >/dev/null
check "C5: 빈 hook → update 후 크기 > 0" test -s "$R/.claude/ai-bouncer/hooks/plan-gate.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── D. settings.json 불일치 ───${NC}"

# D1: PreToolUse 삭제 → install --update
R="$TEST_DIR/d1"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/settings.json'
c = json.load(open(p)); c.get('hooks', {}).pop('PreToolUse', None)
json.dump(c, open(p, 'w'), indent=2)
"
run_install_update "$R" 2>&1 >/dev/null
check "D1: PreToolUse 삭제 → --update 후 plan-gate 등록" grep -q "plan-gate" "$R/.claude/settings.json"

# D2: hooks 키 전체 삭제 → install --update
R="$TEST_DIR/d2"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/settings.json'
c = json.load(open(p)); c.pop('hooks', None)
json.dump(c, open(p, 'w'), indent=2)
"
run_install_update "$R" 2>&1 >/dev/null
check "D2: hooks 삭제 → --update 후 PreToolUse 존재" python3 -c "
import json; c=json.load(open('$R/.claude/settings.json'))
assert 'PreToolUse' in c.get('hooks', {})
"

# D3: settings.json 삭제 → install --update
R="$TEST_DIR/d3"; fresh_install "$R"
rm -f "$R/.claude/settings.json"
run_install_update "$R" 2>&1 >/dev/null
check "D3: settings.json 삭제 → --update 후 재생성" test -f "$R/.claude/settings.json"
check "D3: hook 등록됨" grep -q "plan-gate" "$R/.claude/settings.json"

# D4: settings 빈 객체 → install --update
R="$TEST_DIR/d4"; fresh_install "$R"
echo '{}' > "$R/.claude/settings.json"
run_install_update "$R" 2>&1 >/dev/null
check "D4: 빈 settings → --update 후 AGENT_TEAMS env 등록" grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "$R/.claude/settings.json"
check "D4: hook 등록됨" grep -q "plan-gate" "$R/.claude/settings.json"

# D5: 사용자 hook 보존
R="$TEST_DIR/d5"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/settings.json'
c = json.load(open(p))
hooks = c.setdefault('hooks', {})
custom = hooks.setdefault('PreToolUse', [])
custom.append({'hooks': [{'type': 'command', 'command': '/usr/local/bin/my-custom-hook.sh'}]})
json.dump(c, open(p, 'w'), indent=2)
"
run_install_update "$R" 2>&1 >/dev/null
check "D5: 사용자 hook 보존" grep -q "my-custom-hook" "$R/.claude/settings.json"
check "D5: bouncer hook도 존재" grep -q "plan-gate" "$R/.claude/settings.json"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── E. CLAUDE.md 손상 ───${NC}"

# E1: end 마커만 삭제 → install --update
R="$TEST_DIR/e1"; fresh_install "$R"
python3 -c "
content = open('$R/.claude/CLAUDE.md', encoding='utf-8').read()
content = content.replace('# --- ai-bouncer-rule end ---', '')
open('$R/.claude/CLAUDE.md', 'w', encoding='utf-8').write(content)
"
run_install_update "$R" 2>&1 >/dev/null
check "E1: end 마커 삭제 → --update 후 bouncer rule 존재" grep -q "ai-bouncer-rule" "$R/.claude/CLAUDE.md"

# E2: CLAUDE.md 삭제 → install --update
R="$TEST_DIR/e2"; fresh_install "$R"
rm -f "$R/.claude/CLAUDE.md"
run_install_update "$R" 2>&1 >/dev/null
check "E2: CLAUDE.md 삭제 → --update 후 재생성" test -f "$R/.claude/CLAUDE.md"
check "E2: bouncer rule 포함" grep -q "ai-bouncer-rule" "$R/.claude/CLAUDE.md"

# E3: bouncer 블록 내용 수정 → install --update
R="$TEST_DIR/e3"; fresh_install "$R"
python3 -c "
content = open('$R/.claude/CLAUDE.md', encoding='utf-8').read()
s = content.find('# --- ai-bouncer-rule start ---')
e = content.find('# --- ai-bouncer-rule end ---')
if s != -1 and e != -1:
    modified = content[:s] + '# --- ai-bouncer-rule start ---\nBROKEN CONTENT\n# --- ai-bouncer-rule end ---' + content[e+len('# --- ai-bouncer-rule end ---'):]
    open('$R/.claude/CLAUDE.md', 'w', encoding='utf-8').write(modified)
"
run_install_update "$R" 2>&1 >/dev/null
check "E3: 블록 수정 → --update 후 /dev-bounce 언급 복원" grep -q "dev-bounce" "$R/.claude/CLAUDE.md"

# E4: CLAUDE.md 빈 파일 → install --update
R="$TEST_DIR/e4"; fresh_install "$R"
: > "$R/.claude/CLAUDE.md"
run_install_update "$R" 2>&1 >/dev/null
check "E4: 빈 CLAUDE.md → --update 후 bouncer rule 추가" grep -q "ai-bouncer-rule" "$R/.claude/CLAUDE.md"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── F. scripts/ 손상 ───${NC}"

# F1: update-check.sh 삭제 → update
R="$TEST_DIR/f1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/scripts/update-check.sh"
run_update "$R" 2>&1 >/dev/null
check "F1: update-check.sh 삭제 → update 후 복원" test -f "$R/.claude/ai-bouncer/scripts/update-check.sh"
check "F1: 실행 권한" test -x "$R/.claude/ai-bouncer/scripts/update-check.sh"

# F2: scripts/ 디렉토리 삭제 → update
R="$TEST_DIR/f2"; fresh_install "$R"
rm -rf "$R/.claude/ai-bouncer/scripts"
run_update "$R" 2>&1 >/dev/null
check "F2: scripts/ 삭제 → update 후 디렉토리 재생성" test -d "$R/.claude/ai-bouncer/scripts"
check "F2: update-check.sh 존재" test -f "$R/.claude/ai-bouncer/scripts/update-check.sh"

# F3: update-check.sh 비우기 → update
R="$TEST_DIR/f3"; fresh_install "$R"
: > "$R/.claude/ai-bouncer/scripts/update-check.sh"
run_update "$R" 2>&1 >/dev/null
check "F3: 빈 script → update 후 크기 > 0" test -s "$R/.claude/ai-bouncer/scripts/update-check.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── G. agents/skills 손상 ───${NC}"

# G1: intent.md 삭제 → update
R="$TEST_DIR/g1"; fresh_install "$R"
rm -f "$R/.claude/agents/intent.md"
run_update "$R" 2>&1 >/dev/null
check "G1: intent.md 삭제 → update 후 복원" test -f "$R/.claude/agents/intent.md"

# G2: agents/ 통째 삭제 → update
R="$TEST_DIR/g2"; fresh_install "$R"
rm -rf "$R/.claude/agents"
run_update "$R" 2>&1 >/dev/null
check "G2: agents/ 삭제 → update 후 intent.md 존재" test -f "$R/.claude/agents/intent.md"
check "G2: dev.md 존재" test -f "$R/.claude/agents/dev.md"
check "G2: lead.md 존재" test -f "$R/.claude/agents/lead.md"

# G3: SKILL.md 삭제 → update
R="$TEST_DIR/g3"; fresh_install "$R"
rm -f "$R/.claude/skills/dev-bounce/SKILL.md"
run_update "$R" 2>&1 >/dev/null
check "G3: SKILL.md 삭제 → update 후 복원" test -f "$R/.claude/skills/dev-bounce/SKILL.md"

# G4: agents/guides/ 삭제 → update
R="$TEST_DIR/g4"; fresh_install "$R"
rm -rf "$R/.claude/agents/guides"
run_update "$R" 2>&1 >/dev/null
check "G4: guides/ 삭제 → update 후 tc-guide.md 존재" test -f "$R/.claude/agents/guides/tc-guide.md"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── H. .gitignore 손상 ───${NC}"

# H1: bouncer 블록 삭제 → update
R="$TEST_DIR/h1"; fresh_install "$R"
python3 -c "
f = '$R/.gitignore'
content = open(f, encoding='utf-8').read()
s = content.find('# --- ai-bouncer start ---')
e = content.find('# --- ai-bouncer end ---')
if s != -1 and e != -1:
    new = content[:s] + content[e+len('# --- ai-bouncer end ---'):]
    open(f, 'w', encoding='utf-8').write(new.strip() + '\n')
"
run_update "$R" 2>&1 >/dev/null
check "H1: bouncer 블록 삭제 → update 후 재주입" grep -q "ai-bouncer start" "$R/.gitignore"

# H2: .gitignore 삭제 → update
R="$TEST_DIR/h2"; fresh_install "$R"
rm -f "$R/.gitignore"
run_update "$R" 2>&1 >/dev/null
check "H2: .gitignore 삭제 → update 후 재생성" test -f "$R/.gitignore"
check "H2: bouncer block 포함" grep -q "ai-bouncer start" "$R/.gitignore"

# H3: end 마커만 삭제 → update
R="$TEST_DIR/h3"; fresh_install "$R"
python3 -c "
f = '$R/.gitignore'
content = open(f, encoding='utf-8').read()
content = content.replace('# --- ai-bouncer end ---', '')
open(f, 'w', encoding='utf-8').write(content)
"
run_update "$R" 2>&1 >/dev/null
check "H3: end 마커 삭제 → update 후 bouncer block 존재" grep -q "ai-bouncer start" "$R/.gitignore"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── I. 복합 손상 ───${NC}"

# I1: config + hooks + CLAUDE.md 삭제 → install
R="$TEST_DIR/i1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/config.json"
rm -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh" "$R/.claude/ai-bouncer/hooks/bash-gate.sh"
rm -f "$R/.claude/CLAUDE.md"
run_install_fresh "$R" >/dev/null
check "I1: 복합 삭제 → install 후 config.json 복구" test -f "$R/.claude/ai-bouncer/config.json"
check "I1: plan-gate.sh 복구" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"
check "I1: CLAUDE.md 복구" test -f "$R/.claude/CLAUDE.md"

# I2: settings + hooks + agents 삭제 → install --update
R="$TEST_DIR/i2"; fresh_install "$R"
rm -f "$R/.claude/settings.json"
rm -f "$R/.claude/ai-bouncer/hooks/"*.sh
rm -rf "$R/.claude/agents"
run_install_update "$R" 2>&1 >/dev/null
check "I2: 복합 삭제 → --update 후 settings.json 복구" test -f "$R/.claude/settings.json"
check "I2: hook 등록됨" grep -q "plan-gate" "$R/.claude/settings.json"
check "I2: agents 복구" test -f "$R/.claude/agents/intent.md"

# I3: ai-bouncer/ 통째 삭제 → install
R="$TEST_DIR/i3"; fresh_install "$R"
rm -rf "$R/.claude/ai-bouncer"
run_install_fresh "$R" >/dev/null
check "I3: ai-bouncer/ 삭제 → install 후 전체 복구" test -f "$R/.claude/ai-bouncer/config.json"
check "I3: manifest 복구" test -f "$R/.claude/ai-bouncer/manifest.json"
check "I3: hooks 복구" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"

# I4: .claude/ 비우기 → install
R="$TEST_DIR/i4"; fresh_install "$R"
rm -rf "$R/.claude"
run_install_fresh "$R" >/dev/null
check "I4: .claude/ 비우기 → install 후 전체 복구" test -f "$R/.claude/ai-bouncer/config.json"
check "I4: settings.json 복구" test -f "$R/.claude/settings.json"
check "I4: CLAUDE.md 복구" test -f "$R/.claude/CLAUDE.md"
check "I4: agents 복구" test -f "$R/.claude/agents/intent.md"

# I5: 구 경로 hook + 신 경로 삭제 + manifest 손상 → install --update
R="$TEST_DIR/i5"; fresh_install "$R"
# 구 경로로 hook 복사
mkdir -p "$R/.claude/hooks"
cp "$R/.claude/ai-bouncer/hooks/plan-gate.sh" "$R/.claude/hooks/plan-gate.sh"
cp "$R/.claude/ai-bouncer/hooks/hooks.json" "$R/.claude/hooks/hooks.json"
# 신 경로 hook 삭제
rm -f "$R/.claude/ai-bouncer/hooks/"*.sh "$R/.claude/ai-bouncer/hooks/hooks.json"
# manifest 손상
echo '{broken' > "$R/.claude/ai-bouncer/manifest.json"
run_install_update "$R" 2>&1 >/dev/null || true
check "I5: 구 경로+manifest 손상 → 마이그레이션 후 ai-bouncer/hooks 존재" test -f "$R/.claude/ai-bouncer/hooks/plan-gate.sh"
check_no "I5: 구 경로 hook 정리됨" test -f "$R/.claude/hooks/plan-gate.sh"

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── J. Uninstall 에지케이스 ───${NC}"

# J1: config 삭제 → uninstall (manifest로 감지)
R="$TEST_DIR/j1"; fresh_install "$R"
rm -f "$R/.claude/ai-bouncer/config.json"
run_uninstall "$R" 2>&1 >/dev/null
check_no "J1: config 없어도 uninstall 성공 → ai-bouncer/ 삭제" test -d "$R/.claude/ai-bouncer"

# J2: 사용자 hook + bouncer hook → uninstall
R="$TEST_DIR/j2"; fresh_install "$R"
python3 -c "
import json
p = '$R/.claude/settings.json'
c = json.load(open(p))
hooks = c.setdefault('hooks', {})
custom = hooks.setdefault('PreToolUse', [])
custom.append({'hooks': [{'type': 'command', 'command': '/usr/local/bin/user-lint.sh'}]})
json.dump(c, open(p, 'w'), indent=2)
"
run_uninstall "$R" 2>&1 >/dev/null
check "J2: uninstall 후 사용자 hook 보존" grep -q "user-lint" "$R/.claude/settings.json"
check_no "J2: bouncer hook 제거" grep -q "plan-gate" "$R/.claude/settings.json"

# J3: CLAUDE.md 사용자+bouncer → uninstall
R="$TEST_DIR/j3"; fresh_install "$R"
python3 -c "
content = open('$R/.claude/CLAUDE.md', encoding='utf-8').read()
new = '# My Custom Rules\n\nDo this and that.\n\n' + content
open('$R/.claude/CLAUDE.md', 'w', encoding='utf-8').write(new)
"
run_uninstall "$R" 2>&1 >/dev/null
check "J3: uninstall 후 사용자 내용 보존" grep -q "My Custom Rules" "$R/.claude/CLAUDE.md"
check_no "J3: bouncer 블록 제거" grep -q "ai-bouncer-rule" "$R/.claude/CLAUDE.md"

# J4: 미설치 상태 uninstall
R="$TEST_DIR/j4"; setup_repo "$R"
if ! run_uninstall "$R" 2>&1 >/dev/null; then
  pass "J4: 미설치 → uninstall exit 1"
else
  fail "J4: 미설치 → uninstall가 성공함 (에러 기대)"
fi

# J5: uninstall 2회 연속
R="$TEST_DIR/j5"; fresh_install "$R"
RET1=0; run_uninstall "$R" >/dev/null || RET1=$?
RET2=0; run_uninstall "$R" >/dev/null || RET2=$?
if [ "$RET1" -eq 0 ]; then pass "J5: 1회 uninstall 성공"; else fail "J5: 1회 uninstall 실패 (exit $RET1)"; fi
if [ "$RET2" -ne 0 ]; then pass "J5: 2회 uninstall 에러"; else fail "J5: 2회 uninstall 성공 (에러 기대)"; fi

# ═════════════════════════════════════════════════════════════
echo -e "\n${BOLD}─── 결과 ───${NC}"

echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${GREEN}✅ $PASS 통과${NC} / ${RED}❌ $FAIL 실패${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
