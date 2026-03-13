#!/bin/bash
# e2e-workflow.sh — ai-bouncer Full Workflow Integration E2E Tests
# 6가지 모드 조합(team/subagent/single × hooks/prompt-only)의
# NORMAL 모드 전체 상태 머신을 시뮬레이션하여 hook 동작 검증.
# Usage: bash tests/e2e-workflow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✅${NC} $*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}❌${NC} $*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

# ── 환경 헬퍼 ─────────────────────────────────────────────────

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
  local FAKE_HOME="$1" FAKE_REPO="$2" enforcement="${3:-hooks}" agent="${4:-team}"
  (cd "$FAKE_REPO" && export HOME="$FAKE_HOME" && \
    ENFORCEMENT_MODE="$enforcement" AGENT_MODE="$agent" CI=true \
    bash "$REPO_DIR/install.sh" 2>&1) || true
}

has_hook() {
  local settings="$1" hook_name="$2"
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
assert found
"
}

has_no_hook() {
  local settings="$1" hook_name="$2"
  python3 -c "
import json
cfg = json.load(open('$settings'))
hooks = cfg.get('hooks', {})
for ht in hooks.values():
    for g in ht:
        for h in g.get('hooks', []):
            assert '$hook_name' not in h.get('command', '')
"
}

config_has() {
  local config="$1" key="$2" val="$3"
  python3 -c "
import json
cfg = json.load(open('$config'))
assert str(cfg.get('$key', '')) == '$val'
"
}

# ── State / 문서 헬퍼 ────────────────────────────────────────

write_state() {
  local state_file="$1" json_str="$2"
  echo "$json_str" | python3 -c "
import json, sys
data = json.load(sys.stdin)
with open('$state_file', 'w') as f:
    json.dump(data, f, indent=2)
"
}

DEV_PHASES_2x2='{
  "1": {"name": "setup", "folder": "phase-1-setup", "steps": {"1": {"title": "S1"}, "2": {"title": "S2"}}},
  "2": {"name": "impl", "folder": "phase-2-impl", "steps": {"1": {"title": "S1"}, "2": {"title": "S2"}}}
}'

make_state() {
  local phase="$1" approved="$2" team_name="$3" dev_phase="$4" step="$5" dev_phases="$6"
  cat <<SJSON
{
  "workflow_phase": "$phase",
  "plan_approved": $approved,
  "mode": "normal",
  "team_name": "$team_name",
  "current_dev_phase": $dev_phase,
  "current_step": $step,
  "dev_phases": $dev_phases,
  "verification": {"rounds_passed": 0}
}
SJSON
}

create_phase_dir() {
  local task_dir="$1" phase_folder="$2" num_steps="$3"
  local phase_dir="${task_dir}/${phase_folder}"
  mkdir -p "$phase_dir"
  cat > "$phase_dir/phase.md" <<'PHASEEOF'
# Phase

## 목표
- goal

## 범위
- scope

## Steps
PHASEEOF
  for i in $(seq 1 "$num_steps"); do
    echo "- Step $i" >> "$phase_dir/phase.md"
    cat > "$phase_dir/step-${i}.md" <<STEPEOF
# Step $i
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | test | expected |  |
STEPEOF
  done
}

mark_step_complete() {
  cat > "$1" <<'DONEEOF'
# Step
## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | test | expected | ✅ |

## 실행 결과
$ pytest
1 passed
DONEEOF
}

create_rounds() {
  local task_dir="$1" count="$2"
  local verify_dir="${task_dir}/verifications"
  mkdir -p "$verify_dir"
  for i in $(seq 1 "$count"); do
    printf "통과\n\n## 결론\n통과\n" > "$verify_dir/round-${i}.md"
  done
}

# ── Hook Runner ───────────────────────────────────────────────

run_plan_gate() {
  local fake_repo="$1" target="$2" fake_home="$3"
  local input='{"tool_name":"Write","tool_input":{"file_path":"/src/feat.ts"}}'
  local out
  out=$(cd "$fake_repo" && export HOME="$fake_home" && echo "$input" | bash "$target/hooks/plan-gate.sh" 2>/dev/null || true)
  echo "$out" | grep -q '"block"' 2>/dev/null && echo "block" || echo "allow"
}

run_bash_gate_write() {
  local fake_repo="$1" target="$2" fake_home="$3"
  local input='{"tool_name":"Bash","tool_input":{"command":"echo test > file.txt"}}'
  local out
  out=$(cd "$fake_repo" && export HOME="$fake_home" && echo "$input" | bash "$target/hooks/bash-gate.sh" 2>/dev/null || true)
  echo "$out" | grep -q '"block"' 2>/dev/null && echo "block" || echo "allow"
}

run_bash_gate_commit() {
  local fake_repo="$1" target="$2" fake_home="$3"
  local input='{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}'
  local out
  out=$(cd "$fake_repo" && export HOME="$fake_home" && echo "$input" | bash "$target/hooks/bash-gate.sh" 2>/dev/null || true)
  echo "$out" | grep -q '"block"' 2>/dev/null && echo "block" || echo "allow"
}

run_completion_gate() {
  local fake_repo="$1" target="$2" fake_home="$3"
  local out
  out=$(cd "$fake_repo" && export HOME="$fake_home" && echo '{}' | bash "$target/hooks/completion-gate.sh" 2>/dev/null || true)
  echo "$out" | grep -q '"block"' 2>/dev/null && echo "block" || echo "allow"
}

assert_decision() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (expected=$expected, got=$actual)"
  fi
}

# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer Workflow Integration E2E${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

# ── hooks 워크플로우 시뮬레이션 ───────────────────────────────

simulate_hooks_workflow() {
  local agent_mode="$1"
  echo -e "\n${BOLD}─── hooks + ${agent_mode} ───${NC}"

  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  # W1: Install
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "hooks" "$agent_mode"
  check "W1[$agent_mode]: install OK" test -f "$CONFIG"
  check "W1[$agent_mode]: plan-gate 등록" has_hook "$SETTINGS" "plan-gate"
  check "W1[$agent_mode]: bash-gate 등록" has_hook "$SETTINGS" "bash-gate"
  check "W1[$agent_mode]: completion-gate 등록" has_hook "$SETTINGS" "completion-gate"

  # team 모드: team config 생성
  local TEAM_VAL=""
  if [ "$agent_mode" = "team" ]; then
    TEAM_VAL="wf-team"
    mkdir -p "$FAKE_HOME/.claude/teams/wf-team"
    echo '{"members":["lead-agent"]}' > "$FAKE_HOME/.claude/teams/wf-team/config.json"
  fi

  # docs 구조 생성
  local DOCS_DIR="$FAKE_REPO/docs/2026-01-15/wf-test"
  mkdir -p "$DOCS_DIR"
  touch "$DOCS_DIR/.active"
  echo "# Plan" > "$DOCS_DIR/plan.md"

  # W2: planning → 전부 차단
  write_state "$DOCS_DIR/state.json" "$(make_state planning false "$TEAM_VAL" 0 0 '{}')"
  local d
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W2[$agent_mode]: planning → plan-gate BLOCK" "$d" "block"
  d=$(run_bash_gate_write "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W2[$agent_mode]: planning → bash-gate BLOCK" "$d" "block"

  # W3: development + dev_phases={} → 차단
  write_state "$DOCS_DIR/state.json" "$(make_state development true "$TEAM_VAL" 1 1 '{}')"
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W3[$agent_mode]: dev + dev_phases={} → BLOCK" "$d" "block"

  # W4: dev_phases 있지만 phase dir 없음 → 차단
  write_state "$DOCS_DIR/state.json" "$(make_state development true "$TEAM_VAL" 1 1 "$DEV_PHASES_2x2")"
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W4[$agent_mode]: no phase dir → BLOCK" "$d" "block"

  # W5: phase-1 생성 → 허용
  create_phase_dir "$DOCS_DIR" "phase-1-setup" 2
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W5[$agent_mode]: phase-1/step-1 → ALLOW" "$d" "allow"
  d=$(run_bash_gate_write "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W5[$agent_mode]: bash write → ALLOW" "$d" "allow"

  # W6: step-1 미완료 → commit 차단
  d=$(run_bash_gate_commit "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W6[$agent_mode]: step-1 미완료 → commit BLOCK" "$d" "block"

  # W7: step-1 완료 → commit 허용
  mark_step_complete "$DOCS_DIR/phase-1-setup/step-1.md"
  d=$(run_bash_gate_commit "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W7[$agent_mode]: step-1 완료 → commit ALLOW" "$d" "allow"

  # W8: step-2 (prev complete) → write 허용
  write_state "$DOCS_DIR/state.json" "$(make_state development true "$TEAM_VAL" 1 2 "$DEV_PHASES_2x2")"
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W8[$agent_mode]: step-2 (prev OK) → ALLOW" "$d" "allow"

  # W9: step-2 완료 → commit 허용
  mark_step_complete "$DOCS_DIR/phase-1-setup/step-2.md"
  d=$(run_bash_gate_commit "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W9[$agent_mode]: step-2 완료 → commit ALLOW" "$d" "allow"

  # W10: phase-2 dir 없음 → 차단
  write_state "$DOCS_DIR/state.json" "$(make_state development true "$TEAM_VAL" 2 1 "$DEV_PHASES_2x2")"
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W10[$agent_mode]: phase-2 no dir → BLOCK" "$d" "block"

  # W11: phase-2 생성 → 허용
  create_phase_dir "$DOCS_DIR" "phase-2-impl" 2
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W11[$agent_mode]: phase-2 created → ALLOW" "$d" "allow"

  # W12: phase-2/step-1 완료 → commit
  mark_step_complete "$DOCS_DIR/phase-2-impl/step-1.md"
  d=$(run_bash_gate_commit "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W12[$agent_mode]: phase-2/step-1 → commit ALLOW" "$d" "allow"

  # W13: phase-2/step-2 완료 → commit
  write_state "$DOCS_DIR/state.json" "$(make_state development true "$TEAM_VAL" 2 2 "$DEV_PHASES_2x2")"
  mark_step_complete "$DOCS_DIR/phase-2-impl/step-2.md"
  d=$(run_bash_gate_commit "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W13[$agent_mode]: phase-2/step-2 → commit ALLOW" "$d" "allow"

  # W14: verification + 0 rounds → completion-gate 차단
  write_state "$DOCS_DIR/state.json" "$(make_state verification true "$TEAM_VAL" 2 2 "$DEV_PHASES_2x2")"
  d=$(run_completion_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W14[$agent_mode]: verification 0 rounds → BLOCK" "$d" "block"

  # W15: 2 rounds → 여전히 차단
  create_rounds "$DOCS_DIR" 2
  d=$(run_completion_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W15[$agent_mode]: 2 rounds → BLOCK" "$d" "block"

  # W16: 3 rounds → 통과
  create_rounds "$DOCS_DIR" 3
  d=$(run_completion_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W16[$agent_mode]: 3 rounds → ALLOW" "$d" "allow"

  # W17: verification + plan-gate (all phases done) → 허용
  d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
  assert_decision "W17[$agent_mode]: verification plan-gate → ALLOW" "$d" "allow"

  # W18: agent_mode 특화 team_name 검증
  if [ "$agent_mode" = "team" ]; then
    write_state "$DOCS_DIR/state.json" "$(make_state development true '' 1 1 '{"1":{"name":"s","folder":"phase-1-setup","steps":{"1":{"title":"S1"}}}}')"
    d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
    assert_decision "W18[team]: team_name='' → plan-gate BLOCK" "$d" "block"
    d=$(run_bash_gate_write "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
    assert_decision "W18[team]: team_name='' → bash-gate BLOCK" "$d" "block"
  else
    write_state "$DOCS_DIR/state.json" "$(make_state development true '' 1 1 '{"1":{"name":"s","folder":"phase-1-setup","steps":{"1":{"title":"S1"}}}}')"
    d=$(run_plan_gate "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
    assert_decision "W18[$agent_mode]: team_name='' → plan-gate ALLOW" "$d" "allow"
    d=$(run_bash_gate_write "$FAKE_REPO" "$TARGET" "$FAKE_HOME")
    assert_decision "W18[$agent_mode]: team_name='' → bash-gate ALLOW" "$d" "allow"
  fi

  rm -rf "$tmpdir"
}

# ── prompt-only 워크플로우 시뮬레이션 ─────────────────────────

simulate_prompt_only_workflow() {
  local agent_mode="$1"
  echo -e "\n${BOLD}─── prompt-only + ${agent_mode} ───${NC}"

  local tmpdir
  tmpdir=$(setup_fake_env)
  local FAKE_HOME="$tmpdir/home"
  local FAKE_REPO="$tmpdir/repo"
  local TARGET="$FAKE_REPO/.claude"
  local CONFIG="$TARGET/ai-bouncer/config.json"
  local SETTINGS="$TARGET/settings.json"

  # P1: Install
  run_install_modes "$FAKE_HOME" "$FAKE_REPO" "prompt-only" "$agent_mode"
  check "P1[$agent_mode]: install OK" test -f "$CONFIG"
  check "P1[$agent_mode]: enforcement=prompt-only" config_has "$CONFIG" "enforcement_mode" "prompt-only"
  check "P1[$agent_mode]: agent_mode=$agent_mode" config_has "$CONFIG" "agent_mode" "$agent_mode"

  # P2: hooks 미등록
  if [ -f "$SETTINGS" ]; then
    check "P2[$agent_mode]: no plan-gate" has_no_hook "$SETTINGS" "plan-gate"
    check "P2[$agent_mode]: no bash-gate" has_no_hook "$SETTINGS" "bash-gate"
    check "P2[$agent_mode]: no completion-gate" has_no_hook "$SETTINGS" "completion-gate"
  else
    pass "P2[$agent_mode]: settings.json 없음 (hooks 미등록)"
  fi

  # P3: CLAUDE.md 존재 + ai-bouncer rule
  check "P3[$agent_mode]: CLAUDE.md 존재" test -f "$TARGET/CLAUDE.md"
  check "P3[$agent_mode]: ai-bouncer rule" grep -q "ai-bouncer-rule" "$TARGET/CLAUDE.md"

  # P4: SKILL.md 설치
  check "P4[$agent_mode]: SKILL.md" test -f "$TARGET/skills/dev-bounce/SKILL.md"

  # P5: agents 설치
  check "P5[$agent_mode]: intent.md" test -f "$TARGET/agents/intent.md"
  check "P5[$agent_mode]: lead.md" test -f "$TARGET/agents/lead.md"

  rm -rf "$tmpdir"
}

# ── 6가지 조합 실행 ───────────────────────────────────────────

simulate_hooks_workflow "team"
simulate_hooks_workflow "subagent"
simulate_hooks_workflow "single"

simulate_prompt_only_workflow "team"
simulate_prompt_only_workflow "subagent"
simulate_prompt_only_workflow "single"

# ── 결과 ──────────────────────────────────────────────────────
echo -e "\n${BOLD}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ✅ $PASS 통과 / ❌ $FAIL 실패${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
