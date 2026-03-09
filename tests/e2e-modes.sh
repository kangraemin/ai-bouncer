#!/bin/bash
# e2e-modes.sh — ai-bouncer Mode Flags E2E Tests
# Persona-based lifecycle tests for enforcement_mode + agent_mode
# Usage: bash tests/e2e-modes.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

# ── 공통 헬퍼 ──────────────────────────────────────────────

setup_fake_env() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  mkdir -p "$FAKE_HOME" "$FAKE_REPO"
  git -C "$FAKE_REPO" init -q
  git -C "$FAKE_REPO" config user.email "test@test.com"
  git -C "$FAKE_REPO" config user.name "test"
  touch "$FAKE_REPO/dummy.txt"
  git -C "$FAKE_REPO" add dummy.txt
  git -C "$FAKE_REPO" commit -m "init" -q
  echo "$tmpdir"
}

run_install_modes() {
  local FAKE_HOME="$1"
  local FAKE_REPO="$2"
  local enforcement="${3:-hooks}"
  local agent="${4:-team}"
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && \
    ENFORCEMENT_MODE="$enforcement" AGENT_MODE="$agent" CI=true \
    bash "$REPO_DIR/install.sh" 2>&1) || true
}

run_config() {
  local FAKE_HOME="$1"
  local FAKE_REPO="$2"
  local commit_choice="$3"      # 1=per-step, 2=per-phase, 3=none
  local enforcement_choice="$4" # 1=hooks, 2=prompt-only
  local agent_choice="$5"       # 1=team, 2=subagent, 3=single
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && \
    printf '%s\n' "$commit_choice" "$enforcement_choice" "$agent_choice" | \
    bash "$REPO_DIR/install.sh" --config 2>&1) || true
}

run_update() {
  local FAKE_HOME="$1"
  local FAKE_REPO="$2"
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && bash "$REPO_DIR/update.sh" 2>&1) || true
}

run_uninstall() {
  local FAKE_HOME="$1"
  local FAKE_REPO="$2"
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && bash "$REPO_DIR/uninstall.sh" 2>&1) || true
}

# hook 등록 여부 확인
has_hook() {
  local settings="$1"
  local hook_name="$2"
  python3 -c "
import json
cfg = json.load(open('$settings'))
hooks = cfg.get('hooks', {})
found = False
for ht in hooks.values():
    for g in ht:
        for h in g.get('hooks', []):
            if '$hook_name' in h.get('command', ''):
                found = True
assert found, 'hook $hook_name not found'
"
}

has_no_hook() {
  local settings="$1"
  local hook_name="$2"
  python3 -c "
import json
cfg = json.load(open('$settings'))
hooks = cfg.get('hooks', {})
for ht in hooks.values():
    for g in ht:
        for h in g.get('hooks', []):
            assert '$hook_name' not in h.get('command', ''), 'found $hook_name'
"
}

has_env() {
  local settings="$1"
  local key="$2"
  python3 -c "
import json
cfg = json.load(open('$settings'))
assert cfg.get('env', {}).get('$key') == '1', 'env $key not set'
"
}

has_no_env() {
  local settings="$1"
  local key="$2"
  python3 -c "
import json
cfg = json.load(open('$settings'))
assert '$key' not in cfg.get('env', {}), 'env $key still present'
"
}

config_has() {
  local config="$1"
  local key="$2"
  local val="$3"
  python3 -c "
import json
cfg = json.load(open('$config'))
assert str(cfg.get('$key', '')) == '$val', f'expected $val, got {cfg.get(\"$key\")}'
"
}

# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer Mode Flags E2E Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

# ── Persona A: 기본 유저 (hooks + team) — 회귀 확인 ──────────

persona_a() {
  echo -e "\n${BOLD}Persona A: 기본 유저 (hooks + team)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "team"

  check "config: enforcement_mode=hooks" config_has "$CONFIG" "enforcement_mode" "hooks"
  check "config: agent_mode=team" config_has "$CONFIG" "agent_mode" "team"
  check "settings: plan-gate registered" has_hook "$SETTINGS" "plan-gate"
  check "settings: bash-gate registered" has_hook "$SETTINGS" "bash-gate"
  check "settings: completion-gate registered" has_hook "$SETTINGS" "completion-gate"
  check "settings: AGENT_TEAMS env" has_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

  # update
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: hooks still present" has_hook "$SETTINGS" "plan-gate"

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: config gone" test ! -f "$CONFIG"

  rm -rf "$tmpdir"
}

# ── Persona B: hook 안 쓰는 유저 (prompt-only + team) ────────

persona_b() {
  echo -e "\n${BOLD}Persona B: hook 안 쓰는 유저 (prompt-only + team)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "prompt-only" "team"

  check "config: enforcement_mode=prompt-only" config_has "$CONFIG" "enforcement_mode" "prompt-only"
  check "config: agent_mode=team" config_has "$CONFIG" "agent_mode" "team"
  check "settings: no plan-gate" has_no_hook "$SETTINGS" "plan-gate"
  check "settings: no bash-gate" has_no_hook "$SETTINGS" "bash-gate"
  check "settings: no completion-gate" has_no_hook "$SETTINGS" "completion-gate"
  check "settings: AGENT_TEAMS env (team mode)" has_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
  check "CLAUDE.md exists" test -f "$TARGET/CLAUDE.md"

  # update — hook 복사 스킵
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: still no hooks in settings" has_no_hook "$SETTINGS" "plan-gate"

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: clean" test ! -f "$CONFIG"

  rm -rf "$tmpdir"
}

# ── Persona C: subagent 유저 (hooks + subagent) ──────────────

persona_c() {
  echo -e "\n${BOLD}Persona C: subagent 유저 (hooks + subagent)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"

  check "config: enforcement_mode=hooks" config_has "$CONFIG" "enforcement_mode" "hooks"
  check "config: agent_mode=subagent" config_has "$CONFIG" "agent_mode" "subagent"
  check "settings: plan-gate registered" has_hook "$SETTINGS" "plan-gate"
  check "settings: bash-gate registered" has_hook "$SETTINGS" "bash-gate"
  check "settings: no AGENT_TEAMS env" has_no_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
  check "agents exist" test -f "$TARGET/agents/lead.md"

  # hook 동작 검증 — plan-gate with subagent mode
  # subagent + development + team_name 비어있음 + 정상 구조 → ALLOW
  local date_dir="2026-01-01"
  local task="test-task"
  mkdir -p "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-test"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  echo "# Plan" > "$FAKE_REPO/docs/${date_dir}/${task}/plan.md"
  echo "# Phase 1" > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-test/phase.md"
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-test/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 |  |
STEPEOF

  python3 -c "
import json
state = {
    'workflow_phase': 'development',
    'plan_approved': True,
    'mode': 'normal',
    'team_name': '',
    'current_dev_phase': 1,
    'current_step': 1,
    'dev_phases': {
        '1': {
            'name': 'test',
            'folder': 'phase-1-test',
            'steps': {'1': {'title': 'Test step'}}
        }
    },
    'verification': {'rounds_passed': 0}
}
with open('$FAKE_REPO/docs/${date_dir}/${task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
"

  local hook_input
  hook_input=$(jq -n '{tool_name: "Write", tool_input: {file_path: "/src/feature.ts"}}')
  local hook_out
  hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$TARGET/hooks/plan-gate.sh" 2>/dev/null || true)
  local decision
  decision=$(echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  if [ "$decision" != "block" ]; then
    pass "plan-gate: subagent + no team_name → ALLOW"
  else
    fail "plan-gate: subagent + no team_name → expected ALLOW, got BLOCK"
  fi

  # dev_phases={} → BLOCK (CHECK 6.7 유지)
  python3 -c "
import json
f = '$FAKE_REPO/docs/${date_dir}/${task}/state.json'
with open(f) as fp: s = json.load(fp)
s['dev_phases'] = {}
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
"
  hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$TARGET/hooks/plan-gate.sh" 2>/dev/null || true)
  decision=$(echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  if [ "$decision" = "block" ]; then
    pass "plan-gate: subagent + dev_phases={} → BLOCK"
  else
    fail "plan-gate: subagent + dev_phases={} → expected BLOCK"
  fi

  # update
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: hooks copied" test -f "$TARGET/hooks/plan-gate.sh"

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: clean" test ! -f "$CONFIG"

  rm -rf "$tmpdir"
}

# ── Persona D: 미니멀 유저 (prompt-only + single) ────────────

persona_d() {
  echo -e "\n${BOLD}Persona D: 미니멀 유저 (prompt-only + single)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "prompt-only" "single"

  check "config: enforcement_mode=prompt-only" config_has "$CONFIG" "enforcement_mode" "prompt-only"
  check "config: agent_mode=single" config_has "$CONFIG" "agent_mode" "single"
  check "settings: no hooks" has_no_hook "$SETTINGS" "plan-gate"
  check "settings: no AGENT_TEAMS env" has_no_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
  check "skill installed" test -f "$TARGET/skills/dev-bounce/SKILL.md"

  # update — hook 복사 스킵
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: still no hooks" has_no_hook "$SETTINGS" "plan-gate"

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: clean" test ! -f "$CONFIG"

  rm -rf "$tmpdir"
}

# ── Persona E: 모드 전환 유저 (--config) ──────────────────────

persona_e() {
  echo -e "\n${BOLD}Persona E: 모드 전환 유저 (--config)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  # 1. hooks+team으로 설치
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "team"
  check "E-1: initial hooks+team" has_hook "$SETTINGS" "plan-gate"

  # 2. --config: enforcement → prompt-only (commit=1, enforcement=2, agent=1)
  run_config "$FAKE_HOME" "$FAKE_REPO" "1" "2" "1"
  check "E-2: config enforcement=prompt-only" config_has "$CONFIG" "enforcement_mode" "prompt-only"
  check "E-2: hooks removed" has_no_hook "$SETTINGS" "plan-gate"

  # 3. --config: enforcement → hooks (commit=1, enforcement=1, agent=1)
  run_config "$FAKE_HOME" "$FAKE_REPO" "1" "1" "1"
  check "E-3: config enforcement=hooks" config_has "$CONFIG" "enforcement_mode" "hooks"
  check "E-3: hooks re-registered" has_hook "$SETTINGS" "plan-gate"

  # 4. --config: agent → subagent (commit=1, enforcement=1, agent=2)
  run_config "$FAKE_HOME" "$FAKE_REPO" "1" "1" "2"
  check "E-4: config agent_mode=subagent" config_has "$CONFIG" "agent_mode" "subagent"
  check "E-4: AGENT_TEAMS removed" has_no_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

  # 5. --config: agent → team (commit=1, enforcement=1, agent=1)
  run_config "$FAKE_HOME" "$FAKE_REPO" "1" "1" "1"
  check "E-5: config agent_mode=team" config_has "$CONFIG" "agent_mode" "team"
  check "E-5: AGENT_TEAMS restored" has_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

  rm -rf "$tmpdir"
}

# ── Persona F: 구버전 유저 (하위 호환) ────────────────────────

persona_f() {
  echo -e "\n${BOLD}Persona F: 구버전 유저 (하위 호환)${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"

  # 설치 후 config.json에서 mode 필드 제거 (구버전 시뮬레이션)
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "team"

  python3 -c "
import json
cfg_path = '$TARGET/ai-bouncer/config.json'
with open(cfg_path) as f: cfg = json.load(f)
cfg.pop('enforcement_mode', None)
cfg.pop('agent_mode', None)
with open(cfg_path, 'w') as f: json.dump(cfg, f, indent=2)
"

  # plan-gate: team 기본값 → team_name 비어있으면 차단
  local date_dir="2026-01-01"
  local task="legacy-task"
  mkdir -p "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-test"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  echo "# Plan" > "$FAKE_REPO/docs/${date_dir}/${task}/plan.md"
  echo "# Phase 1" > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-test/phase.md"

  python3 -c "
import json
state = {
    'workflow_phase': 'development',
    'plan_approved': True,
    'mode': 'normal',
    'team_name': '',
    'current_dev_phase': 1,
    'current_step': 1,
    'dev_phases': {'1': {'name': 'test', 'folder': 'phase-1-test', 'steps': {'1': {'title': 'Test'}}}},
    'verification': {'rounds_passed': 0}
}
with open('$FAKE_REPO/docs/${date_dir}/${task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
"

  local hook_input
  hook_input=$(jq -n '{tool_name: "Write", tool_input: {file_path: "/src/feature.ts"}}')
  local hook_out
  hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$TARGET/hooks/plan-gate.sh" 2>/dev/null || true)
  local decision
  decision=$(echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  if [ "$decision" = "block" ]; then
    pass "plan-gate: legacy config + no team_name → BLOCK (team fallback)"
  else
    fail "plan-gate: legacy config + no team_name → expected BLOCK"
  fi

  # update: hook 복사됨 (기본값 hooks 폴백)
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: hooks copied (default fallback)" test -f "$TARGET/hooks/plan-gate.sh"

  rm -rf "$tmpdir"
}

# ── 실행 ────────────────────────────────────────────────────

persona_a
persona_b
persona_c
persona_d
persona_e
persona_f

echo -e "\n${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${PASS}/${TOTAL} PASS, ${FAIL} FAIL${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
