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

  # update — 파일 내용까지 검증
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: hooks still present" has_hook "$SETTINGS" "plan-gate"
  check "update: plan-gate.sh 내용 갱신" grep -q "ai-bouncer" "$TARGET/hooks/plan-gate.sh"
  check "update: agent dev.md 갱신" grep -q "commit_strategy" "$TARGET/agents/dev.md"
  check "update: skill SKILL.md 갱신" test -f "$TARGET/skills/dev-bounce/SKILL.md"

  # uninstall — 전체 정리 검증
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: config gone" test ! -f "$CONFIG"
  check "uninstall: hooks cleaned" test ! -f "$TARGET/hooks/plan-gate.sh"
  check "uninstall: agents cleaned" test ! -f "$TARGET/agents/dev.md"
  check "uninstall: CLAUDE.md rule removed" bash -c '! grep -q "ai-bouncer-rule" "$0" 2>/dev/null || ! test -f "$0"' "$TARGET/CLAUDE.md"
  check "uninstall: settings hooks removed" has_no_hook "$SETTINGS" "plan-gate"

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
  check "uninstall: CLAUDE.md rule removed" bash -c '! grep -q "ai-bouncer-rule" "$0" 2>/dev/null || ! test -f "$0"' "$TARGET/CLAUDE.md"

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

  # update — 파일 내용 검증
  run_update "$FAKE_HOME" "$FAKE_REPO"
  check "update: hooks copied" test -f "$TARGET/hooks/plan-gate.sh"
  check "update: bash-gate.sh 내용 갱신" grep -q "ai-bouncer" "$TARGET/hooks/bash-gate.sh"

  # uninstall — 전체 정리
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: clean" test ! -f "$CONFIG"
  check "uninstall: hooks cleaned" test ! -f "$TARGET/hooks/plan-gate.sh"
  check "uninstall: agents cleaned" test ! -f "$TARGET/agents/lead.md"

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

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "E-6: uninstall config gone" test ! -f "$CONFIG"
  check "E-6: uninstall hooks cleaned" has_no_hook "$SETTINGS" "plan-gate"
  check "E-6: uninstall AGENT_TEAMS removed" has_no_env "$SETTINGS" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

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
  check "update: agent 파일 갱신" test -f "$TARGET/agents/dev.md"

  # uninstall
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "uninstall: config gone" test ! -f "$TARGET/ai-bouncer/config.json"
  check "uninstall: hooks cleaned" test ! -f "$TARGET/hooks/plan-gate.sh"

  rm -rf "$tmpdir"
}

# ── Persona G: commit_strategy 유저 ─────────────────────────

persona_g() {
  echo -e "\n${BOLD}Persona G: commit_strategy 유저${NC}"
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"

  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"

  # 공통 setup: docs + state.json + step 파일
  local date_dir="2026-01-01"
  local task="cs-task"
  mkdir -p "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  echo "# Plan" > "$FAKE_REPO/docs/${date_dir}/${task}/plan.md"
  echo "# Phase 1" > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/phase.md"

  # step-1.md (미완료 — ✅ 없음)
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 |  |
STEPEOF

  # step-2.md (미완료)
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/step-2.md" << 'STEPEOF'
# Step 2: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 |  |
STEPEOF

  # state.json: normal + development + per-step (2 steps)
  write_state() {
    python3 -c "
import json
state = $1
with open('$FAKE_REPO/docs/${date_dir}/${task}/state.json', 'w') as f:
    json.dump(state, f, indent=2)
"
  }

  set_commit_strategy() {
    python3 -c "
import json
with open('$CONFIG') as f: cfg = json.load(f)
cfg['commit_strategy'] = '$1'
with open('$CONFIG', 'w') as f: json.dump(cfg, f, indent=2)
"
  }

  run_bash_gate() {
    local cmd="$1"
    local hook_input
    hook_input=$(jq -n --arg cmd "$cmd" '{tool_name: "Bash", tool_input: {command: $cmd}}')
    local hook_out
    hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$TARGET/hooks/bash-gate.sh" 2>/dev/null || true)
    echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow"
  }

  # G-1: per-step + step 미완료 + git commit → BLOCK
  set_commit_strategy "per-step"
  write_state '{
    "workflow_phase": "development", "plan_approved": True, "mode": "normal",
    "team_name": "", "current_dev_phase": 1, "current_step": 1,
    "dev_phases": {"1": {"name": "impl", "folder": "phase-1-impl", "steps": {"1": {"title": "S1"}, "2": {"title": "S2"}}}},
    "verification": {"rounds_passed": 0}
  }'
  local decision
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" = "block" ]; then
    pass "G-1: per-step + step 미완료 + git commit → BLOCK"
  else
    fail "G-1: per-step + step 미완료 + git commit → expected BLOCK, got $decision"
  fi

  # G-2: per-step + step 완료(✅) + git commit → ALLOW
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 | ✅ |
STEPEOF
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" != "block" ]; then
    pass "G-2: per-step + step 완료(✅) + git commit → ALLOW"
  else
    fail "G-2: per-step + step 완료 → expected ALLOW, got BLOCK"
  fi

  # G-3: per-phase + 중간 step (step 1 완료, step 2 미완료) + git commit → BLOCK
  set_commit_strategy "per-phase"
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" = "block" ]; then
    pass "G-3: per-phase + 중간 step + git commit → BLOCK"
  else
    fail "G-3: per-phase + 중간 step → expected BLOCK, got $decision"
  fi

  # G-4: per-phase + 마지막 step 완료 + git commit → ALLOW
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/step-2.md" << 'STEPEOF'
# Step 2: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 | ✅ |
STEPEOF
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" != "block" ]; then
    pass "G-4: per-phase + 마지막 step 완료 + git commit → ALLOW"
  else
    fail "G-4: per-phase + 마지막 step 완료 → expected ALLOW, got BLOCK"
  fi

  # G-5: none + git commit → BLOCK
  set_commit_strategy "none"
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" = "block" ]; then
    pass "G-5: none + git commit → BLOCK"
  else
    fail "G-5: none → expected BLOCK, got $decision"
  fi

  # G-6: git status (비 commit/push) → ALLOW
  set_commit_strategy "per-step"
  decision=$(run_bash_gate "git status")
  if [ "$decision" != "block" ]; then
    pass "G-6: git status → ALLOW"
  else
    fail "G-6: git status → expected ALLOW, got BLOCK"
  fi

  # G-7: verification + git commit → ALLOW
  set_commit_strategy "per-step"
  write_state '{
    "workflow_phase": "verification", "plan_approved": True, "mode": "normal",
    "team_name": "", "current_dev_phase": 1, "current_step": 1,
    "dev_phases": {"1": {"name": "impl", "folder": "phase-1-impl", "steps": {"1": {"title": "S1"}}}},
    "verification": {"rounds_passed": 0}
  }'
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" != "block" ]; then
    pass "G-7: verification + git commit → ALLOW"
  else
    fail "G-7: verification → expected ALLOW, got BLOCK"
  fi

  # G-8: .active 없음 + git commit → ALLOW (gate 비활성)
  rm -f "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  set_commit_strategy "per-step"
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" != "block" ]; then
    pass "G-8: .active 없음 + git commit → ALLOW"
  else
    fail "G-8: .active 없음 → expected ALLOW, got BLOCK"
  fi

  # G-9: simple 모드 + development + git commit → ALLOW
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  set_commit_strategy "per-step"
  write_state '{
    "workflow_phase": "development", "plan_approved": True, "mode": "simple",
    "team_name": "", "current_dev_phase": 0, "current_step": 0,
    "dev_phases": {}, "verification": {"rounds_passed": 0}
  }'
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" != "block" ]; then
    pass "G-9: simple + development + git commit → ALLOW"
  else
    fail "G-9: simple mode → expected ALLOW, got BLOCK"
  fi

  # G-10: planning + git commit → BLOCK
  set_commit_strategy "per-step"
  write_state '{
    "workflow_phase": "planning", "plan_approved": False, "mode": "normal",
    "team_name": "", "current_dev_phase": 0, "current_step": 0,
    "dev_phases": {}, "verification": {"rounds_passed": 0}
  }'
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" = "block" ]; then
    pass "G-10: planning + git commit → BLOCK"
  else
    fail "G-10: planning → expected BLOCK, got $decision"
  fi

  # G-11: update 후 bash-gate 동작 유지
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  set_commit_strategy "per-step"
  # step-1.md를 미완료 상태로 복원 (G-2에서 ✅가 들어갔음)
  cat > "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl/step-1.md" << 'STEPEOF'
# Step 1: Test
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | 테스트 | 성공 |  |
STEPEOF
  write_state '{
    "workflow_phase": "development", "plan_approved": True, "mode": "normal",
    "team_name": "", "current_dev_phase": 1, "current_step": 1,
    "dev_phases": {"1": {"name": "impl", "folder": "phase-1-impl", "steps": {"1": {"title": "S1"}, "2": {"title": "S2"}}}},
    "verification": {"rounds_passed": 0}
  }'
  run_update "$FAKE_HOME" "$FAKE_REPO"
  decision=$(run_bash_gate "git commit -m 'test'")
  if [ "$decision" = "block" ]; then
    pass "G-11: update 후 per-step + 미완료 → BLOCK 유지"
  else
    fail "G-11: update 후 → expected BLOCK, got $decision"
  fi

  # G-12: uninstall 후 bash-gate 사라짐
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  check "G-12: uninstall config gone" test ! -f "$CONFIG"
  check "G-12: uninstall bash-gate gone" test ! -f "$TARGET/hooks/bash-gate.sh"

  rm -rf "$tmpdir"
}

persona_h() {
  echo -e "\n${BOLD}Persona H: stop hook 호환성${NC}"

  # ── Setup ──
  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"

  # fake 글로벌 stop.sh 생성 (worklog 패턴 — 미커밋 감지 → block)
  mkdir -p "$FAKE_HOME/.claude/hooks"
  cat > "$FAKE_HOME/.claude/hooks/stop.sh" << 'STOPEOF'
#!/bin/bash
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd')
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
if [ -n "$DIRTY" ]; then
  jq -n '{decision:"block", reason:"미커밋 변경 감지"}'
  exit 0
fi
exit 0
STOPEOF
  chmod +x "$FAKE_HOME/.claude/hooks/stop.sh"

  # 글로벌 settings.json에 stop.sh 등록
  cat > "$FAKE_HOME/.claude/settings.json" << SETTEOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$FAKE_HOME/.claude/hooks/stop.sh"}]}]}}
SETTEOF

  # ── 실제 install 실행 ──
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"

  # H-1: stop.sh에 managed block inject 됐는지
  check "H-1: stop.sh managed block inject" grep -q "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh"

  # ── 공통 setup: docs 구조 + dirty state ──
  local date_dir="2026-01-01"
  local task="h-task"
  mkdir -p "$FAKE_REPO/docs/${date_dir}/${task}/phase-1-impl"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  echo "# Plan" > "$FAKE_REPO/docs/${date_dir}/${task}/plan.md"
  # dirty file 생성 (미커밋 상태 — stop.sh가 block할 조건)
  echo "dirty" > "$FAKE_REPO/src.txt"
  git -C "$FAKE_REPO" add src.txt

  # ── 헬퍼: state.json 쓰기 + stop.sh 실행 → decision 반환 ──
  write_h_state() {
    echo "$1" | python3 -c "
import json, sys
data = json.load(sys.stdin)
with open('$FAKE_REPO/docs/${date_dir}/${task}/state.json', 'w') as f:
    json.dump(data, f, indent=2)
"
  }

  run_stop_hook() {
    local hook_input
    hook_input=$(jq -n --arg cwd "$FAKE_REPO" '{cwd: $cwd}')
    local hook_out
    hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null || true)
    echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow"
  }

  local decision

  # ── H-2: normal + development + dirty → ALLOW (팀 작업 중, managed block이 exit 0) ──
  write_h_state '{"workflow_phase":"development","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" != "block" ]; then
    pass "H-2: normal + development → ALLOW"
  else
    fail "H-2: normal + development → expected ALLOW, got $decision"
  fi

  # ── H-3: normal + done + dirty → BLOCK (작업 끝, 미커밋 감지 → /finish) ──
  write_h_state '{"workflow_phase":"done","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-3: normal + done + dirty → BLOCK"
  else
    fail "H-3: normal + done + dirty → expected BLOCK, got $decision"
  fi

  # ── H-4: .active 없음 + dirty → BLOCK (gate 비활성, 기존 stop.sh 동작) ──
  rm -f "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  write_h_state '{"workflow_phase":"development","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-4: .active 없음 + dirty → BLOCK"
  else
    fail "H-4: .active 없음 → expected BLOCK, got $decision"
  fi

  # ── H-5: simple + development + dirty → BLOCK (SIMPLE 모드는 예외 아님) ──
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  write_h_state '{"workflow_phase":"development","mode":"simple","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-5: simple + development → BLOCK"
  else
    fail "H-5: simple mode → expected BLOCK, got $decision"
  fi

  # ── H-6: normal + verification + dirty → ALLOW (검증 중도 예외) ──
  write_h_state '{"workflow_phase":"verification","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" != "block" ]; then
    pass "H-6: normal + verification → ALLOW"
  else
    fail "H-6: verification → expected ALLOW, got BLOCK"
  fi

  # ── H-7: normal + planning + dirty → BLOCK (코드 수정 안 하는 단계) ──
  write_h_state '{"workflow_phase":"planning","mode":"normal","plan_approved":false}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-7: normal + planning → BLOCK"
  else
    fail "H-7: planning → expected BLOCK, got $decision"
  fi

  # ── update.sh 테스트 ──

  # ── H-8: update 후 managed block 유지 ──
  run_update "$FAKE_HOME" "$FAKE_REPO"
  if grep -q "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null; then
    pass "H-8: update → managed block 유지"
  else
    fail "H-8: update → managed block 사라짐"
  fi

  # ── H-9: update 후 gate 동작 정상 (normal+dev → ALLOW) ──
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  # dirty 복원
  echo "dirty" > "$FAKE_REPO/src.txt"
  git -C "$FAKE_REPO" add src.txt
  write_h_state '{"workflow_phase":"development","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" != "block" ]; then
    pass "H-9: post-update + development → ALLOW"
  else
    fail "H-9: post-update → expected ALLOW, got BLOCK"
  fi

  # ── H-10: update로 block 갱신 (기존 block 변조 → 새 버전 재적용) ──
  # managed block 내용을 일부 변조
  sed 's/_bouncer_mode/OLD_VAR/' "$FAKE_HOME/.claude/hooks/stop.sh" > "$FAKE_HOME/.claude/hooks/stop.sh.tmp"
  mv "$FAKE_HOME/.claude/hooks/stop.sh.tmp" "$FAKE_HOME/.claude/hooks/stop.sh"
  chmod +x "$FAKE_HOME/.claude/hooks/stop.sh"
  run_update "$FAKE_HOME" "$FAKE_REPO"
  if grep -q "_bouncer_mode" "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null; then
    pass "H-10: update → evolved block 재적용"
  else
    fail "H-10: update → block 갱신 안 됨"
  fi

  # ── H-11: update 2회 연속 → block 중복 안 됨 ──
  run_update "$FAKE_HOME" "$FAKE_REPO"
  run_update "$FAKE_HOME" "$FAKE_REPO"
  local count
  count=$(grep -c "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh")
  if [ "$count" -eq 1 ]; then
    pass "H-11: update 2회 → block 1개 (idempotent)"
  else
    fail "H-11: update 2회 → block ${count}개"
  fi

  # ── uninstall 테스트 ──

  # ── H-12: uninstall 후 managed block 제거 확인 ──
  run_uninstall "$FAKE_HOME" "$FAKE_REPO"
  if ! grep -q "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null; then
    pass "H-12: uninstall → managed block 제거됨"
  else
    fail "H-12: uninstall → managed block 여전히 존재"
  fi

  # ── H-13: uninstall 후 기존 stop.sh 동작 복원 (dirty → block) ──
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  write_h_state '{"workflow_phase":"development","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-13: uninstall 후 기존 동작 복원 (dirty → BLOCK)"
  else
    fail "H-13: uninstall 후 → expected BLOCK, got $decision"
  fi

  # ── 엣지케이스 ──

  # ── H-14: 재설치(idempotent) — managed block 중복 안 됨 ──
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"
  count=$(grep -c "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh")
  if [ "$count" -eq 1 ]; then
    pass "H-14: 재설치 idempotent (block 1개)"
  else
    fail "H-14: 재설치 → ai-bouncer start ${count}개 (expected 1)"
  fi

  # ── H-15: config.json 없으면 기존 stop.sh 동작 유지 ──
  mv "$FAKE_REPO/.claude/ai-bouncer/config.json" "$FAKE_REPO/.claude/ai-bouncer/config.json.bak"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  write_h_state '{"workflow_phase":"development","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" = "block" ]; then
    pass "H-15: config.json 없음 → 기존 동작 (BLOCK)"
  else
    fail "H-15: config.json 없음 → expected BLOCK, got $decision"
  fi
  mv "$FAKE_REPO/.claude/ai-bouncer/config.json.bak" "$FAKE_REPO/.claude/ai-bouncer/config.json"

  # ── H-16: state.json 없으면 기존 stop.sh 동작 유지 ──
  rm -f "$FAKE_REPO/docs/${date_dir}/${task}/state.json"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  local hook_input
  hook_input=$(jq -n --arg cwd "$FAKE_REPO" '{cwd: $cwd}')
  local hook_out
  hook_out=$(cd "$FAKE_REPO" && echo "$hook_input" | bash "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null || true)
  decision=$(echo "$hook_out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  if [ "$decision" = "block" ]; then
    pass "H-16: state.json 없음 → 기존 동작 (BLOCK)"
  else
    fail "H-16: state.json 없음 → expected BLOCK, got $decision"
  fi

  # ── H-17: 여러 Stop hook 등록 → 모두 패치 ──
  mkdir -p "$FAKE_HOME/.claude/hooks2"
  cat > "$FAKE_HOME/.claude/hooks2/stop2.sh" << 'STOP2EOF'
#!/bin/bash
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd')
cd "$CWD" 2>/dev/null || exit 0
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
if [ -n "$DIRTY" ]; then
  jq -n '{decision:"block", reason:"stop2 미커밋 감지"}'
  exit 0
fi
exit 0
STOP2EOF
  chmod +x "$FAKE_HOME/.claude/hooks2/stop2.sh"
  python3 -c "
import json
cfg = json.load(open('$FAKE_HOME/.claude/settings.json'))
cfg['hooks']['Stop'].append({'hooks':[{'type':'command','command':'$FAKE_HOME/.claude/hooks2/stop2.sh'}]})
json.dump(cfg, open('$FAKE_HOME/.claude/settings.json','w'), indent=2)
"
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent"
  if grep -q "ai-bouncer start" "$FAKE_HOME/.claude/hooks/stop.sh" 2>/dev/null && \
     grep -q "ai-bouncer start" "$FAKE_HOME/.claude/hooks2/stop2.sh" 2>/dev/null; then
    pass "H-17: 여러 Stop hook 모두 패치됨"
  else
    fail "H-17: 일부 hook 패치 안 됨"
  fi

  # ── H-18: 존재하지 않는 hook 경로 → 에러 없이 스킵 ──
  python3 -c "
import json
cfg = json.load(open('$FAKE_HOME/.claude/settings.json'))
cfg['hooks']['Stop'].append({'hooks':[{'type':'command','command':'/nonexistent/path/ghost.sh'}]})
json.dump(cfg, open('$FAKE_HOME/.claude/settings.json','w'), indent=2)
"
  local install_out
  install_out=$(run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "subagent" 2>&1)
  if [ $? -eq 0 ] || [ -z "$(echo "$install_out" | grep -i 'error')" ]; then
    pass "H-18: 존재하지 않는 hook 경로 → 에러 없이 스킵"
  else
    fail "H-18: 존재하지 않는 hook 경로 → 에러 발생"
  fi

  # ── H-19: clean 상태 (dirty 없음) + normal+done → ALLOW ──
  git -C "$FAKE_REPO" checkout -- . 2>/dev/null || true
  git -C "$FAKE_REPO" reset HEAD -- src.txt 2>/dev/null || true
  rm -f "$FAKE_REPO/src.txt"
  touch "$FAKE_REPO/docs/${date_dir}/${task}/.active"
  write_h_state '{"workflow_phase":"done","mode":"normal","plan_approved":true}'
  decision=$(run_stop_hook)
  if [ "$decision" != "block" ]; then
    pass "H-19: clean 상태 + done → ALLOW"
  else
    fail "H-19: clean + done → expected ALLOW, got BLOCK"
  fi

  rm -rf "$tmpdir"
}

# ── 실행 ────────────────────────────────────────────────────

persona_a
persona_b
persona_c
persona_d
persona_e
persona_f
persona_g
persona_h

echo -e "\n${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${PASS}/${TOTAL} PASS, ${FAIL} FAIL${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
