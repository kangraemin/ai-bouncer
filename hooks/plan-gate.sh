#!/bin/bash
# plan-gate: PreToolUse hook
# Write/Edit 시도 전 아티팩트 기반 검증 — state.json 플래그만으로 우회 불가

HOOK_NAME="plan-gate"
source "$(dirname "${BASH_SOURCE[0]}")/lib/block-logger.sh"

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

# .active 없거나 내 세션이 아니면 → 통과
if [ "$IS_MY_TASK" != "true" ]; then
  exit 0
fi

# 승인된 sub-agent → gate 스킵 (단, team 모드 + development + team_name="" 이면 차단)
if [ "${IS_DELEGATED_AGENT:-false}" = "true" ]; then
  if [ -f "$STATE_FILE" ]; then
    _IDA_PHASE=$(jq -r '.workflow_phase // ""' "$STATE_FILE" 2>/dev/null)
    if [ "$_IDA_PHASE" = "development" ]; then
      _IDA_CFG="${BOUNCER_CONFIG:-}"
      if [ -z "$_IDA_CFG" ] || [ ! -f "$_IDA_CFG" ]; then
        _IDA_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
        _IDA_CFG="${_IDA_ROOT}/.claude/ai-bouncer/config.json"
        [ -f "$_IDA_CFG" ] || _IDA_CFG="${HOME}/.claude/ai-bouncer/config.json"
      fi
      _IDA_MODE=$(jq -r '.agent_mode // "team"' "$_IDA_CFG" 2>/dev/null || echo "team")
      if [ "$_IDA_MODE" = "team" ]; then
        _IDA_DP=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
        _IDA_DP=${_IDA_DP//[^0-9]/}; _IDA_DP=${_IDA_DP:-0}
        _IDA_TN=""
        if [ "$_IDA_DP" -gt 0 ]; then
          _IDA_TN=$(jq -r --argjson ph "$_IDA_DP" '.dev_phases[($ph|tostring)].team_name // ""' "$STATE_FILE" 2>/dev/null)
        fi
        # per-phase 미설정/빈값이면 top-level team_name 폴백
        [ -z "$_IDA_TN" ] && _IDA_TN=$(jq -r '.team_name // ""' "$STATE_FILE" 2>/dev/null)
        if [ -z "$_IDA_TN" ]; then
          log_block "PG-DELEGATED-NO-TEAM" "⛔ [delegated][team] development 페이즈에서 team_name 없음."
          jq -n --arg r "⛔ [delegated][team] development 페이즈에서 team_name이 없습니다. TeamCreate를 먼저 실행하세요." \
             '{decision:"block", reason:$r}'
          exit 0
        fi
      fi
    fi
  fi
  exit 0
fi

# state.json 없으면 통과
[ -f "$STATE_FILE" ] || exit 0

# CHECK 1.6: planning 단계 state.json forward-skip 차단
if [[ "$FILE_PATH" == */state.json ]]; then
  _CURRENT_PHASE=$(jq -r '.workflow_phase // ""' "$FILE_PATH" 2>/dev/null)
  _PLAN_APPROVED_16=$(jq -r '.plan_approved // false' "$FILE_PATH" 2>/dev/null)
  if [ "$_PLAN_APPROVED_16" != "true" ]; then
    _NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
    # 새 내용에 plan_approved=true가 동시에 포함된 경우 원자적 전환 허용
    _NEW_PA=$(echo "$_NEW_CONTENT" | python3 -c "
import json, sys, re
txt = sys.stdin.read()
try:
    d = json.loads(txt)
    print('true' if d.get('plan_approved') is True else 'false')
except:
    m = re.search(r'\"plan_approved\"\s*:\s*(true|false)', txt)
    print(m.group(1) if m else 'false')
" 2>/dev/null)
    if [ "$_NEW_PA" != "true" ]; then
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
          log_block "PG-NO-APPROVAL-PHASE-CHANGE" "⛔ plan_approved 없이 state.json 전환 금지."
          jq -n --arg nxt "$_NEW_PHASE" '{
            decision: "block",
            reason: ("⛔ plan_approved 없이 state.json을 " + $nxt + "으로 변경할 수 없습니다. 계획을 수립하고 승인을 받으세요.")
          }'
          exit 0 ;;
      esac
    fi
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
    log_block "PG-STEP-OVERFLOW" "⛔ state.json current_step이 Phase 최대 step 수 초과."
    jq -n --arg s "$_S" --arg max "$_MAX" --arg ph "$_PH" '{
      decision: "block",
      reason: ("⛔ state.json current_step=" + $s + "은 Phase " + $ph + "의 최대 step 수(" + $max + ")를 초과합니다. Phase 완료 시 current_dev_phase++, current_step=1로 설정하세요.")
    }'
    exit 0
  fi

  # CHECK 1.6c: verification/done 전환 시 모든 step-*.md ✅ 완료 확인
  # CHECK 1.6d: done 전환 시 추가로 e2e-result.md 확인
  if [ "$_PLAN_APPROVED_16" = "true" ]; then
    _NEW_CONTENT_16C=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
    _NEW_PHASE_16C=$(echo "$_NEW_CONTENT_16C" | python3 -c "
import json, sys, re
txt = sys.stdin.read()
try:
    d = json.loads(txt)
    print(d.get('workflow_phase', ''))
except:
    m = re.search(r'\"workflow_phase\"\s*:\s*\"([^\"]+)\"', txt)
    print(m.group(1) if m else '')
" 2>/dev/null)
    if [[ "$_NEW_PHASE_16C" = "verification" || "$_NEW_PHASE_16C" = "done" ]]; then
      _ALL_STEPS_16=true
      _DPC_16=$(jq '.dev_phases | length' "${STATE_FILE}" 2>/dev/null)
      _DPC_16=${_DPC_16:-0}
      if [ "$_DPC_16" -gt 0 ]; then
        for _pidx_16 in $(seq 1 "$_DPC_16"); do
          _pf_16=$(_get_phase_folder "${STATE_FILE}" "$_pidx_16")
          _pd_16="${TASK_DIR}/${_pf_16}"
          _hs_16=false
          for _sf_16 in "$_pd_16"/step-*.md; do
            [ -f "$_sf_16" ] || continue
            _hs_16=true
            if ! grep -q '✅' "$_sf_16" 2>/dev/null; then
              _ALL_STEPS_16=false; break 2
            fi
          done
          if [ "$_hs_16" = false ]; then _ALL_STEPS_16=false; break; fi
        done
      fi
      if [ "$_ALL_STEPS_16" != "true" ]; then
        log_block "PG-VERIF-INCOMPLETE-STEPS" "⛔ workflow_phase 전환 불가: 미완료 step 존재."
        jq -n --arg nxt "$_NEW_PHASE_16C" '{decision:"block", reason:("⛔ workflow_phase=" + $nxt + " 전환 불가: 미완료 step이 있습니다. 모든 step-*.md에 ✅가 있어야 합니다.")}'
        exit 0
      fi
      # CHECK 1.6c-2: verification 전환 시 모든 dev_phases status=done 확인
      _ALL_PHASES_DONE_16=$(echo "$_NEW_CONTENT_16C" | python3 -c "
import json, sys
txt = sys.stdin.read()
try:
    d = json.loads(txt)
except:
    print('skip'); sys.exit(0)
phases = d.get('dev_phases', {})
if not phases:
    print('ok'); sys.exit(0)
not_done = [k for k,v in phases.items() if v.get('status') not in (None, '', 'done')]
print('ok' if not not_done else ','.join(not_done))
" 2>/dev/null)
      if [ -n "$_ALL_PHASES_DONE_16" ] && [ "$_ALL_PHASES_DONE_16" != "ok" ] && [ "$_ALL_PHASES_DONE_16" != "skip" ]; then
        log_block "PG-VERIF-INCOMPLETE-PHASES" "⛔ workflow_phase 전환 불가: 미완료 dev_phase 존재."
        jq -n --arg nxt "$_NEW_PHASE_16C" --arg phases "$_ALL_PHASES_DONE_16" \
          '{decision:"block", reason:("⛔ workflow_phase=" + $nxt + " 전환 불가: 미완료 dev_phase가 있습니다 (" + $phases + "). 모든 phase를 완료하세요.")}'
        exit 0
      fi
    fi
    if [ "$_NEW_PHASE_16C" = "done" ]; then
      _E2E_RESULT="${TASK_DIR}/verifications/e2e-result.md"
      _E2E_PASS=false
      if [ -f "$_E2E_RESULT" ] && grep -A1 "^## 결론" "$_E2E_RESULT" 2>/dev/null | grep -q "^통과"; then
        _E2E_PASS=true
      fi
      if [ "$_E2E_PASS" != "true" ]; then
        log_block "PG-DONE-DIRECT" "⛔ verification 없이 done 직접 전환 불가."
        jq -n '{decision:"block", reason:"⛔ verification 없이 workflow_phase=done으로 직접 전환할 수 없습니다. Phase 4에서 e2e-writer를 통해 검증을 완료하세요."}'
        exit 0
      fi
    fi
  fi
  # CHECK 1.6e: development/verification 단계에서 cancelled 전환 전면 차단
  if [ "$_PLAN_APPROVED_16" = "true" ] && [[ "$_CURRENT_PHASE" == "development" || "$_CURRENT_PHASE" == "verification" ]]; then
    _NEW_CONTENT_16E=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
    _NEW_PHASE_16E=$(echo "$_NEW_CONTENT_16E" | python3 -c "
import json, sys, re
txt = sys.stdin.read()
try:
    d = json.loads(txt)
    print(d.get('workflow_phase', ''))
except:
    m = re.search(r'\"workflow_phase\"\s*:\s*\"([^\"]+)\"', txt)
    print(m.group(1) if m else '')
" 2>/dev/null)
    if [ "$_NEW_PHASE_16E" = "cancelled" ]; then
      log_block "PG-ARBITRARY-CANCEL" "⛔ [plan-gate] development/verification 단계에서 임의 cancelled 처리 금지."
      jq -n '{decision:"block", reason:"⛔ [plan-gate] development/verification 단계에서 임의로 cancelled 처리 금지. 사용자에게 현재 상태를 보고하고 지시를 기다리세요."}'
      exit 0
    fi
  fi
  # CHECK 1.6f: resolved_agent_mode=single 임의 override 차단
  # dev_phases > 3인데 config agent_mode != "single"일 때 single로 쓰면 차단
  _NEW_CONTENT_16F=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')
  _16F_PHASE_COUNT=$(echo "$_NEW_CONTENT_16F" | python3 -c "
import json, sys
txt = sys.stdin.read()
try:
    d = json.loads(txt)
except:
    sys.exit(0)
if d.get('resolved_agent_mode', '') != 'single':
    sys.exit(0)
phase_count = len(d.get('dev_phases', {}))
if phase_count <= 3:
    sys.exit(0)
print(phase_count)
" 2>/dev/null)
  if [ -n "$_16F_PHASE_COUNT" ]; then
    _BCFG_16F=$(python3 -c "import os; d=['.claude/ai-bouncer/scripts','scripts']; g=os.path.expanduser('~/.claude/ai-bouncer/scripts'); print(next((p for p in [*d,g] if os.path.isfile(p+'/bouncer-config.sh')),''))" 2>/dev/null)
    _CFG_MODE_16F="team"
    [ -n "$_BCFG_16F" ] && _CFG_MODE_16F=$(bash "$_BCFG_16F/bouncer-config.sh" agent_mode team 2>/dev/null)
    if [ "$_CFG_MODE_16F" != "single" ]; then
      log_block "PG-RESOLVED-SINGLE-OVERRIDE" "⛔ [plan-gate] resolved_agent_mode=single 임의 override 금지."
      jq -n --arg r "⛔ [plan-gate] resolved_agent_mode=single 임의 override 금지. config의 agent_mode=${_CFG_MODE_16F}이고 dev_phases=${_16F_PHASE_COUNT}개(>3)입니다. SKILL.md 규칙: PHASE_COUNT>3이면 CONFIG_MODE 그대로 사용." \
        '{decision:"block", reason:$r}'
      exit 0
    fi
  fi
fi

# state.json 값 읽기
WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)
TEAM_NAME=$(jq -r '.team_name // ""' "$STATE_FILE" 2>/dev/null)
CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE//[^0-9]/}; CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE:-0}
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=${CURRENT_STEP//[^0-9]/}; CURRENT_STEP=${CURRENT_STEP:-0}

# CHECK 1.5: workflow_phase 화이트리스트
case "$WORKFLOW_PHASE" in
  planning|development|verification) ;;
  done|cancelled) exit 0 ;;  # 완료/취소 상태 — gate 비활성
  *)
    log_block "PG-PHASE-INVALID" "⛔ workflow_phase가 허용되지 않는 값."
    jq -n '{decision:"block", reason:"⛔ workflow_phase가 허용되지 않는 값입니다."}'
    exit 0 ;;
esac

# CHECK 2: planning 단계 → 프로젝트 소스 파일 차단, .ai-bouncer-tasks/ + 외부 경로 허용
if [ "$WORKFLOW_PHASE" = "planning" ]; then
  if [[ "$FILE_PATH" == */phase-*.md ]] || [[ "$FILE_PATH" == */step-*.md ]]; then
    log_block "PG-PLANNING-PHASE-FILE" "⛔ planning 단계에서 phase/step 파일 작성 금지."
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
       [[ "$_PG_FILE_REAL" != *"/.ai-bouncer-tasks/"* ]]; then
      log_block "PG-PLANNING-SOURCE-FILE" "⛔ planning 단계에서 프로젝트 소스 파일 수정 금지."
      jq -n '{
        decision: "block",
        reason: "⛔ planning 단계에서 프로젝트 소스 파일을 수정할 수 없습니다. 계획을 승인받은 후 개발을 시작하세요."
      }'
      exit 0
    fi
  fi
  exit 0
fi

# .active 파일: 이미 다른 세션이 claim한 경우 덮어쓰기 방지
if [[ "$FILE_PATH" == */.active ]]; then
  _existing_sid=$(cat "$FILE_PATH" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$_existing_sid" ] && [ "$_existing_sid" != "$SESSION_ID" ]; then
    log_block "PG-ACTIVE-CONFLICT" "⛔ 다른 세션이 claim한 .active 파일 덮어쓰기 금지."
    jq -n --arg sid "$_existing_sid" '{
      decision: "block",
      reason: ("⛔ 이 .active 파일은 다른 세션(" + $sid + ")이 claim 중입니다. 강제로 덮어쓸 수 없습니다.")
    }'
    exit 0
  fi
fi

# CHECK verifications-in-development: development 상태에서 verifications/ 쓰기 차단
# Phase 4 시작 전 state를 verification으로 먼저 변경해야 함
if { [[ "$FILE_PATH" == */.ai-bouncer-tasks/*/verifications/* ]] || [[ "$FILE_PATH" == .ai-bouncer-tasks/*/verifications/* ]]; } && [ "$WORKFLOW_PHASE" = "development" ]; then
  log_block "PG-VERIFICATIONS-EARLY" "⛔ development 상태에서 verifications/ 작성 불가."
  jq -n '{decision:"block", reason:"⛔ development 상태에서 verifications/ 파일 작성 불가. Phase 4 시작 전 state.json workflow_phase를 \"verification\"으로 먼저 변경하세요."}'
  exit 0
fi

# .ai-bouncer-tasks/ 하위 파일은 태스크 관리 파일 → plan_approved 무관 허용
# 단, .py/.sh 스크립트 생성 금지 (scaffold 방지)
if [[ "$FILE_PATH" == */.ai-bouncer-tasks/* ]] || [[ "$FILE_PATH" == .ai-bouncer-tasks/* ]]; then
  if [[ "$FILE_PATH" == *.py ]] || [[ "$FILE_PATH" == *.sh ]]; then
    log_block "PG-INTERNAL-SCRIPT" "⛔ .ai-bouncer-tasks/ 내부 스크립트 생성 금지."
    jq -n '{decision:"block", reason:"⛔ .ai-bouncer-tasks/ 내부에 스크립트(.py/.sh) 생성 금지. 태스크 문서는 .md 파일만 허용됩니다."}'
    exit 0
  fi
  exit 0
fi

# 공통 게이트 검증 (CHECK 3-7)
GATE_FILE="$FILE_PATH"
source "$SCRIPT_DIR/lib/gate-checks.sh"
_run_gate_checks

# --- ai-bouncer end ---

exit 0
