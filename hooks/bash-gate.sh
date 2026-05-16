#!/bin/bash
# bash-gate: PreToolUse hook (Layer 1)
# Bash 도구로 파일 쓰기 우회 차단 — 쓰기 패턴 휴리스틱 감지

HOOK_NAME="bash-gate"
source "$(dirname "${BASH_SOURCE[0]}")/lib/block-logger.sh"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Bash만 체크
[ "$TOOL" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

# 세션 격리: session_id 추출
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -n "$SESSION_ID" ] && echo "$SESSION_ID" > /tmp/.ai-bouncer-current-session

# --- ai-bouncer start ---

# 0. .ai-bouncer-tasks/ 내부 스크립트 실행 차단 (scaffold 방지) — fast-exit보다 먼저
if echo "$CMD" | grep -qE '(\.venv/bin/python|python3?|bash|sh)\s+[^ ]*\.ai-bouncer-tasks/[^ ]*\.(py|sh)'; then
  log_block "BG-INTERNAL-SCRIPT" "⛔ [bash-gate] .ai-bouncer-tasks/ 내부 스크립트 실행 금지."
  jq -n '{decision:"block", reason:"⛔ [bash-gate] .ai-bouncer-tasks/ 내부 스크립트 실행 금지. step.md는 Write 도구로 개별 작성하세요."}'
  exit 0
fi

# 1. Fast exit: 쓰기 패턴 미포함 → exit 0 (git commit/push는 제외)
# fd redirect (2>/dev/null, 1>&2 등) 제거 후 검사 — 오탐 방지
CMD_CLEAN=$(echo "$CMD" | sed -E 's/[0-9]+>\/dev\/null//g; s/[0-9]+>[&]?[0-9]*//g')
if ! echo "$CMD_CLEAN" | grep -qE '>[^&]|>>|\btee\b|\bsed\b.*-i|\bcp\b|\bmv\b|\btouch\b|\bdd\b.*of=|\bpython|\bnode\b.*-e|\bruby\b.*-e|\bperl\b.*-e|\brm\b|\brmdir\b|\bunlink\b|\bcurl\b.*(-o|--output)|\bwget\b'; then
  # 쓰기 패턴 없지만 git commit/push면 commit_strategy 검증 필요
  if echo "$CMD" | grep -qE '^\s*git\s+(commit|push)\b'; then
    :
  else
    exit 0
  fi
fi

# 2. git 명령어 분기
if echo "$CMD" | grep -qE '^\s*git\b'; then
  # git commit/push → commit_strategy 검증 (아래 블록)
  if echo "$CMD" | grep -qE '\bgit\s+(commit|push)\b'; then
    :
  else
    # 나머지 git 명령 (status, add, diff 등) → 통과
    exit 0
  fi
fi

# 2-1. commit_strategy 검증 (git commit/push)
if echo "$CMD" | grep -qE '^\s*git\s+(commit|push)\b'; then
  REPO_ROOT_CS=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  CONFIG_CS="${REPO_ROOT_CS}/.claude/ai-bouncer/config.json"
  [ ! -f "$CONFIG_CS" ] && CONFIG_CS="$HOME/.claude/ai-bouncer/config.json"

  # config.json 없으면 통과
  [ ! -f "$CONFIG_CS" ] && exit 0

  COMMIT_STRATEGY=$(jq -r '.commit_strategy // "per-step"' "$CONFIG_CS" 2>/dev/null || echo "per-step")

  # none → 항상 block
  if [ "$COMMIT_STRATEGY" = "none" ]; then
    log_block "BG-COMMIT-NONE" "⛔ [bash-gate] commit_strategy=none: 커밋이 차단됩니다."
    jq -n '{decision:"block", reason:"⛔ [bash-gate] commit_strategy=none: 커밋이 차단됩니다. 수동 관리 모드."}'
    exit 0
  fi

  # .active 탐색 (resolve-task.sh)
  SCRIPT_DIR_CS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR_CS/lib/resolve-task.sh"

  # .active 없거나 내 세션이 아니면 gate 비활성 → 통과
  [ "$IS_MY_TASK" != "true" ] && exit 0

  # state.json 없으면 통과
  [ -f "$STATE_FILE" ] || exit 0

  CS_WORKFLOW=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)

  # done → 항상 허용
  [ "$CS_WORKFLOW" = "done" ] && exit 0

  # verification → 모든 Phase 완료 시만 허용 (plan-gate CHECK 6.8 동등)
  if [ "$CS_WORKFLOW" = "verification" ]; then
    DEV_PHASES_COUNT=$(jq '.dev_phases | length' "$STATE_FILE" 2>/dev/null)
    DEV_PHASES_COUNT=${DEV_PHASES_COUNT:-0}
    if [ "$DEV_PHASES_COUNT" -gt 0 ]; then
      ALL_DONE=true
      for pidx in $(seq 1 "$DEV_PHASES_COUNT"); do
        PFOLDER=$(_get_phase_folder "$STATE_FILE" "$pidx")
        PDIR="${TASK_DIR}/${PFOLDER}"
        HAS_STEPS=false
        for sf in "$PDIR"/step-*.md; do
          [ -f "$sf" ] || continue
          HAS_STEPS=true
          if ! grep -q '✅' "$sf" 2>/dev/null; then
            ALL_DONE=false
            break 2
          fi
        done
        if [ "$HAS_STEPS" = false ]; then
          ALL_DONE=false
          break
        fi
      done
      if [ "$ALL_DONE" = false ]; then
        log_block "BG-COMMIT-VERIFICATION-INCOMPLETE" "⛔ [bash-gate] verification이지만 미완료 Phase 존재."
        jq -n --arg count "$DEV_PHASES_COUNT" '{
          decision: "block",
          reason: ("⛔ [bash-gate] verification이지만 미완료 Phase 존재. 개발을 먼저 완료하세요. (총 " + $count + "개 Phase)")
        }'
        exit 0
      fi
    fi
    exit 0
  fi

  # planning → 커밋 허용 (bash-gate가 코드 수정을 이미 차단. 워크로그 등 커밋 가능)
  [ "$CS_WORKFLOW" = "planning" ] && exit 0

  CS_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
  CS_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)
  CS_PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$CS_PHASE")

  if [ "$COMMIT_STRATEGY" = "per-step" ]; then
    STEP_FILE_CS="${TASK_DIR}/${CS_PHASE_FOLDER}/step-${CS_STEP}.md"
    if [ -f "$STEP_FILE_CS" ] && grep -q '✅' "$STEP_FILE_CS" 2>/dev/null; then
      exit 0
    fi
    log_block "BG-COMMIT-PERSTEP-INCOMPLETE" "⛔ [bash-gate] commit_strategy=per-step: 현재 Step 미완료."
    jq -n --arg p "$CS_PHASE" --arg s "$CS_STEP" \
      '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-step: Phase " + $p + " Step " + $s + " 미완료. 테스트 통과 후 커밋하세요.")}'
    exit 0
  fi

  if [ "$COMMIT_STRATEGY" = "per-phase" ]; then
    # current_step=1이면 새 Phase 시작 상태 → 이전 Phase(N-1) 기준으로 검증
    # (Lead가 Phase N 완료 후 N+1로 넘긴 직후 커밋 시 차단되는 레이스컨디션 방지)
    COMMIT_PHASE_CS=$CS_PHASE
    COMMIT_FOLDER_CS=$CS_PHASE_FOLDER
    if [ "${CS_STEP:-1}" -le 1 ] && [ "$CS_PHASE" -gt 1 ]; then
      COMMIT_PHASE_CS=$((CS_PHASE - 1))
      COMMIT_FOLDER_CS=$(_get_phase_folder "$STATE_FILE" "$COMMIT_PHASE_CS")
    fi
    STEP_COUNT_CS=$(jq -r ".dev_phases[\"$COMMIT_PHASE_CS\"].steps | length" "$STATE_FILE" 2>/dev/null)
    # state.json에 steps 미등록 시 파일시스템 fallback: step-*.md 파일로 판단
    if [ "${STEP_COUNT_CS:-0}" -le 0 ] 2>/dev/null; then
      COMMIT_PDIR="${TASK_DIR}/${COMMIT_FOLDER_CS}"
      FS_LAST_STEP_CS=0
      for sf in "$COMMIT_PDIR"/step-*.md; do
        [ -f "$sf" ] || continue
        snum="${sf##*/step-}"; snum="${snum%.md}"
        [ "$snum" -gt "$FS_LAST_STEP_CS" ] 2>/dev/null && FS_LAST_STEP_CS=$snum
      done
      if [ "$FS_LAST_STEP_CS" -le 0 ] 2>/dev/null; then
        log_block "BG-COMMIT-PERPHASE-NO-STEPS" "⛔ [bash-gate] commit_strategy=per-phase: 현재 Phase에 Step 파일 없음."
        jq -n --arg p "$COMMIT_PHASE_CS" \
          '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-phase: Phase " + $p + "에 Step이 없습니다. Step을 먼저 생성하세요.")}'
        exit 0
      fi
      FS_LAST_STEP_FILE="${COMMIT_PDIR}/step-${FS_LAST_STEP_CS}.md"
      if [ -f "$FS_LAST_STEP_FILE" ] && grep -q '✅' "$FS_LAST_STEP_FILE" 2>/dev/null; then
        exit 0
      fi
      log_block "BG-COMMIT-PERPHASE-LAST-A" "⛔ [bash-gate] commit_strategy=per-phase: 마지막 Step(fs fallback) 미완료."
      jq -n --arg p "$COMMIT_PHASE_CS" --arg ls "$FS_LAST_STEP_CS" \
        '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-phase: Phase " + $p + " 마지막 Step " + $ls + " 미완료. Phase 완료 후 커밋하세요.")}'
      exit 0
    fi
    LAST_STEP_CS=$(jq -r ".dev_phases[\"$COMMIT_PHASE_CS\"].steps | keys | map(tonumber) | max // 0" "$STATE_FILE" 2>/dev/null)
    LAST_STEP_FILE_CS="${TASK_DIR}/${COMMIT_FOLDER_CS}/step-${LAST_STEP_CS}.md"
    if [ -f "$LAST_STEP_FILE_CS" ] && grep -q '✅' "$LAST_STEP_FILE_CS" 2>/dev/null; then
      exit 0
    fi
    log_block "BG-COMMIT-PERPHASE-LAST-B" "⛔ [bash-gate] commit_strategy=per-phase: 마지막 Step 미완료."
    jq -n --arg p "$COMMIT_PHASE_CS" --arg ls "$LAST_STEP_CS" \
      '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-phase: Phase " + $p + " 마지막 Step " + $ls + " 미완료. Phase 완료 후 커밋하세요.")}'
    exit 0
  fi

  # 알 수 없는 strategy → 통과 (하위 호환)
  exit 0
fi

# 3. 쓰기 패턴 상세 감지
IS_WRITE=false

# 리다이렉트: >, >> (단 >& 및 fd redirect 제외)
if echo "$CMD_CLEAN" | grep -qE '>[^>&]|>>'; then
  IS_WRITE=true
fi

# tee (파이프로 파일 쓰기)
if echo "$CMD" | grep -qE '\btee\b'; then
  IS_WRITE=true
fi

# sed -i (인플레이스 수정)
if echo "$CMD" | grep -qE '\bsed\b.*-i'; then
  IS_WRITE=true
fi

# cp, mv (파일 복사/이동)
if echo "$CMD" | grep -qE '\bcp\b|\bmv\b'; then
  IS_WRITE=true
fi

# touch (파일 생성)
if echo "$CMD" | grep -qE '\btouch\b'; then
  IS_WRITE=true
fi

# dd of= (블록 디바이스 쓰기)
if echo "$CMD" | grep -qE '\bdd\b.*of='; then
  IS_WRITE=true
fi

# 스크립트 언어로 파일 쓰기
if echo "$CMD" | grep -qE '\bpython[23]?\b.*(-c|<<)|\bnode\b.*-e|\bruby\b.*-e|\bperl\b.*-e'; then
  IS_WRITE=true
fi

# cat/echo + heredoc
if echo "$CMD" | grep -qE '\bcat\b.*>|\becho\b.*>|\bprintf\b.*>'; then
  IS_WRITE=true
fi

# rm, rmdir, unlink (파일/디렉토리 삭제)
if echo "$CMD" | grep -qE '\brm\b|\brmdir\b|\bunlink\b'; then
  IS_WRITE=true
fi

# curl -o/--output (파일 다운로드)
if echo "$CMD" | grep -qE '\bcurl\b.*(-o|--output)'; then
  IS_WRITE=true
fi

# wget (항상 파일 저장)
if echo "$CMD" | grep -qE '\bwget\b'; then
  IS_WRITE=true
fi

[ "$IS_WRITE" = "false" ] && exit 0

# 4. 예외 경로 — gate 관리 파일은 항상 허용
EXCEPTION=false

# ~/.claude/plans/ 경로
if echo "$CMD" | grep -qE '\.claude/plans/'; then
  EXCEPTION=true
fi

# state.json 파일 (.active는 예외 아님 — 비우기로 gate 무력화 방지)
# rm/rmdir/unlink은 state.json도 예외 아님 (삭제 방지)
if echo "$CMD" | grep -qE 'state\.json' && ! echo "$CMD" | grep -qE '\brm\b|\brmdir\b|\bunlink\b'; then
  _BG_REPO=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  _BG_STATE=""
  for _bg_af in "$_BG_REPO"/.ai-bouncer-tasks/*/.active "$_BG_REPO"/.ai-bouncer-tasks/*/*/.active; do
    [ -f "$_bg_af" ] || continue
    _bg_sf="$(dirname "$_bg_af")/state.json"
    [ -f "$_bg_sf" ] || continue
    _bg_sid=$(cat "$_bg_af" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$SESSION_ID" ] || [ "$_bg_sid" = "$SESSION_ID" ]; then
      _BG_STATE="$_bg_sf"; break
    fi
  done
  if [ -n "$_BG_STATE" ]; then
    _BG_PHASE=$(jq -r '.workflow_phase // ""' "$_BG_STATE" 2>/dev/null)
    if [ "$_BG_PHASE" = "planning" ]; then
      # 패턴 1: dict literal / JSON ("workflow_phase":"done", 'workflow_phase':'done')
      # 패턴 2: jq (.workflow_phase = "done")
      # 패턴 3: 브라켓 접근 (state['workflow_phase'] = 'done')
      _WP_BLOCKED=false
      if echo "$CMD" | grep -qE "['\"](workflow_phase)['\"]\s*:\s*['\"](done|verification)['\"]"; then _WP_BLOCKED=true; fi
      if echo "$CMD" | grep -qE "\.workflow_phase\s*=\s*['\"](done|verification)['\"]"; then _WP_BLOCKED=true; fi
      if echo "$CMD" | grep -q "workflow_phase" && echo "$CMD" | grep -qE "\]\s*=\s*['\"]done['\"]"; then _WP_BLOCKED=true; fi
      if echo "$CMD" | grep -q "workflow_phase" && echo "$CMD" | grep -qE "\]\s*=\s*['\"]verification['\"]"; then _WP_BLOCKED=true; fi
      if [ "$_WP_BLOCKED" = "true" ]; then
        # cancelled 전환: pass through (planning→cancelled는 Phase 0 취소 케이스)
        if echo "$CMD" | grep -qE "cancelled"; then
          :
        else
          # done 전환: e2e-result.md 통과 조건 검증
          _ALLOW=false
          _TASK_DIR=$(dirname "$_BG_STATE")
          _E2E_RESULT="$_TASK_DIR/verifications/e2e-result.md"
          if [ -f "$_E2E_RESULT" ]; then
            if grep -A1 "^## 결론" "$_E2E_RESULT" 2>/dev/null | grep -q "^통과"; then
              _ALLOW=true
            fi
          fi
          if [ "$_ALLOW" = "false" ]; then
            log_block "BG-DONE-NO-VERIFY" "⛔ [bash-gate] done 조건 미충족. verifications/e2e-result.md 통과 필요."
            jq -n '{decision:"block", reason:"⛔ [bash-gate] done 조건 미충족. verifications/e2e-result.md 통과 필요."}'
            exit 0
          fi
        fi
      fi
    fi
    # development/verification 상태 + cancelled 전환 전면 차단
    if [[ "$_BG_PHASE" == "development" || "$_BG_PHASE" == "verification" ]]; then
      _BG_PA=$(jq -r '.plan_approved // false' "$_BG_STATE" 2>/dev/null)
      if [ "$_BG_PA" = "true" ] && echo "$CMD" | grep -qE "cancelled"; then
        log_block "BG-ARBITRARY-CANCEL" "⛔ [bash-gate] development/verification 단계에서 임의 cancelled 처리 금지."
        jq -n '{decision:"block", reason:"⛔ [bash-gate] development/verification 단계에서 임의로 cancelled 처리 금지. 사용자에게 현재 상태를 보고하고 지시를 기다리세요."}'
        exit 0
      fi
    fi
  fi
  EXCEPTION=true
fi

# plan.md, step-*.md, phase-*.md
if echo "$CMD" | grep -qE 'plan\.md|step-[0-9]+\.md|phase-[0-9]+.*\.md'; then
  EXCEPTION=true
fi

# .active 파일 조작 (삭제 포함 — dev-bounce 완료 시 필요)
# 단, 다른 세션이 claim한 .active는 조작 불가
# rm: workflow_phase=done/cancelled인 경우만 허용
if echo "$CMD" | grep -qE '\.active'; then
  _active_safe=true
  for _af_path in .ai-bouncer-tasks/*/*/.active .ai-bouncer-tasks/*/.active; do
    [ -f "$_af_path" ] || continue
    echo "$CMD" | grep -qF "$_af_path" || continue
    _af_sid=$(cat "$_af_path" 2>/dev/null | tr -d '[:space:]')
    # 다른 세션이 claim한 .active는 무조건 차단
    if [ -n "$_af_sid" ] && [ -n "$SESSION_ID" ] && [ "$_af_sid" != "$SESSION_ID" ]; then
      _active_safe=false; break
    fi
    # rm 명령인 경우 workflow_phase=done/cancelled 아니면 차단
    if echo "$CMD" | grep -qE '\brm\b'; then
      _af_state_path="$(dirname "$_af_path")/state.json"
      if [ -f "$_af_state_path" ]; then
        _af_wf=$(jq -r '.workflow_phase // ""' "$_af_state_path" 2>/dev/null)
        if [ "$_af_wf" != "done" ] && [ "$_af_wf" != "cancelled" ]; then
          log_block "BG-ACTIVE-DELETE" "⛔ [bash-gate] done/cancelled 아닌 상태에서 .active 삭제 금지."
          jq -n '{decision:"block", reason:"⛔ [bash-gate] workflow_phase가 done/cancelled 아닌 상태에서 .active 삭제 금지. 사용자에게 현재 상태를 보고하고 지시를 기다리세요."}'
          exit 0
        fi
      fi
    fi
  done
  [ "$_active_safe" = "true" ] && EXCEPTION=true
fi

# /tmp/ 임시 파일 조작 항상 허용 (worklog 중간 파일, mktemp 등)
if echo "$CMD_CLEAN" | grep -qE '(>|>>)[[:space:]]*/tmp/|tee[[:space:]]*/tmp/|\brm\b[[:space:]]*.*/tmp/|\bmktemp\b'; then
  EXCEPTION=true
fi
if echo "$CMD" | grep -qE '\btouch\b[[:space:]]*/tmp/|\bsed\b.*-i.*/tmp/|\bwget\b.*/tmp/|\bcurl\b.*-o[[:space:]]*/tmp/'; then
  EXCEPTION=true
fi
if echo "$CMD" | grep -qE '^\s*(cp|mv)\b.*[[:space:]]/tmp/' || echo "$CMD" | grep -qE '/tmp/.*[[:space:]]/tmp/'; then
  EXCEPTION=true
fi

# ~/.claude/ 경로 항상 허용 (설정 읽기, worklog 스크립트 등)
_CLAUDE_DIR="${HOME}/.claude"
if [ -n "$_CLAUDE_DIR" ] && echo "$CMD" | grep -qF "$_CLAUDE_DIR"; then
  EXCEPTION=true
fi

[ "$EXCEPTION" = "true" ] && exit 0

# 4.5. PRE-CHECK 제거됨
# SPAWNED_COUNT(/tmp/ 파일 기반) 검증이 fragile하여 정상 Dev 에이전트도 차단하는 버그 수정.
# Lead 차단은 team 모드 CHECK 6-DEV (NON_LEAD_COUNT) 에서 처리.

# 5. Gate 검증 (plan-gate.sh CHECK 2~7 동일)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"

# .active 없거나 내 세션이 아니면 → 통과 (gate 비활성)
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
          log_block "BG-DELEGATED-NO-TEAM" "⛔ [delegated][team] development 페이즈에서 team_name 없음."
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
    log_block "BG-PHASE-INVALID" "⛔ [bash-gate] workflow_phase가 허용되지 않는 값."
    jq -n '{decision:"block", reason:"⛔ [bash-gate] workflow_phase가 허용되지 않는 값입니다."}'
    exit 0 ;;
esac

# CHECK verifications-in-development: development 상태에서 verifications/ 쓰기 차단
if echo "$CMD" | grep -qE '\.ai-bouncer-tasks[/\\].*/verifications[/\\]' && [ "$WORKFLOW_PHASE" = "development" ]; then
  log_block "BG-VERIFICATIONS-EARLY" "⛔ [bash-gate] development 상태에서 verifications/ 작성 불가."
  jq -n '{decision:"block", reason:"⛔ [bash-gate] development 상태에서 verifications/ 파일 작성 불가. state.json workflow_phase를 \"verification\"으로 먼저 변경하세요."}'
  exit 0
fi

# 공통 게이트 검증 (CHECK 3-7)
GATE_CMD="$CMD"
source "$SCRIPT_DIR/lib/gate-checks.sh"
_run_gate_checks "[bash-gate] "

# 모든 검증 통과

# --- ai-bouncer end ---

exit 0
