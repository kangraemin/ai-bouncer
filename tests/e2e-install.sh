#!/bin/bash
# e2e-install.sh — ai-bouncer install/uninstall e2e tests
# Uses FAKE_HOME to avoid polluting the real environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

pass() { ((PASS++)); ((TOTAL++)); echo -e "  ${GREEN}PASS${NC} $*"; }
fail() { ((FAIL++)); ((TOTAL++)); echo -e "  ${RED}FAIL${NC} $*"; }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# ── 공통 검증 함수 ──────────────────────────────────────────────

verify_install() {
  local TARGET_DIR="$1"
  local FAKE_HOME="$2"
  local label="$3"

  echo "  --- $label: 설치 검증 ---"

  # agents 8개
  for agent in intent.md planner-lead.md planner-dev.md planner-qa.md verifier.md lead.md dev.md qa.md; do
    check "agent: $agent" test -f "$TARGET_DIR/agents/$agent"
  done

  # hooks 5개 + 실행 권한
  for hook in plan-gate.sh bash-gate.sh bash-audit.sh doc-reminder.sh completion-gate.sh; do
    check "hook exists: $hook" test -f "$TARGET_DIR/hooks/$hook"
    check "hook executable: $hook" test -x "$TARGET_DIR/hooks/$hook"
  done

  # hooks/lib/resolve-task.sh
  check "hooks/lib/resolve-task.sh" test -f "$TARGET_DIR/hooks/lib/resolve-task.sh"

  # settings.json hook 등록
  local SETTINGS="$TARGET_DIR/settings.json"
  check "settings.json exists" test -f "$SETTINGS"
  if [ -f "$SETTINGS" ]; then
    check "settings: plan-gate PreToolUse" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {}).get('PreToolUse', [])
assert any('plan-gate' in h.get('command','') for g in hooks for h in g.get('hooks', []))
"
    check "settings: bash-gate PreToolUse" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {}).get('PreToolUse', [])
assert any('bash-gate' in h.get('command','') for g in hooks for h in g.get('hooks', []))
"
    check "settings: doc-reminder PostToolUse" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {}).get('PostToolUse', [])
assert any('doc-reminder' in h.get('command','') for g in hooks for h in g.get('hooks', []))
"
    check "settings: bash-audit PostToolUse" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {}).get('PostToolUse', [])
assert any('bash-audit' in h.get('command','') for g in hooks for h in g.get('hooks', []))
"
    check "settings: completion-gate Stop" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {}).get('Stop', [])
assert any('completion-gate' in h.get('command','') for g in hooks for h in g.get('hooks', []))
"
  fi

  # CLAUDE.md ai-bouncer-rule 블록
  check "CLAUDE.md exists" test -f "$TARGET_DIR/CLAUDE.md"
  if [ -f "$TARGET_DIR/CLAUDE.md" ]; then
    check "CLAUDE.md: ai-bouncer-rule block" grep -q "ai-bouncer-rule start" "$TARGET_DIR/CLAUDE.md"
  fi

  # manifest.json
  local MANIFEST="$FAKE_HOME/.claude/ai-bouncer/manifest.json"
  check "manifest.json exists" test -f "$MANIFEST"
  if [ -f "$MANIFEST" ]; then
    check "manifest.json: files not empty" python3 -c "
import json
m = json.load(open('$MANIFEST'))
assert len(m.get('files', [])) > 0
"
  fi

  # config.json
  local CONFIG="$FAKE_HOME/.claude/ai-bouncer/config.json"
  check "config.json exists" test -f "$CONFIG"
  if [ -f "$CONFIG" ]; then
    check "config.json: commit_strategy" python3 -c "
import json
c = json.load(open('$CONFIG'))
assert 'commit_strategy' in c
"
    check "config.json: target_dir" python3 -c "
import json
c = json.load(open('$CONFIG'))
assert 'target_dir' in c
"
  fi

  # skills/dev-bounce/SKILL.md (항상 글로벌)
  check "skills/dev-bounce/SKILL.md" test -f "$FAKE_HOME/.claude/skills/dev-bounce/SKILL.md"
}

# ── 테스트 환경 셋업 ──────────────────────────────────────────────

setup_fake_env() {
  local tmpdir
  tmpdir=$(mktemp -d)

  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  mkdir -p "$FAKE_HOME" "$FAKE_REPO"

  # 가짜 git repo 생성
  git -C "$FAKE_REPO" init -q
  git -C "$FAKE_REPO" config user.email "test@test.com"
  git -C "$FAKE_REPO" config user.name "test"
  touch "$FAKE_REPO/dummy.txt"
  git -C "$FAKE_REPO" add dummy.txt
  git -C "$FAKE_REPO" commit -m "init" -q

  echo "$tmpdir"
}

run_install() {
  local FAKE_HOME="$1"
  local FAKE_REPO="$2"
  local scope="$3"       # 1=global, 2=local
  local commit="$4"      # 1=per-step, 2=per-phase, 3=none
  local docs_track="$5"  # y/n

  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && printf '%s\n' "$scope" "$docs_track" "$commit" | bash "$REPO_DIR/install.sh" 2>&1) || true
}

# ── TC-1: 로컬 설치 ──────────────────────────────────────────────

tc1_local_install() {
  echo -e "\n${BOLD}TC-1: 로컬 설치${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  run_install "$FAKE_HOME" "$FAKE_REPO" "2" "1" "n"

  verify_install "$FAKE_REPO/.claude" "$FAKE_HOME" "TC-1"

  rm -rf "$tmpdir"
}

# ── TC-2: 전역 설치 ──────────────────────────────────────────────

tc2_global_install() {
  echo -e "\n${BOLD}TC-2: 전역 설치${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  run_install "$FAKE_HOME" "$FAKE_REPO" "1" "1" "n"

  verify_install "$FAKE_HOME/.claude" "$FAKE_HOME" "TC-2"

  rm -rf "$tmpdir"
}

# ── TC-3: curl 원격 설치 시뮬레이션 ──────────────────────────────

tc3_curl_simulation() {
  echo -e "\n${BOLD}TC-3: curl 원격 설치 시뮬레이션${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  # bash <(cat ...) 로 BASH_SOURCE[0]를 /dev/fd/XX로 깨뜨려서 curl 실행 시뮬레이션
  # AI_BOUNCER_REPO로 로컬 레포 지정 (네트워크 불필요)
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && export AI_BOUNCER_REPO="$REPO_DIR" && printf '%s\n' "1" "n" "1" | bash <(cat "$REPO_DIR/install.sh") 2>&1) || true

  verify_install "$FAKE_HOME/.claude" "$FAKE_HOME" "TC-3"

  rm -rf "$tmpdir"
}

# ── TC-4: 언인스톨 ──────────────────────────────────────────────

tc4_uninstall() {
  echo -e "\n${BOLD}TC-4: 언인스톨${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  # 먼저 전역 설치 (uninstall.sh가 $HOME/.claude 기준으로 동작)
  run_install "$FAKE_HOME" "$FAKE_REPO" "1" "1" "n"

  # 언인스톨
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && bash "$REPO_DIR/uninstall.sh" 2>&1) || true

  echo "  --- TC-4: 언인스톨 검증 ---"

  local TARGET_DIR="$FAKE_HOME/.claude"

  # agents 삭제 확인
  local all_gone=true
  for agent in intent.md planner-lead.md planner-dev.md planner-qa.md verifier.md lead.md dev.md qa.md; do
    if [ -f "$TARGET_DIR/agents/$agent" ]; then
      fail "agent still exists: $agent"
      all_gone=false
    fi
  done
  $all_gone && pass "agents 삭제됨"

  # hooks 삭제 확인
  all_gone=true
  for hook in plan-gate.sh bash-gate.sh bash-audit.sh doc-reminder.sh completion-gate.sh; do
    if [ -f "$TARGET_DIR/hooks/$hook" ]; then
      fail "hook still exists: $hook"
      all_gone=false
    fi
  done
  $all_gone && pass "hooks 삭제됨"

  # settings.json에서 hook 제거 확인
  local SETTINGS="$TARGET_DIR/settings.json"
  if [ -f "$SETTINGS" ]; then
    check "settings: no ai-bouncer hooks" python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
hooks = cfg.get('hooks', {})
for ht in ['PreToolUse', 'PostToolUse', 'Stop']:
    for g in hooks.get(ht, []):
        for h in g.get('hooks', []):
            assert 'ai-bouncer' not in h.get('command', ''), f'found ai-bouncer in {ht}'
"
  else
    pass "settings.json: no ai-bouncer hooks (file removed)"
  fi

  # CLAUDE.md 블록 제거 확인
  if [ -f "$TARGET_DIR/CLAUDE.md" ]; then
    check "CLAUDE.md: no ai-bouncer block" python3 -c "
content = open('$TARGET_DIR/CLAUDE.md').read()
assert 'ai-bouncer-rule start' not in content
"
  else
    pass "CLAUDE.md: removed entirely"
  fi

  # manifest.json, config.json 삭제 확인
  check "manifest.json 삭제됨" test ! -f "$FAKE_HOME/.claude/ai-bouncer/manifest.json"
  check "config.json 삭제됨" test ! -f "$FAKE_HOME/.claude/ai-bouncer/config.json"

  rm -rf "$tmpdir"
}

# ── TC-5: 재설치 (업데이트) ──────────────────────────────────────

tc5_reinstall() {
  echo -e "\n${BOLD}TC-5: 재설치 (업데이트)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  # 1차 설치
  run_install "$FAKE_HOME" "$FAKE_REPO" "2" "1" "n"

  # 2차 설치 (업데이트) — "기존 설치 감지" 메시지 확인
  local output
  output=$(run_install "$FAKE_HOME" "$FAKE_REPO" "2" "1" "n")

  if echo "$output" | grep -q "기존 설치 감지"; then pass "업데이트 메시지 출력"; else fail "업데이트 메시지 출력"; fi

  verify_install "$FAKE_REPO/.claude" "$FAKE_HOME" "TC-5"

  rm -rf "$tmpdir"
}

# ── TC-6: --config ──────────────────────────────────────────────

tc6_config() {
  echo -e "\n${BOLD}TC-6: --config${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"

  # 먼저 설치
  run_install "$FAKE_HOME" "$FAKE_REPO" "1" "1" "n"

  # --config로 per-phase로 변경
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && printf '%s\n' "2" | bash "$REPO_DIR/install.sh" --config 2>&1) || true

  local CONFIG="$FAKE_HOME/.claude/ai-bouncer/config.json"
  check "config.json: commit_strategy = per-phase" python3 -c "
import json
c = json.load(open('$CONFIG'))
assert c['commit_strategy'] == 'per-phase', f'got {c[\"commit_strategy\"]}'
"

  # --config로 none으로 변경
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && printf '%s\n' "3" | bash "$REPO_DIR/install.sh" --config 2>&1) || true

  check "config.json: commit_strategy = none" python3 -c "
import json
c = json.load(open('$CONFIG'))
assert c['commit_strategy'] == 'none', f'got {c[\"commit_strategy\"]}'
"

  rm -rf "$tmpdir"
}

# ── 실행 ────────────────────────────────────────────────────────

echo -e "${BOLD}=== ai-bouncer e2e install tests ===${NC}"

tc1_local_install
tc2_global_install
tc3_curl_simulation
tc4_uninstall
tc5_reinstall
tc6_config

echo -e "\n${BOLD}=== 결과: ${PASS}/${TOTAL} PASS, ${FAIL} FAIL ===${NC}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
