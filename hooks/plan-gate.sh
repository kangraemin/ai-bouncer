#!/bin/bash
# plan-gate: PreToolUse hook
# Write/Edit 시도 전 아티팩트 기반 검증 — state.json 플래그만으로 우회 불가

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Write/Edit/MultiEdit 계열만 체크
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# 세션 격리: session_id 추출
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# --- ai-bouncer start ---

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# CHECK 0: ~/.claude/plans/ 경로 → 즉시 ALLOW (Claude Code 내부 plan 파일)
if [[ "$FILE_PATH" == "$HOME/.claude/plans/"* ]] || [[ "$FILE_PATH" == *"/.claude/plans/"* ]]; then
  exit 0
fi

# CHECK 1: plan.md는 항상 허용 (계획 작성 중 필요)
# phase-*.md / step-*.md는 planning 단계에서 차단 (CHECK 2에서 처리)
if [[ "$FILE_PATH" == */plan.md ]]; then
  exit 0
fi

# 4.5. PRE-CHECK 제거됨
# SPAWNED_COUNT(/tmp/ 파일 기반) 검증이 fragile하여 정상 Dev 에이전트도 차단하는 버그 수정.
# Lead 제거에 따라 이 검증은 불필요.

# resolve_task_dir: 공유 라이브러리 사용
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"

# .active 없거나 비어있으면 → 통과
if [ -z "$TASK_NAME" ]; then
  exit 0
fi

# state.json 없으면 통과
[ -f "$STATE_FILE" ] || exit 0

# CHECK 1.6: planning 단계 state.json forward-skip 차단
if [[ "$FILE_PATH" == */state.json ]]; then
  _CURRENT_PHASE=$(jq -r '.workflow_phase // ""' "$STATE_FILE" 2>/dev/null)
  _PLAN_APPROVED_16=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)
  if [ "$_CURRENT_PHASE" = "planning" ] || [ "$_PLAN_APPROVED_16" != "true" ]; then
    _NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
    _NEW_PHASE=$(echo "$_NEW_CONTENT" | python3 -c "
import json, sys, re
txt = sys.stdin.read()
try:
    d = json.loads(txt)
    print(d.get('workflow_phase', ''))
except:
    m = re.search(r'\"workflow_phase\"\s*:\s*\"([^\"]+)\"', txt)
    print(m.group(1) if m else '')
" 2>/dev/null)
    case "$_NEW_PHASE" in
      development|done|verification)
        jq -n --arg nxt "$_NEW_PHASE" '{
          decision: "block",
          reason: ("⛔ plan_approved 없이 state.json을 " + $nxt + "으로 변경할 수 없습니다. 계획을 수립하고 승인을 받으세요. 작업 취소 시 workflow_phase=cancelled 사용.")
        }'
        exit 0 ;;
    esac
  fi
  # CHECK 1.6b: current_step이 해당 Phase의 step 수를 초과하면 차단 (순환 차단 방지)
  _NEW_CONTENT_16B=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
  _STEP_CHECK=$(echo "$_NEW_CONTENT_16B" | python3 -c "
import json, sys
txt = sys.stdin.read()
try:
    d = json.loads(txt)
    phase = str(d.get('current_dev_phase', 0))
    step = int(d.get('current_step', 0))
    steps = d.get('dev_phases', {}).get(phase, {}).get('steps', {})
    max_step = len(steps) if steps else 0
    if step > 0 and max_step > 0 and step > max_step:
        print(f'OVERFLOW:{step}:{max_step}:{phase}')
    else:
        print('OK')
except:
    print('OK')
" 2>/dev/null)
  if [[ "$_STEP_CHECK" == OVERFLOW:* ]]; then
    _S=$(echo "$_STEP_CHECK" | cut -d: -f2)
    _MAX=$(echo "$_STEP_CHECK" | cut -d: -f3)
    _PH=$(echo "$_STEP_CHECK" | cut -d: -f4)
    jq -n --arg s "$_S" --arg max "$_MAX" --arg ph "$_PH" '{
      decision: "block",
      reason: ("⛔ state.json current_step=" + $s + "은 Phase " + $ph + "의 최대 step 수(" + $max + ")를 초과합니다. Phase 완료 시 current_dev_phase++, current_step=1로 설정하세요.")
    }'
    exit 0
  fi
fi

# state.json 값 읽기
WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)
MODE=$(jq -r '.mode // "normal"' "$STATE_FILE" 2>/dev/null)
TEAM_NAME=$(jq -r '.team_name // ""' "$STATE_FILE" 2>/dev/null)
CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE:-0}; CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE//[^0-9]/}; CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE:-0}
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=${CURRENT_STEP:-0}; CURRENT_STEP=${CURRENT_STEP//[^0-9]/}; CURRENT_STEP=${CURRENT_STEP:-0}

# CHECK 1.5: workflow_phase 화이트리스트
case "$WORKFLOW_PHASE" in
  planning|development|verification) ;;
  done|cancelled) exit 0 ;;  # 완료/취소 상태 — gate 비활성
  *)
    jq -n '{decision:"block", reason:"⛔ workflow_phase가 허용되지 않는 값입니다."}'
    exit 0 ;;
esac

# CHECK 2: planning 단계 → 프로젝트 소스 파일 차단, .ai-bouncer-tasks/ + 외부 경로 허용
if [ "$WORKFLOW_PHASE" = "planning" ]; then
  if [[ "$FILE_PATH" == */phase-*.md ]] || [[ "$FILE_PATH" == */step-*.md ]]; then
    jq -n '{
      decision: "block",
      reason: "⛔ planning 단계에서 phase/step 파일을 작성할 수 없습니다. 계획을 먼저 승인받으세요 (/dev-bounce Phase 1)."
    }'
    exit 0
  fi
  # 프로젝트 소스 파일 차단: REPO_ROOT 안이고 .ai-bouncer-tasks/ 밖이면 차단
  # /tmp/ 등 외부 경로와 .ai-bouncer-tasks/ 하위 task 파일(state.json, .active 등)은 허용
  _PG_REPO=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$_PG_REPO" ]; then
    # macOS symlink 정규화 (예: /var/folders → /private/var/folders)
    _PG_FILE_REAL=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    if [[ "$_PG_FILE_REAL" == "$_PG_REPO"* ]] && \
       [[ "$_PG_FILE_REAL" != "$_PG_REPO/.ai-bouncer-tasks/"* ]]; then
      jq -n '{
        decision: "block",
        reason: "⛔ planning 단계에서 프로젝트 소스 파일을 수정할 수 없습니다. 계획을 승인받은 후 개발을 시작하세요."
      }'
      exit 0
    fi
  fi
  exit 0
fi

# .ai-bouncer-tasks/ 하위 파일은 태스크 관리 파일 → plan_approved 무관 허용
if [[ "$FILE_PATH" == */.ai-bouncer-tasks/* ]] || [[ "$FILE_PATH" == .ai-bouncer-tasks/* ]]; then
  exit 0
fi

# CHECK 3: plan_approved 체크 + plan.md 파일 실존 이중 체크
if [ "$PLAN_APPROVED" != "true" ]; then
  jq -n '{
    decision: "block",
    reason: "계획이 승인되지 않았습니다. /dev-bounce로 계획을 수립하고 승인 후 개발을 시작하세요."
  }'
  exit 0
fi

if [ ! -f "${TASK_DIR}/plan.md" ]; then
  jq -n '{
    decision: "block",
    reason: "plan.md 파일이 존재하지 않습니다. 계획 문서가 실제로 작성되어야 합니다."
  }'
  exit 0
fi

# SIMPLE 모드: plan_approved + plan.md 존재만으로 통과
if [ "$MODE" = "simple" ]; then
  exit 0
fi

# --- 이하 NORMAL 모드 전용 ---

# agent_mode 읽기 (config.json에서)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
AGENT_MODE=$(jq -r '.agent_mode // "team"' "$BOUNCER_CONFIG" 2>/dev/null || echo "team")

# agent_mode별 검증 분기
case "$AGENT_MODE" in
  team)
    # CHECK 4: development + team_name 비어있음 → BLOCK
    if [ "$WORKFLOW_PHASE" = "development" ] && [ -z "$TEAM_NAME" ]; then
      jq -n '{
        decision: "block",
        reason: "⛔ [team] 팀이 구성되지 않았습니다. TeamCreate로 팀을 먼저 생성하세요."
      }'
      exit 0
    fi

    # CHECK 5: development + team config.json 미존재 → BLOCK
    if [ "$WORKFLOW_PHASE" = "development" ]; then
      TEAM_CONFIG="$HOME/.claude/teams/${TEAM_NAME}/config.json"
      if [ ! -f "$TEAM_CONFIG" ]; then
        jq -n '{
          decision: "block",
          reason: "⛔ [team] 팀 디렉토리가 존재하지 않습니다. TeamCreate로 팀을 먼저 생성하세요."
        }'
        exit 0
      fi

      # CHECK 6: team members < 1 → BLOCK
      MEMBER_COUNT=$(jq -r '.members | length' "$TEAM_CONFIG" 2>/dev/null)
      MEMBER_COUNT=${MEMBER_COUNT:-0}; MEMBER_COUNT=${MEMBER_COUNT//[^0-9]/}; MEMBER_COUNT=${MEMBER_COUNT:-0}
      if [ "$MEMBER_COUNT" -lt 1 ]; then
        jq -n '{
          decision: "block",
          reason: "⛔ [team] 팀 멤버가 없습니다. Dev/QA를 스폰하세요."
        }'
        exit 0
      fi

      # CHECK 6-DEV: Lead만 있고 Dev/QA 없으면 소스 파일 쓰기 차단
      NON_LEAD_COUNT=$(jq -r '[.members[] | select(.name | ascii_downcase | test("lead") | not)] | length' "$TEAM_CONFIG" 2>/dev/null)
      NON_LEAD_COUNT=${NON_LEAD_COUNT:-0}; NON_LEAD_COUNT=${NON_LEAD_COUNT//[^0-9]/}; NON_LEAD_COUNT=${NON_LEAD_COUNT:-0}
      if [ "$NON_LEAD_COUNT" -lt 1 ]; then
        _PG_REPO6=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$_PG_REPO6" ]; then
          _PG_FILE6=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
          if [[ "$_PG_FILE6" == "$_PG_REPO6"* ]] && [[ "$_PG_FILE6" != "$_PG_REPO6/.ai-bouncer-tasks/"* ]]; then
            jq -n '{
              decision: "block",
              reason: "⛔ [team] Dev/QA 에이전트가 없습니다. Main Claude가 Dev/QA를 스폰하세요."
            }'
            exit 0
          fi
        fi
      fi
    fi
    ;;
  subagent)
    # subagent: team 구성 불필요, 위임 등록 검증은 resolve-task.sh fallback이 처리
    ;;
  single)
    # single: Main Claude가 직접 수행, 팀/에이전트 검증 불필요
    ;;
esac

# CHECK 6.5: development + step=0 방어
if [ "$WORKFLOW_PHASE" = "development" ]; then
  if [ "$CURRENT_DEV_PHASE" -le 0 ] || [ "$CURRENT_STEP" -le 0 ]; then
    jq -n '{decision:"block", reason:"⛔ development이지만 dev_phase/step 미설정"}'
    exit 0
  fi
fi

# CHECK 6.7: dev_phases 비어있는지 검증
if [ "$WORKFLOW_PHASE" = "development" ] && [ "$MODE" = "normal" ]; then
  DEV_PHASES_COUNT=$(jq '.dev_phases | length' "$STATE_FILE" 2>/dev/null)
  DEV_PHASES_COUNT=${DEV_PHASES_COUNT:-0}; DEV_PHASES_COUNT=${DEV_PHASES_COUNT//[^0-9]/}; DEV_PHASES_COUNT=${DEV_PHASES_COUNT:-0}
  if [ "$DEV_PHASES_COUNT" -le 0 ]; then
    jq -n '{decision:"block", reason:"⛔ dev_phases가 비어있습니다. Main Claude가 phase 구조를 먼저 정의해야 합니다."}'
    exit 0
  fi
fi

# CHECK 6.8: verification인데 모든 Phase가 완료되지 않았으면 → BLOCK
if [ "$WORKFLOW_PHASE" = "verification" ] && [ "$MODE" = "normal" ]; then
  DEV_PHASES_COUNT=$(jq '.dev_phases | length' "$STATE_FILE" 2>/dev/null)
  DEV_PHASES_COUNT=${DEV_PHASES_COUNT:-0}
  if [ "$DEV_PHASES_COUNT" -gt 0 ]; then
    ALL_PHASES_DONE=true
    for phase_idx in $(seq 1 "$DEV_PHASES_COUNT"); do
      PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$phase_idx")
      PHASE_DIR="${TASK_DIR}/${PHASE_FOLDER}"
      # phase 디렉토리에 step-*.md가 있고, 모두 ✅를 포함해야 함
      HAS_STEPS=false
      for step_file in "$PHASE_DIR"/step-*.md; do
        [ -f "$step_file" ] || continue
        HAS_STEPS=true
        if ! grep -q '✅' "$step_file" 2>/dev/null; then
          ALL_PHASES_DONE=false
          break 2
        fi
      done
      if [ "$HAS_STEPS" = false ]; then
        ALL_PHASES_DONE=false
        break
      fi
    done
    if [ "$ALL_PHASES_DONE" = false ]; then
      jq -n --arg count "$DEV_PHASES_COUNT" '{
        decision: "block",
        reason: ("⛔ verification 단계이지만 모든 개발 Phase가 완료되지 않았습니다. 미완료 Phase의 개발을 먼저 완료하세요. (총 " + $count + "개 Phase)")
      }'
      exit 0
    fi
  fi
fi

# CHECK 7: current_dev_phase > 0 AND current_step > 0
if [ "$CURRENT_DEV_PHASE" -gt 0 ] && [ "$CURRENT_STEP" -gt 0 ]; then
  DEV_PHASE_KEY="$CURRENT_DEV_PHASE"
  STEP_KEY="$CURRENT_STEP"

  # phase_folder 조회
  PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$DEV_PHASE_KEY")

  PHASE_DIR="${TASK_DIR}/${PHASE_FOLDER}"

  # state.json 수정은 phase/step 아티팩트 검증 전체를 스킵 (deadlock 방지)
  if [[ "$FILE_PATH" == */state.json ]]; then
    : # CHECK 7a~7e 스킵, 아래 fi에서 블록 탈출
  else

  # CHECK 7-PHASE: 이전 Phase 완료 검증 (current_dev_phase > 1일 때)
  PREV_DEV_PHASE=$((CURRENT_DEV_PHASE - 1))
  if [ "$PREV_DEV_PHASE" -gt 0 ]; then
    PREV_PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$PREV_DEV_PHASE")
    PREV_PHASE_DIR="${TASK_DIR}/${PREV_PHASE_FOLDER}"
    # 이전 Phase의 모든 step.md에 ✅가 있어야 함
    PREV_PHASE_INCOMPLETE=false
    for prev_step_file in "$PREV_PHASE_DIR"/step-*.md; do
      [ -f "$prev_step_file" ] || continue
      if ! grep -q '✅' "$prev_step_file" 2>/dev/null; then
        PREV_PHASE_INCOMPLETE=true
        break
      fi
    done
    if [ "$PREV_PHASE_INCOMPLETE" = true ]; then
      jq -n --arg phase "$PREV_DEV_PHASE" '{
        decision: "block",
        reason: ("⛔ Phase " + $phase + "의 모든 Step이 완료되지 않았습니다. 이전 Phase를 먼저 완료하세요.")
      }'
      exit 0
    fi
  fi

  # CHECK 7a: phase.md 존재 검증 (phase.md 자체를 쓰는 경우는 부트스트랩 허용)
  _IS_PHASE_BOOTSTRAP=false
  if [ ! -f "${PHASE_DIR}/phase.md" ]; then
    _PG_FILE_ABS=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    _PHASE_MD_ABS=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${PHASE_DIR}/phase.md" 2>/dev/null || echo "${PHASE_DIR}/phase.md")
    if [ "$_PG_FILE_ABS" != "$_PHASE_MD_ABS" ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + "의 phase.md가 존재하지 않습니다. Main Claude가 phase.md를 먼저 생성해야 합니다.")
      }'
      exit 0
    fi
    _IS_PHASE_BOOTSTRAP=true
  fi

  # CHECK 7a-2: phase.md 필수 섹션 검증 (부트스트랩 시 스킵 — 아직 파일이 없음)
  if [ "$_IS_PHASE_BOOTSTRAP" = false ]; then
    for section in "## 목표" "## 범위" "## Steps"; do
      if ! LC_ALL=en_US.UTF-8 grep -q "$section" "${PHASE_DIR}/phase.md" 2>/dev/null; then
        jq -n --arg phase "$DEV_PHASE_KEY" --arg s "$section" '{
          decision: "block",
          reason: ("Dev Phase " + $phase + "의 phase.md에 필수 섹션 누락: " + $s)
        }'
        exit 0
      fi
    done
  fi

  # 이전 step 검증 (M > 1일 때)
  PREV_STEP=$((CURRENT_STEP - 1))
  if [ "$PREV_STEP" -gt 0 ]; then
    PREV_STEP_FILE="${PHASE_DIR}/step-${PREV_STEP}.md"

    # CHECK 7b: 이전 step 파일 미존재 → BLOCK
    if [ ! -f "$PREV_STEP_FILE" ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + " 문서가 존재하지 않습니다.")
      }'
      exit 0
    fi

    # CHECK 7c: 이전 step에 ✅ 미포함 → BLOCK
    if ! grep -q '✅' "$PREV_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + " 테스트가 통과되지 않았습니다 (✅ 없음). 테스트를 먼저 통과시킨 후 진행하세요.")
      }'
      exit 0
    fi

    # CHECK 7c-2: 이전 step의 TC 실행출력 — 섹션 존재 + 실제 내용 확인
    if ! LC_ALL=en_US.UTF-8 grep -qE '(실행출력|실행 결과|출력:|Output:)' "$PREV_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + "의 TC에 실행출력이 없습니다. 테스트 실행 결과를 반드시 기록하세요.")
      }'
      exit 0
    fi
    # CHECK 7c-3: 실행출력 섹션 이후 실제 내용 확인 (빈 섹션 방지)
    _EXEC_LINES=$(python3 -c "
import re, sys
try:
    content = open(sys.argv[1], errors='replace').read()
    m = re.search(r'^## (실행출력|실행 결과)', content, re.MULTILINE)
    if not m:
        print(0); sys.exit()
    rest = content[m.end():]
    nxt = re.search(r'^##', rest, re.MULTILINE)
    sec = rest[:nxt.start()] if nxt else rest
    non_empty = [l for l in sec.split('\n') if l.strip() and not l.strip().startswith('(QA가')]
    print(len(non_empty))
except:
    print(0)
" "$PREV_STEP_FILE" 2>/dev/null || echo 0)
    if [ "$_EXEC_LINES" -lt 2 ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + "의 실행출력이 비어있습니다. 실제 명령어 실행 결과를 붙여넣으세요.")
      }'
      exit 0
    fi
  fi

  # 현재 step 검증
  CURRENT_STEP_FILE="${PHASE_DIR}/step-${STEP_KEY}.md"

  # CHECK 7d: 현재 step 파일 미존재 → BLOCK (step.md 자체를 쓰는 경우 부트스트랩 허용)
  if [ ! -f "$CURRENT_STEP_FILE" ]; then
    _PG_FILE_ABS7d=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
    _STEP_MD_ABS=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$CURRENT_STEP_FILE" 2>/dev/null || echo "$CURRENT_STEP_FILE")
    if [ "$_PG_FILE_ABS7d" != "$_STEP_MD_ABS" ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + " 의 step.md가 존재하지 않습니다. Main Claude가 step.md를 먼저 생성해야 합니다.")
      }'
      exit 0
    fi
  fi

  # CHECK 7e: 현재 step에 TC 행 내용 없음 → BLOCK (step.md 자체를 쓰는 경우 부트스트랩 허용)
  _PG_FILE_ABS7e=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
  _STEP_MD_ABS7e=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$CURRENT_STEP_FILE" 2>/dev/null || echo "$CURRENT_STEP_FILE")
  if [ "$_PG_FILE_ABS7e" = "$_STEP_MD_ABS7e" ]; then
    : # step.md 자체를 생성 중 — TC 검증 스킵 (부트스트랩)
  elif ! grep -E '^\| *TC-[0-9]+ *\| *[^ |]' "$CURRENT_STEP_FILE" >/dev/null 2>&1; then
    jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
      decision: "block",
      reason: ("Dev Phase " + $phase + " Step " + $step + " 의 테스트 기준이 정의되지 않았습니다. QA가 TC를 먼저 작성해야 합니다.")
    }'
    exit 0
  fi

  # CHECK 7e-2/7e-3: step.md 자체를 생성 중이면 스킵 (부트스트랩)
  if [ "$_PG_FILE_ABS7e" != "$_STEP_MD_ABS7e" ]; then
    # CHECK 7e-2: TC 내용 충실도 검증 (시나리오/기대결과 5자 미만 방지)
    _TC_SHALLOW=$(grep -E '^\| *TC-[0-9]+' "$CURRENT_STEP_FILE" 2>/dev/null | python3 -c "
import sys
shallow = 0
for line in sys.stdin:
    cols = [c.strip() for c in line.strip().strip('|').split('|')]
    if len(cols) >= 3:
        scenario = cols[1].strip()
        expected = cols[2].strip()
        if len(scenario) < 5 or len(expected) < 5:
            shallow += 1
print(shallow)
" 2>/dev/null || echo 0)
    if [ "$_TC_SHALLOW" -gt 0 ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" --arg n "$_TC_SHALLOW" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + ": TC " + $n + "개의 시나리오/기대결과가 너무 짧습니다 (5자 미만). 구체적으로 작성하세요.")
      }'
      exit 0
    fi

    # CHECK 7e-3: 검증 명령어(backtick) 존재 확인
    if ! LC_ALL=en_US.UTF-8 grep -q '`' "$CURRENT_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + "에 검증 명령어(backtick)가 없습니다. 실행 가능한 명령어를 포함하세요.")
      }'
      exit 0
    fi
  fi
  fi # state.json 스킵 블록 끝
fi

# --- ai-bouncer end ---

exit 0
