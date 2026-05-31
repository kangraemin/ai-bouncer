#!/bin/bash
# gate-checks 차단이 blocks.log에 기록되는지 검증 (HOME 격리)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_GATE="$REPO/hooks/plan-gate.sh"
PASS=0; FAIL=0
ok(){ echo "✅ $1"; PASS=$((PASS+1)); }
ng(){ echo "❌ $1"; FAIL=$((FAIL+1)); }

setup(){  # 격리 HOME + 임시 task
  TMP=$(mktemp -d); export HOME="$TMP"; mkdir -p "$HOME/.claude"
  LOG="$HOME/.claude/ai-bouncer-blocks.log"
  PROJ="$TMP/proj"; mkdir -p "$PROJ/src"
  ( cd "$PROJ" && git init -q && git commit -q --allow-empty -m init 2>/dev/null )
  SID="t-sid"; TD="$PROJ/.ai-bouncer-tasks/2026-01-01/t"; mkdir -p "$TD/phase-1-x"
  echo "$SID" > "$TD/.active"
}
teardown(){ rm -rf "$TMP"; }
run_edit(){ python3 -c 'import json;print(json.dumps({"session_id":"'"$SID"'","tool_name":"Edit","tool_input":{"file_path":"'"$1"'","old_string":"a","new_string":"b"}}))' | ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" bash "$PLAN_GATE" 2>/dev/null ); }
loglines(){ [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }

# TC-1: development + plan.md 없음 → block + 로그 +1 + 코드 GC-NO-PLAN-MD
setup
printf '## 목표\nx\n## 기술 접근\ny\n## Steps\n- s\n' > "$TD/phase-1-x/phase.md"
printf '## 구현 목표\n- x\n' > "$TD/phase-1-x/step-1.md"
cat > "$TD/state.json" <<EOF
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"x","folder":"phase-1-x","steps":{"1":"a"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/t","active_file":".ai-bouncer-tasks/2026-01-01/t/.active"}
EOF
B=$(loglines); OUT=$(run_edit "$PROJ/src/foo.py"); A=$(loglines)
[ "$(echo "$OUT" | jq -r .decision)" = "block" ] && ok "TC-1: gate-checks 차단됨" || ng "TC-1: 차단 안 됨"
[ "$((A-B))" -ge 1 ] && ok "TC-1: blocks.log 기록됨(+$((A-B)))" || ng "TC-1: blocks.log 미기록"
grep -q "GC-NO-PLAN-MD" "$LOG" 2>/dev/null && ok "TC-1: GC-NO-PLAN-MD 코드 기록" || ng "TC-1: 코드 누락"
teardown

# TC-2: development + plan.md 있음 + TC 미정의 → block + reason 불변 + GC-TC-UNDEFINED
setup
printf '## 목표\nx\n## 기술 접근\ny\n## Steps\n- s\n' > "$TD/phase-1-x/phase.md"
printf '## 구현 목표\n- x (TC 없음)\n' > "$TD/phase-1-x/step-1.md"
printf '# plan\n' > "$TD/plan.md"
cat > "$TD/state.json" <<EOF
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"x","folder":"phase-1-x","steps":{"1":"a"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/t","active_file":".ai-bouncer-tasks/2026-01-01/t/.active"}
EOF
B=$(loglines); OUT=$(run_edit "$PROJ/src/foo.py"); A=$(loglines)
echo "$OUT" | jq -r .reason | grep -q "테스트 기준이 정의되지 않았습니다" && ok "TC-2: reason 불변(원본 유지)" || ng "TC-2: reason 변경됨"
grep -q "GC-TC-UNDEFINED" "$LOG" 2>/dev/null && ok "TC-2: GC-TC-UNDEFINED 기록" || ng "TC-2: 코드 누락"
teardown

# TC-3: 정상 상태(TC 충족) → allow + 로그 0 (오탐 없음)
setup
printf '## 목표\nx\n## 기술 접근\ny\n## Steps\n- s\n' > "$TD/phase-1-x/phase.md"
printf '## 테스트 기준\n| TC-ID | 유형 | 시나리오 | 기대 결과 | 실제 결과 |\n|--|--|--|--|--|\n| TC-1 | happy | 시나리오입니다 | 기대결과입니다 | |\n검증: `echo hi`\n' > "$TD/phase-1-x/step-1.md"
printf '# plan\n' > "$TD/plan.md"
cat > "$TD/state.json" <<EOF
{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"x","folder":"phase-1-x","steps":{"1":"a"},"depends_on":[],"team_name":""}},"task_dir":".ai-bouncer-tasks/2026-01-01/t","active_file":".ai-bouncer-tasks/2026-01-01/t/.active"}
EOF
B=$(loglines); OUT=$(run_edit "$PROJ/src/foo.py"); A=$(loglines)
[ -z "$OUT" ] && ok "TC-3: 정상 상태 통과(allow)" || ng "TC-3: 통과 안 됨 ($OUT)"
[ "$((A-B))" -eq 0 ] && ok "TC-3: 통과 시 로그 0(오탐 없음)" || ng "TC-3: 통과인데 로그 남음"
teardown

echo ""; echo "결과: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
