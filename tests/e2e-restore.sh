#!/bin/bash
# E2E Session Restore Tests — SKILL.md 컨텍스트 복원 Python 스크립트 검증
# Usage: bash tests/e2e-restore.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✅${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}❌${NC} $*"; FAIL=$((FAIL + 1)); }

# 임시 디렉토리 생성 (.ai-bouncer-tasks/ 구조 시뮬레이션)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# SKILL.md에 있는 복원 스크립트 (.ai-bouncer-tasks/ 경로를 TEST_DIR 기준으로 실행)
run_restore_script() {
  local workdir="$1"
  (cd "$workdir" && python3 -c "
import json, os, glob

results = {'active': None, 'incomplete': []}

# 1) .active 파일 스캔
for state_file in sorted(glob.glob('.ai-bouncer-tasks/*/*/state.json'), reverse=True):
    task_dir = os.path.dirname(state_file)
    active_file = os.path.join(task_dir, '.active')
    if os.path.isfile(active_file):
        results['active'] = {'task_dir': task_dir, 'state_file': state_file}
        break

# 2) .active 없으면 미완료 작업 스캔
if not results['active']:
    for state_file in sorted(glob.glob('.ai-bouncer-tasks/*/*/state.json'), reverse=True):
        try:
            state = json.load(open(state_file))
        except: continue
        phase = state.get('workflow_phase', '')
        if phase in ('done', ''): continue
        task_dir = os.path.dirname(state_file)
        task_name = os.path.basename(task_dir)
        date_dir = os.path.basename(os.path.dirname(task_dir))
        mode = state.get('mode', '?')
        dev_phase = state.get('current_dev_phase', 0)
        total_phases = len(state.get('dev_phases', {}))
        results['incomplete'].append({
            'label': f'{date_dir}/{task_name}',
            'phase': phase, 'mode': mode,
            'dev_phase': dev_phase, 'total_phases': total_phases,
            'task_dir': task_dir
        })

print(json.dumps(results, ensure_ascii=False))
")
}

write_state() {
  local dir="$1"
  local content="$2"
  mkdir -p "$dir"
  echo "$content" > "$dir/state.json"
}

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  ai-bouncer E2E Session Restore Tests${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

# ─── 1. .ai-bouncer-tasks/ 없음 (빈 프로젝트) → active=null, incomplete=[] ───
echo -e "${BOLD}─── 1. 빈 프로젝트 ───${NC}"

WORK1="$TEST_DIR/case1"
mkdir -p "$WORK1"
R=$(run_restore_script "$WORK1")
ACTIVE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['active'])")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")
if [ "$ACTIVE" = "None" ] && [ "$INCOMPLETE" = "0" ]; then
  pass "빈 프로젝트 → Case C (active=null, incomplete=0)"
else
  fail "빈 프로젝트 → expected null/0, got active=$ACTIVE incomplete=$INCOMPLETE"
fi

# ─── 2. .active 파일 있음 → Case A ───
echo -e "\n${BOLD}─── 2. .active 있음 → Case A ───${NC}"

WORK2="$TEST_DIR/case2"
mkdir -p "$WORK2"
write_state "$WORK2/.ai-bouncer-tasks/2026-03-12/my-task" '{"workflow_phase":"development","mode":"normal","current_dev_phase":2,"dev_phases":{"1":{},"2":{}}}'
touch "$WORK2/.ai-bouncer-tasks/2026-03-12/my-task/.active"

R=$(run_restore_script "$WORK2")
ACTIVE=$(echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['active']['task_dir'] if d['active'] else 'None')")
if echo "$ACTIVE" | grep -q "my-task"; then
  pass ".active 있음 → active 감지됨 ($ACTIVE)"
else
  fail ".active 있음 → active 미감지 ($ACTIVE)"
fi

# incomplete은 비어야 함 (active가 있으므로 스캔 안 함)
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")
if [ "$INCOMPLETE" = "0" ]; then
  pass ".active 있으면 incomplete 스캔 스킵"
else
  fail ".active 있는데 incomplete 스캔됨 ($INCOMPLETE개)"
fi

# ─── 3. .active 없음 + 미완료 작업 1개 → Case B ───
echo -e "\n${BOLD}─── 3. .active 없음 + 미완료 1개 → Case B ───${NC}"

WORK3="$TEST_DIR/case3"
mkdir -p "$WORK3"
write_state "$WORK3/.ai-bouncer-tasks/2026-03-12/reskin-task" '{"workflow_phase":"development","mode":"normal","current_dev_phase":2,"dev_phases":{"1":{},"2":{},"3":{}}}'
# .active 없음!

R=$(run_restore_script "$WORK3")
ACTIVE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['active'])")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$ACTIVE" = "None" ] && [ "$INCOMPLETE" = "1" ]; then
  pass "미완료 1개 감지됨"
else
  fail "expected active=None/incomplete=1, got $ACTIVE/$INCOMPLETE"
fi

# 상세 정보 확인
LABEL=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['label'])")
PHASE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['phase'])")
MODE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['mode'])")
DEV_PHASE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['dev_phase'])")
TOTAL=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['total_phases'])")

if [ "$LABEL" = "2026-03-12/reskin-task" ]; then pass "label 정확"; else fail "label 불일치: $LABEL"; fi
if [ "$PHASE" = "development" ]; then pass "phase 정확"; else fail "phase 불일치: $PHASE"; fi
if [ "$MODE" = "normal" ]; then pass "mode 정확"; else fail "mode 불일치: $MODE"; fi
if [ "$DEV_PHASE" = "2" ]; then pass "dev_phase 정확"; else fail "dev_phase 불일치: $DEV_PHASE"; fi
if [ "$TOTAL" = "3" ]; then pass "total_phases 정확"; else fail "total_phases 불일치: $TOTAL"; fi

# ─── 4. 완료된 작업만 → Case C ───
echo -e "\n${BOLD}─── 4. 완료 작업만 → Case C ───${NC}"

WORK4="$TEST_DIR/case4"
mkdir -p "$WORK4"
write_state "$WORK4/.ai-bouncer-tasks/2026-03-10/done-task" '{"workflow_phase":"done","mode":"simple"}'
write_state "$WORK4/.ai-bouncer-tasks/2026-03-11/done-task2" '{"workflow_phase":"done","mode":"normal","current_dev_phase":3,"dev_phases":{"1":{},"2":{},"3":{}}}'

R=$(run_restore_script "$WORK4")
ACTIVE=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['active'])")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$ACTIVE" = "None" ] && [ "$INCOMPLETE" = "0" ]; then
  pass "완료 작업만 → Case C (새 작업 시작)"
else
  fail "완료 작업 필터링 실패: active=$ACTIVE incomplete=$INCOMPLETE"
fi

# ─── 5. 미완료 여러 개 → 최신 날짜 순 정렬 ───
echo -e "\n${BOLD}─── 5. 미완료 여러 개 + 정렬 ───${NC}"

WORK5="$TEST_DIR/case5"
mkdir -p "$WORK5"
write_state "$WORK5/.ai-bouncer-tasks/2026-03-10/old-task" '{"workflow_phase":"planning","mode":"normal","current_dev_phase":0,"dev_phases":{}}'
write_state "$WORK5/.ai-bouncer-tasks/2026-03-12/new-task" '{"workflow_phase":"development","mode":"normal","current_dev_phase":1,"dev_phases":{"1":{}}}'
write_state "$WORK5/.ai-bouncer-tasks/2026-03-11/mid-task" '{"workflow_phase":"verification","mode":"simple","current_dev_phase":0,"dev_phases":{}}'
write_state "$WORK5/.ai-bouncer-tasks/2026-03-11/done-task" '{"workflow_phase":"done","mode":"simple"}'

R=$(run_restore_script "$WORK5")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$INCOMPLETE" = "3" ]; then
  pass "미완료 3개 감지 (done 제외)"
else
  fail "미완료 개수 불일치: expected 3, got $INCOMPLETE"
fi

# 첫 번째가 최신 날짜 (2026-03-12)
FIRST=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['incomplete'][0]['label'])")
if echo "$FIRST" | grep -q "2026-03-12"; then
  pass "최신 날짜 우선 정렬 ($FIRST)"
else
  fail "정렬 순서 틀림: $FIRST"
fi

# done 필터링
LABELS=$(echo "$R" | python3 -c "import json,sys; print([t['label'] for t in json.load(sys.stdin)['incomplete']])")
if ! echo "$LABELS" | grep -q "done-task"; then
  pass "done 작업 필터링됨"
else
  fail "done 작업이 목록에 포함됨: $LABELS"
fi

# ─── 6. .active + 미완료 혼재 → .active 우선 ───
echo -e "\n${BOLD}─── 6. .active + 미완료 혼재 → .active 우선 ───${NC}"

WORK6="$TEST_DIR/case6"
mkdir -p "$WORK6"
write_state "$WORK6/.ai-bouncer-tasks/2026-03-12/active-task" '{"workflow_phase":"development","mode":"normal","current_dev_phase":1,"dev_phases":{"1":{}}}'
touch "$WORK6/.ai-bouncer-tasks/2026-03-12/active-task/.active"
write_state "$WORK6/.ai-bouncer-tasks/2026-03-10/orphan-task" '{"workflow_phase":"development","mode":"simple","current_dev_phase":0,"dev_phases":{}}'

R=$(run_restore_script "$WORK6")
ACTIVE=$(echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['active']['task_dir'] if d['active'] else 'None')")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if echo "$ACTIVE" | grep -q "active-task" && [ "$INCOMPLETE" = "0" ]; then
  pass ".active 우선 + incomplete 스캔 스킵"
else
  fail ".active 우선 실패: active=$ACTIVE incomplete=$INCOMPLETE"
fi

# ─── 7. 깨진 state.json → 스킵 ───
echo -e "\n${BOLD}─── 7. 깨진 state.json → 스킵 ───${NC}"

WORK7="$TEST_DIR/case7"
mkdir -p "$WORK7/.ai-bouncer-tasks/2026-03-12/broken-task"
echo "NOT_JSON{{{" > "$WORK7/.ai-bouncer-tasks/2026-03-12/broken-task/state.json"
write_state "$WORK7/.ai-bouncer-tasks/2026-03-12/good-task" '{"workflow_phase":"development","mode":"simple","current_dev_phase":0,"dev_phases":{}}'

R=$(run_restore_script "$WORK7")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$INCOMPLETE" = "1" ]; then
  pass "깨진 state.json 스킵, 정상 1개만 감지"
else
  fail "깨진 state.json 처리 실패: incomplete=$INCOMPLETE"
fi

# ─── 8. workflow_phase 빈 문자열 → 제외 ───
echo -e "\n${BOLD}─── 8. workflow_phase 빈 문자열 → 제외 ───${NC}"

WORK8="$TEST_DIR/case8"
mkdir -p "$WORK8"
write_state "$WORK8/.ai-bouncer-tasks/2026-03-12/empty-phase" '{"workflow_phase":"","mode":"simple"}'
write_state "$WORK8/.ai-bouncer-tasks/2026-03-12/good-task" '{"workflow_phase":"planning","mode":"normal","current_dev_phase":0,"dev_phases":{}}'

R=$(run_restore_script "$WORK8")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$INCOMPLETE" = "1" ]; then
  pass "빈 workflow_phase 제외됨"
else
  fail "빈 workflow_phase 처리 실패: incomplete=$INCOMPLETE"
fi

# ─── 9. workflow_phase 없는 state.json → 제외 ───
echo -e "\n${BOLD}─── 9. workflow_phase 키 없음 → 제외 ───${NC}"

WORK9="$TEST_DIR/case9"
mkdir -p "$WORK9"
write_state "$WORK9/.ai-bouncer-tasks/2026-03-12/no-phase" '{"mode":"simple"}'

R=$(run_restore_script "$WORK9")
INCOMPLETE=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['incomplete']))")

if [ "$INCOMPLETE" = "0" ]; then
  pass "workflow_phase 키 없음 → 제외됨"
else
  fail "workflow_phase 없는 항목 포함됨: incomplete=$INCOMPLETE"
fi

# ─── 결과 ───
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  결과: ${GREEN}✅ $PASS 통과${NC} / ${RED}❌ $FAIL 실패${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"

exit $FAIL
