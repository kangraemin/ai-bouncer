#!/usr/bin/env bash
# E2E tests for SKILL.md dev-bounce logic
# Tests: Phase 0-B path selection, context restore, Phase 4-4 copy
# Usage: bash tests/e2e-skill.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; echo "       → $2"; ((FAIL_COUNT++)) || true; }

TMPDIR_ROOT=$(mktemp -d)
FAKE_HOME=$(mktemp -d)
FAKE_DATE="2026-01-15"

cleanup() { rm -rf "$TMPDIR_ROOT" "$FAKE_HOME"; }
trap cleanup EXIT

# Create a git repo with one real commit (avoids --allow-empty)
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init "$dir" -q
  touch "$dir/.gitkeep"
  git -C "$dir" add .gitkeep
  git -C "$dir" -c user.email=test@test.com -c user.name=Test commit -m "init" -q
}

# ---------------------------------------------------------------------------
# Phase 0-B Python logic (from SKILL.md — date-based, worktree-only persistent)
# ---------------------------------------------------------------------------
PHASE0B_PY='
import json, os, subprocess, sys

home      = os.environ["FAKE_HOME"]
task_name = sys.argv[1]
date_str  = os.environ.get("FAKE_DATE", "2026-01-15")

git_dir = subprocess.run(["git", "rev-parse", "--git-dir"],
    capture_output=True, text=True).stdout.strip()
is_worktree = "worktrees" in git_dir

repo_root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
    capture_output=True, text=True).stdout.strip()
repo_name = os.path.basename(repo_root)

persistent_mode = is_worktree  # worktree만 예외
if persistent_mode:
    docs_base = os.path.join(home, f".claude/ai-bouncer/sessions/{repo_name}/docs")
else:
    docs_base = os.path.join(repo_root, "docs", date_str)

task_dir    = os.path.join(docs_base, task_name)
active_file = os.path.join(task_dir, ".active")

os.makedirs(task_dir, exist_ok=True)
with open(active_file, "w") as f:
    f.write("")

state = {
    "workflow_phase": "planning",
    "task_dir": task_dir,
    "active_file": active_file,
    "persistent_mode": persistent_mode,
    "repo_root": repo_root,
    "planning": {"no_question_streak": 0},
    "plan_approved": False,
    "team_spawned": False,
    "current_dev_phase": 0,
    "current_step": 0,
    "dev_phases": {},
    "verification": {"rounds_passed": 0}
}
with open(os.path.join(task_dir, "state.json"), "w") as f:
    json.dump(state, f, indent=2)

print(f"persistent_mode={persistent_mode}")
print(f"task_dir={task_dir}")
print(f"active_file={active_file}")
'

# ---------------------------------------------------------------------------
# Phase 4-4 copy Python logic (from SKILL.md — date-based destination)
# ---------------------------------------------------------------------------
PHASE44_PY='
import json, os, shutil, subprocess, sys

task_dir  = sys.argv[1]
date_str  = os.environ.get("FAKE_DATE", "2026-01-15")

state = json.load(open(os.path.join(task_dir, "state.json")))
if state.get("persistent_mode"):
    git_common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
        capture_output=True, text=True).stdout.strip()
    main_root = os.path.dirname(os.path.abspath(git_common))
    task_name = os.path.basename(state["task_dir"])
    dst = os.path.join(main_root, "docs", date_str, task_name)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(state["task_dir"], dst)
    src = state["task_dir"]
    print(f"[docs 복사 완료] {src} -> {dst}")
    print(f"dst={dst}")
'

# ---------------------------------------------------------------------------
# Context restore bash logic (updated for date-based docs/*/*/.active)
# Runs inside repo dir; FAKE_HOME replaces $HOME
# ---------------------------------------------------------------------------
context_restore_bash() {
  local repo_dir="$1"
  local fake_home="$2"
  (cd "$repo_dir" && HOME="$fake_home" bash -c '
    REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

    TASK_NAME=""
    STATE_JSON=""
    TASK_DIR=""

    # 1. persistent dir (worktree용)
    PERSISTENT_BASE="$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs"
    if [ -d "$PERSISTENT_BASE" ]; then
      for active_file in "$PERSISTENT_BASE"/*/.active; do
        [ -f "$active_file" ] || continue
        task_folder=$(basename "$(dirname "$active_file")")
        state_json="${PERSISTENT_BASE}/${task_folder}/state.json"
        [ -f "$state_json" ] || continue
        TASK_NAME="$task_folder"
        STATE_JSON="$state_json"
        TASK_DIR="${PERSISTENT_BASE}/${task_folder}"
        break
      done
    fi

    # 2. local docs/ — 날짜별 구조 (docs/YYYY-MM-DD/task-name/.active)
    if [ -z "$TASK_NAME" ] && [ -d "docs" ]; then
      for date_dir in docs/*/; do
        [ -d "$date_dir" ] || continue
        for active_file in "$date_dir"*/.active; do
          [ -f "$active_file" ] || continue
          task_folder=$(basename "$(dirname "$active_file")")
          state_json="$(dirname "$active_file")/state.json"
          [ -f "$state_json" ] || continue
          TASK_NAME="$task_folder"
          STATE_JSON="$state_json"
          break 2
        done
      done
    fi

    # 3. fallback: 기존 flat 구조 (docs/task-name/.active — 하위 호환)
    if [ -z "$TASK_NAME" ] && [ -d "docs" ]; then
      for active_file in docs/*/.active; do
        [ -f "$active_file" ] || continue
        task_folder=$(basename "$(dirname "$active_file")")
        state_json="docs/${task_folder}/state.json"
        [ -f "$state_json" ] || continue
        TASK_NAME="$task_folder"
        STATE_JSON="$state_json"
        break
      done
    fi

    echo "$STATE_JSON"
  ')
}

# ---------------------------------------------------------------------------
# TC-1: worktree → persistent path
# ---------------------------------------------------------------------------
tc1() {
  local main_repo="$TMPDIR_ROOT/tc1-main"
  local worktree_dir="$TMPDIR_ROOT/tc1-worktree"

  make_repo "$main_repo"
  git -C "$main_repo" worktree add "$worktree_dir" -q

  local repo_name; repo_name=$(basename "$worktree_dir")
  local expected_task_dir="$FAKE_HOME/.claude/ai-bouncer/sessions/${repo_name}/docs/my-task"

  local out
  out=$(cd "$worktree_dir" && FAKE_HOME="$FAKE_HOME" FAKE_DATE="$FAKE_DATE" python3 -c "$PHASE0B_PY" "my-task")

  local pm; pm=$(echo "$out" | grep "^persistent_mode=" | cut -d= -f2)
  local td; td=$(echo "$out" | grep "^task_dir=" | cut -d= -f2)
  local af; af=$(echo "$out" | grep "^active_file=" | cut -d= -f2)
  local expected_active="$expected_task_dir/.active"

  if [ "$pm" = "True" ] && \
     [ "$td" = "$expected_task_dir" ] && \
     [ "$af" = "$expected_active" ] && \
     [ -f "$expected_task_dir/state.json" ]; then
    local pm_json; pm_json=$(python3 -c "import json; print(json.load(open('$expected_task_dir/state.json'))['persistent_mode'])")
    if [ "$pm_json" = "True" ]; then
      pass "TC-1: worktree → persistent path"
    else
      fail "TC-1: worktree → persistent path" "state.json persistent_mode=$pm_json (expected True)"
    fi
  else
    fail "TC-1: worktree → persistent path" \
         "persistent_mode=$pm, task_dir=$td (expected $expected_task_dir)"
  fi
}

# ---------------------------------------------------------------------------
# TC-2: normal repo → local date-based path
# ---------------------------------------------------------------------------
tc2() {
  local repo="$TMPDIR_ROOT/tc2-repo"
  make_repo "$repo"

  local out
  out=$(cd "$repo" && FAKE_HOME="$FAKE_HOME" FAKE_DATE="$FAKE_DATE" python3 -c "$PHASE0B_PY" "my-task")

  local pm; pm=$(echo "$out" | grep "^persistent_mode=" | cut -d= -f2)
  local td; td=$(echo "$out" | grep "^task_dir=" | cut -d= -f2)

  local expected_task_dir; expected_task_dir=$(python3 -c "import os; print(os.path.realpath('$repo'))")/docs/${FAKE_DATE}/my-task

  if [ "$pm" = "False" ] && [ "$td" = "$expected_task_dir" ] && \
     [ -f "$expected_task_dir/state.json" ]; then
    local pm_json; pm_json=$(python3 -c "import json; print(json.load(open('$expected_task_dir/state.json'))['persistent_mode'])")
    if [ "$pm_json" = "False" ]; then
      pass "TC-2: normal repo → local date-based path"
    else
      fail "TC-2: normal repo → local date-based path" "state.json persistent_mode=$pm_json (expected False)"
    fi
  else
    fail "TC-2: normal repo → local date-based path" \
         "persistent_mode=$pm, task_dir=$td (expected $expected_task_dir)"
  fi
}

# ---------------------------------------------------------------------------
# TC-3: docs_git_track=false → still local (no longer triggers persistent)
# ---------------------------------------------------------------------------
tc3() {
  local repo="$TMPDIR_ROOT/tc3-repo"
  make_repo "$repo"

  # Write config with docs_git_track=false — should NOT trigger persistent anymore
  mkdir -p "$FAKE_HOME/.claude/ai-bouncer"
  echo '{"docs_git_track": false}' > "$FAKE_HOME/.claude/ai-bouncer/config.json"

  local out
  out=$(cd "$repo" && FAKE_HOME="$FAKE_HOME" FAKE_DATE="$FAKE_DATE" python3 -c "$PHASE0B_PY" "my-task")

  local pm; pm=$(echo "$out" | grep "^persistent_mode=" | cut -d= -f2)
  local td; td=$(echo "$out" | grep "^task_dir=" | cut -d= -f2)

  # Clean up config for other tests
  rm "$FAKE_HOME/.claude/ai-bouncer/config.json"

  local expected_task_dir; expected_task_dir=$(python3 -c "import os; print(os.path.realpath('$repo'))")/docs/${FAKE_DATE}/my-task

  if [ "$pm" = "False" ] && [ "$td" = "$expected_task_dir" ] && \
     [ -f "$expected_task_dir/state.json" ]; then
    pass "TC-3: docs_git_track=false → still local (worktree-only persistent)"
  else
    fail "TC-3: docs_git_track=false → still local" \
         "persistent_mode=$pm, task_dir=$td (expected $expected_task_dir)"
  fi
}

# ---------------------------------------------------------------------------
# TC-4: context restore — persistent .active takes priority over local
# ---------------------------------------------------------------------------
tc4() {
  local repo="$TMPDIR_ROOT/tc4-repo"
  make_repo "$repo"

  local repo_name; repo_name=$(basename "$repo")
  local persistent_docs="$FAKE_HOME/.claude/ai-bouncer/sessions/${repo_name}/docs"
  local local_docs="$repo/docs/$FAKE_DATE"

  # Create persistent task with per-task .active
  mkdir -p "$persistent_docs/persistent-task"
  touch "$persistent_docs/persistent-task/.active"
  local persistent_state="$persistent_docs/persistent-task/state.json"
  echo '{"task":"persistent"}' > "$persistent_state"

  # Create local date-based task with per-task .active
  mkdir -p "$local_docs/local-task"
  touch "$local_docs/local-task/.active"
  echo '{"task":"local"}' > "$local_docs/local-task/state.json"

  local result; result=$(context_restore_bash "$repo" "$FAKE_HOME")

  if [ "$result" = "$persistent_state" ]; then
    pass "TC-4: context restore — persistent .active priority"
  else
    fail "TC-4: context restore — persistent .active priority" \
         "STATE_JSON=$result (expected $persistent_state)"
  fi
}

# ---------------------------------------------------------------------------
# TC-5: context restore — no persistent → local date-based fallback
# ---------------------------------------------------------------------------
tc5() {
  local repo="$TMPDIR_ROOT/tc5-repo"
  make_repo "$repo"

  local repo_name; repo_name=$(basename "$repo")
  local local_docs="$repo/docs/$FAKE_DATE"

  # Only local date-based .active (no persistent)
  mkdir -p "$local_docs/local-task"
  touch "$local_docs/local-task/.active"
  echo '{"task":"local"}' > "$local_docs/local-task/state.json"

  # Ensure no persistent .active exists
  local persistent_docs="$FAKE_HOME/.claude/ai-bouncer/sessions/${repo_name}/docs"
  rm -rf "$persistent_docs" 2>/dev/null || true

  local result; result=$(context_restore_bash "$repo" "$FAKE_HOME")
  local expected="docs/$FAKE_DATE/local-task/state.json"

  if [ "$result" = "$expected" ]; then
    pass "TC-5: context restore — local date-based fallback"
  else
    fail "TC-5: context restore — local date-based fallback" \
         "STATE_JSON=$result (expected $expected)"
  fi
}

# ---------------------------------------------------------------------------
# TC-5b: context restore — flat fallback (legacy docs/task/.active)
# ---------------------------------------------------------------------------
tc5b() {
  local repo="$TMPDIR_ROOT/tc5b-repo"
  make_repo "$repo"

  local repo_name; repo_name=$(basename "$repo")

  # Only legacy flat .active (no persistent, no date-based)
  mkdir -p "$repo/docs/legacy-task"
  touch "$repo/docs/legacy-task/.active"
  echo '{"task":"legacy"}' > "$repo/docs/legacy-task/state.json"

  # Ensure no persistent .active exists
  local persistent_docs="$FAKE_HOME/.claude/ai-bouncer/sessions/${repo_name}/docs"
  rm -rf "$persistent_docs" 2>/dev/null || true

  local result; result=$(context_restore_bash "$repo" "$FAKE_HOME")
  local expected="docs/legacy-task/state.json"

  if [ "$result" = "$expected" ]; then
    pass "TC-5b: context restore — flat fallback (legacy)"
  else
    fail "TC-5b: context restore — flat fallback (legacy)" \
         "STATE_JSON=$result (expected $expected)"
  fi
}

# ---------------------------------------------------------------------------
# TC-6: Phase 4-4 — persistent task_dir copied to main repo (date-based dst)
# ---------------------------------------------------------------------------
tc6() {
  local main_repo="$TMPDIR_ROOT/tc6-main"
  local worktree_dir="$TMPDIR_ROOT/tc6-worktree"

  make_repo "$main_repo"
  git -C "$main_repo" worktree add "$worktree_dir" -q

  local repo_name; repo_name=$(basename "$main_repo")
  local persistent_task="$FAKE_HOME/.claude/ai-bouncer/sessions/${repo_name}/docs/my-task"
  mkdir -p "$persistent_task"
  # Create state.json with persistent_mode=true
  python3 -c "
import json, os
state = {
  'persistent_mode': True,
  'task_dir': '$persistent_task',
  'workflow_phase': 'done'
}
json.dump(state, open('$persistent_task/state.json','w'), indent=2)
"
  # Add some extra files to verify they are copied too
  echo "plan content" > "$persistent_task/plan.md"

  # Run Phase 4-4 copy from within the worktree
  local out
  out=$(cd "$worktree_dir" && FAKE_HOME="$FAKE_HOME" FAKE_DATE="$FAKE_DATE" python3 -c "$PHASE44_PY" "$persistent_task")

  local dst; dst=$(echo "$out" | grep "^dst=" | cut -d= -f2)
  local expected_dst; expected_dst=$(python3 -c "import os; print(os.path.realpath('$main_repo'))")/docs/${FAKE_DATE}/my-task

  if [ "$dst" = "$expected_dst" ] && \
     [ -f "$expected_dst/state.json" ] && \
     [ -f "$expected_dst/plan.md" ]; then
    pass "TC-6: Phase 4-4 copy to main repo (date-based)"
  else
    fail "TC-6: Phase 4-4 copy to main repo (date-based)" \
         "dst=$dst (expected $expected_dst), state.json exists=$([ -f "$expected_dst/state.json" ] && echo yes || echo no)"
  fi
  # Store resolved dst for TC-7
  echo "$dst" > "$TMPDIR_ROOT/tc6-dst"
}

# ---------------------------------------------------------------------------
# TC-7: worktree deletion → main repo docs preserved
# ---------------------------------------------------------------------------
tc7() {
  local main_repo="$TMPDIR_ROOT/tc6-main"
  local worktree_dir="$TMPDIR_ROOT/tc6-worktree"
  local expected_dst; expected_dst=$(cat "$TMPDIR_ROOT/tc6-dst" 2>/dev/null || echo "")

  if [ -z "$expected_dst" ]; then
    fail "TC-7: worktree deletion → main docs preserved" "TC-6 dst not available"
    return
  fi

  # Remove the worktree
  git -C "$main_repo" worktree remove "$worktree_dir" --force -q 2>/dev/null || \
    rm -rf "$worktree_dir"

  if [ -d "$expected_dst" ] && [ -f "$expected_dst/state.json" ]; then
    pass "TC-7: worktree deletion → main docs preserved"
  else
    fail "TC-7: worktree deletion → main docs preserved" \
         "$expected_dst missing after worktree removal"
  fi
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== SKILL.md E2E Tests ===${NC}"
echo ""

tc1
tc2
tc3
tc4
tc5
tc5b
tc6
tc7

echo ""
echo "---"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✅ $PASS_COUNT/$TOTAL passed${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAIL_COUNT/$TOTAL failed${NC}"
  exit 1
fi
