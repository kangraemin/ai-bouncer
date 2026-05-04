#!/bin/bash
# tests/test-phase-layers.sh — phase_layers 계산 + resolved_agent_mode + hook 호환성

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"
PASS=0; FAIL=0

check() {
  local label="$1" output="$2" expected="$3"
  local actual
  if [ -z "$output" ]; then
    actual="allow"
  else
    actual=$(echo "$output" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow")
  fi
  if [ "$actual" = "$expected" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (expected=$expected got=$actual)"; FAIL=$((FAIL+1))
  fi
}

check_val() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (expected=$expected got=$actual)"; FAIL=$((FAIL+1))
  fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# Kahn's algorithm Python snippet (SKILL.md Phase 3-1 Step 5와 동일)
compute_layers() {
  python3 -c "
import json, sys
s = json.load(open('$1'))
dp = s.get('dev_phases', {})
in_deg = {k: len(v.get('depends_on', [])) for k, v in dp.items()}
layers = []
ready = sorted([k for k, d in in_deg.items() if d == 0], key=int)
while ready:
    layers.append(ready)
    nxt = []
    for node in ready:
        for k, v in dp.items():
            if int(node) in [int(d) for d in v.get('depends_on', [])]:
                in_deg[k] -= 1
                if in_deg[k] == 0:
                    nxt.append(k)
    ready = sorted(nxt, key=int)
max_concurrent = max(len(l) for l in layers) if layers else 0
print(json.dumps({'layers': layers, 'max_concurrent': max_concurrent}))
"
}

decide_mode() {
  python3 -c "
max_c = $1; cfg = '$2'
print('single' if max_c == 1 else cfg)
"
}

# --- phase_layers 계산 ---

# TC-01: 전체 직렬 [1→2→3] → max_concurrent=1, 레이어 3개
cat > "$TMPDIR/s.json" <<'EOF'
{"dev_phases":{"1":{"depends_on":[]},"2":{"depends_on":[1]},"3":{"depends_on":[2]}}}
EOF
R=$(compute_layers "$TMPDIR/s.json")
check_val "TC-01: 직렬 max_concurrent=1" \
  "$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_concurrent'])")" "1"
check_val "TC-01: 직렬 레이어=3" \
  "$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['layers']))")" "3"

# TC-02: 2개 병렬 [1,2]→[3] → max_concurrent=2, 레이어 2개
cat > "$TMPDIR/s.json" <<'EOF'
{"dev_phases":{"1":{"depends_on":[]},"2":{"depends_on":[]},"3":{"depends_on":[1,2]}}}
EOF
R=$(compute_layers "$TMPDIR/s.json")
check_val "TC-02: 2개 병렬 max_concurrent=2" \
  "$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_concurrent'])")" "2"
check_val "TC-02: 2개 병렬 레이어=2" \
  "$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['layers']))")" "2"

# TC-03: 3개 병렬 [1,2,3]→[4] → max_concurrent=3
cat > "$TMPDIR/s.json" <<'EOF'
{"dev_phases":{"1":{"depends_on":[]},"2":{"depends_on":[]},"3":{"depends_on":[]},"4":{"depends_on":[1,2,3]}}}
EOF
R=$(compute_layers "$TMPDIR/s.json")
check_val "TC-03: 3개 병렬 max_concurrent=3" \
  "$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_concurrent'])")" "3"

# TC-04: 단일 Phase [1] → max_concurrent=1
cat > "$TMPDIR/s.json" <<'EOF'
{"dev_phases":{"1":{"depends_on":[]}}}
EOF
R=$(compute_layers "$TMPDIR/s.json")
check_val "TC-04: 단일 Phase max_concurrent=1" \
  "$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_concurrent'])")" "1"

# TC-05: 혼합 [(1,2)→(3,4)→5] → max_concurrent=2
cat > "$TMPDIR/s.json" <<'EOF'
{"dev_phases":{"1":{"depends_on":[]},"2":{"depends_on":[]},"3":{"depends_on":[1,2]},"4":{"depends_on":[1,2]},"5":{"depends_on":[3,4]}}}
EOF
R=$(compute_layers "$TMPDIR/s.json")
check_val "TC-05: 혼합 [(1,2)→(3,4)→5] max_concurrent=2" \
  "$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_concurrent'])")" "2"

# --- resolved_agent_mode 결정 ---

# TC-06: max_concurrent=1 + config=team → single (전체 직렬)
check_val "TC-06: 직렬 + config=team → single" "$(decide_mode 1 team)" "single"
# TC-07: max_concurrent=2 + config=team → team
check_val "TC-07: 병렬 + config=team → team" "$(decide_mode 2 team)" "team"
# TC-08: max_concurrent=2 + config=single → single (config 존중)
check_val "TC-08: 병렬 + config=single → single" "$(decide_mode 2 single)" "single"
# TC-09: max_concurrent=3 + config=team → team
check_val "TC-09: 3병렬 + config=team → team" "$(decide_mode 3 team)" "team"

# --- hook 호환성: 병렬 팀 에이전트가 current_dev_phase=1 기준으로 통과 ---
(cd "$TMPDIR" && git init -q && git config user.email t@t.com && git config user.name T)
mkdir -p "$TMPDIR/.claude/ai-bouncer"
cat > "$TMPDIR/.claude/ai-bouncer/config.json" <<'EOF'
{"agent_mode":"team","commit_strategy":"none"}
EOF
TASK_DIR="$TMPDIR/.ai-bouncer-tasks/2026-01-01/test-task"
mkdir -p "$TASK_DIR/verifications"
touch "$TASK_DIR/.active"
cat > "$TASK_DIR/state.json" <<'EOF'
{"workflow_phase":"development","plan_approved":true,"current_dev_phase":1,"current_step":1,
 "current_layer":0,"phase_layers":[["1","2"],["3"]],
 "dev_phases":{
   "1":{"name":"A","depends_on":[],"team_name":"task-p1","status":"pending"},
   "2":{"name":"B","depends_on":[],"team_name":"task-p2","status":"pending"},
   "3":{"name":"C","depends_on":[1,2],"team_name":"","status":"pending"}
 }}
EOF
SID="agent-p2-parallel-$$"
echo "$SID|$TASK_DIR" >> /tmp/.ai-bouncer-approved-agents

# TC-10: p2 에이전트가 current_dev_phase=1 (p1 기준)으로도 통과 (non-empty check)
OUT=$(cd "$TMPDIR" && IS_DELEGATED_AGENT=true SESSION_ID="$SID" \
  jq -n "{\"tool_name\":\"Write\",\"session_id\":\"$SID\",\"tool_input\":{\"file_path\":\"x.md\",\"content\":\"x\"}}" \
  | bash "$HOOKS_DIR/plan-gate.sh" 2>/dev/null || true)
check "TC-10: 병렬 p2 에이전트 team_name non-empty → allow" "$OUT" "allow"

sed -i.bak "/$SID/d" /tmp/.ai-bouncer-approved-agents 2>/dev/null
rm -f /tmp/.ai-bouncer-approved-agents.bak

# TC-11: install.sh에 subagent 선택 메뉴 없음 (Phase 3 완료 후 통과)
INSTALL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
SUBAGENT_MENU=$(grep -nE '"subagent"|AGENT_MODE="subagent"' "$INSTALL_SH" 2>/dev/null | grep -v '^\s*#' || true)
if [ -z "$SUBAGENT_MENU" ]; then
  echo "✅ TC-11: install.sh subagent 선택지 없음"; PASS=$((PASS+1))
else
  echo "❌ TC-11: install.sh에 subagent 활성 메뉴 존재"; echo "$SUBAGENT_MENU"; FAIL=$((FAIL+1))
fi

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
