#!/bin/bash
# gate-checks: plan-gate / bash-gate 공통 검증 로직 (CHECK 3-7)
# plan-gate.sh / bash-gate.sh 에서 resolve-task.sh 소싱 후 이 파일을 소싱하고
# _run_gate_checks [prefix] 를 호출한다.
#
# 필수 (resolve-task.sh 가 설정):
#   STATE_FILE, TASK_DIR, BOUNCER_CONFIG
#
# 필수 (각 gate 에서 설정):
#   WORKFLOW_PHASE, PLAN_APPROVED, TEAM_NAME
#   CURRENT_DEV_PHASE, CURRENT_STEP
#
# 선택 (gate 종류에 따라 설정):
#   GATE_FILE  — Write/Edit 대상 파일 경로 (plan-gate 가 설정)
#   GATE_CMD   — Bash 명령어 (bash-gate 가 설정)

# 현재 write 대상이 target_path 인지 확인 (bootstrap 감지용)
_gate_is_bootstrap_for() {
  local target="$1"
  if [ -n "${GATE_FILE:-}" ]; then
    local _abs _tgt
    _abs=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${GATE_FILE}" 2>/dev/null || echo "${GATE_FILE}")
    _tgt=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$target" 2>/dev/null || echo "$target")
    [ "$_abs" = "$_tgt" ] && return 0
  fi
  [ -n "${GATE_CMD:-}" ] && echo "${GATE_CMD}" | grep -qF "$target" && return 0
  return 1
}

# 공통 게이트 검증
# 인자: prefix 문자열 (예: "[bash-gate] " — 에러 메시지 앞에 붙임)
_run_gate_checks() {
  local _P="${1:-}"

  # 승인된 sub-agent: Main Claude가 plan 승인 후 스폰한 에이전트 → gate 전체 스킵
  if [ "${IS_DELEGATED_AGENT:-false}" = "true" ]; then
    return 0
  fi

  # per-phase team_name: dev_phases[N].team_name → TEAM_NAME 덮어쓰기
  # top-level team_name 필드 제거 후 plan-gate/bash-gate는 "" 반환하므로, 현재 Phase 팀으로 교체.
  if [ "${WORKFLOW_PHASE}" = "development" ] && [ "${CURRENT_DEV_PHASE:-0}" -gt 0 ]; then
    local _PHASE_TN
    _PHASE_TN=$(jq -r --argjson ph "${CURRENT_DEV_PHASE}" \
      '.dev_phases[($ph|tostring)].team_name // ""' "${STATE_FILE}" 2>/dev/null)
    TEAM_NAME="${_PHASE_TN}"
  fi

  # CHECK 3: plan_approved + plan.md 실존
  if [ "${PLAN_APPROVED}" != "true" ]; then
    jq -n --arg r "⛔ ${_P}계획이 승인되지 않았습니다. /dev-bounce로 계획을 수립하고 승인 후 개발을 시작하세요." \
       '{decision:"block", reason:$r}'
    exit 0
  fi
  if [ ! -f "${TASK_DIR}/plan.md" ]; then
    jq -n --arg r "⛔ ${_P}plan.md 파일이 존재하지 않습니다. 계획 문서가 실제로 작성되어야 합니다." \
       '{decision:"block", reason:$r}'
    exit 0
  fi

  # AGENT_MODE
  local AGENT_MODE
  AGENT_MODE=$(jq -r '.agent_mode // "team"' "${BOUNCER_CONFIG}" 2>/dev/null || echo "team")

  # resolved_agent_mode in state.json overrides config.json
  # (plan.md Phase 수 기반으로 Phase 1에서 동적 결정됨, ≤3 Phase → single)
  if [ -n "${STATE_FILE:-}" ] && [ -f "${STATE_FILE}" ]; then
    local _RESOLVED
    _RESOLVED=$(jq -r '.resolved_agent_mode // empty' "${STATE_FILE}" 2>/dev/null)
    [ -n "$_RESOLVED" ] && AGENT_MODE="$_RESOLVED"
  fi

  case "$AGENT_MODE" in
    team)
      if [ "${WORKFLOW_PHASE}" = "development" ] && [ -z "${TEAM_NAME:-}" ]; then
        jq -n --arg r "⛔ ${_P}[team] 팀이 구성되지 않았습니다. TeamCreate로 팀을 먼저 생성하세요." \
           '{decision:"block", reason:$r}'
        exit 0
      fi

      if [ "${WORKFLOW_PHASE}" = "development" ]; then
        local _home="${HOME:-$(eval echo ~"$(id -un)" 2>/dev/null)}"
        local TEAM_CONFIG="${_home}/.claude/teams/${TEAM_NAME:-}/config.json"
        if [ ! -f "$TEAM_CONFIG" ]; then
          jq -n --arg r "⛔ ${_P}[team] 팀 디렉토리가 존재하지 않습니다. TeamCreate로 팀을 먼저 생성하세요." \
             '{decision:"block", reason:$r}'
          exit 0
        fi

        local MEMBER_COUNT
        MEMBER_COUNT=$(jq -r '.members | length' "$TEAM_CONFIG" 2>/dev/null)
        MEMBER_COUNT=${MEMBER_COUNT//[^0-9]/}; MEMBER_COUNT=${MEMBER_COUNT:-0}
        if [ "$MEMBER_COUNT" -lt 1 ]; then
          jq -n --arg r "⛔ ${_P}[team] 팀 멤버가 없습니다. Dev/QA를 스폰하세요." \
             '{decision:"block", reason:$r}'
          exit 0
        fi

        local NON_LEAD_COUNT
        NON_LEAD_COUNT=$(jq -r '[.members[] | select(.name | ascii_downcase | test("lead") | not)] | length' "$TEAM_CONFIG" 2>/dev/null)
        NON_LEAD_COUNT=${NON_LEAD_COUNT//[^0-9]/}; NON_LEAD_COUNT=${NON_LEAD_COUNT:-0}
        if [ "$NON_LEAD_COUNT" -lt 1 ]; then
          local _should_block=true
          # plan-gate 모드(GATE_FILE 있음): 프로젝트 소스 파일인지 확인 후 판단
          if [ -n "${GATE_FILE:-}" ]; then
            local _repo _fabs
            _repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
            if [ -n "$_repo" ]; then
              _fabs=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${GATE_FILE}" 2>/dev/null || echo "${GATE_FILE}")
              if ! { [[ "$_fabs" == "$_repo"* ]] && [[ "$_fabs" != "$_repo/.ai-bouncer-tasks/"* ]]; }; then
                _should_block=false
              fi
            fi
          fi
          if [ "$_should_block" = "true" ]; then
            jq -n --arg r "⛔ ${_P}[team] Dev/QA 에이전트가 없습니다. Main Claude가 Dev/QA를 스폰하세요." \
               '{decision:"block", reason:$r}'
            exit 0
          fi
        fi
      fi
      ;;
    subagent|single) ;;
  esac

  # CHECK 6.5: development + dev_phase/step=0 방어
  if [ "${WORKFLOW_PHASE}" = "development" ]; then
    if [ "${CURRENT_DEV_PHASE}" -le 0 ] || [ "${CURRENT_STEP}" -le 0 ]; then
      jq -n --arg r "⛔ ${_P}development이지만 dev_phase/step 미설정" \
         '{decision:"block", reason:$r}'
      exit 0
    fi
  fi

  # CHECK 6.7: dev_phases 비어있는지
  if [ "${WORKFLOW_PHASE}" = "development" ]; then
    local _DPC
    _DPC=$(jq '.dev_phases | length' "${STATE_FILE}" 2>/dev/null)
    _DPC=${_DPC:-0}; _DPC=${_DPC//[^0-9]/}; _DPC=${_DPC:-0}
    if [ "$_DPC" -le 0 ]; then
      jq -n --arg r "⛔ ${_P}dev_phases가 비어있습니다. Main Claude가 phase 구조를 먼저 정의해야 합니다." \
         '{decision:"block", reason:$r}'
      exit 0
    fi
  fi

  # CHECK 6.8: verification + 미완료 Phase
  if [ "${WORKFLOW_PHASE}" = "verification" ]; then
    local _DPC
    _DPC=$(jq '.dev_phases | length' "${STATE_FILE}" 2>/dev/null)
    _DPC=${_DPC:-0}
    if [ "$_DPC" -gt 0 ]; then
      local ALL_PHASES_DONE=true
      local _pidx
      for _pidx in $(seq 1 "$_DPC"); do
        local _pf _pd _hs=false _sf
        _pf=$(_get_phase_folder "${STATE_FILE}" "$_pidx")
        _pd="${TASK_DIR}/${_pf}"
        for _sf in "$_pd"/step-*.md; do
          [ -f "$_sf" ] || continue
          _hs=true
          if ! grep -q '✅' "$_sf" 2>/dev/null; then
            ALL_PHASES_DONE=false; break 2
          fi
        done
        if [ "$_hs" = false ]; then ALL_PHASES_DONE=false; break; fi
      done
      if [ "$ALL_PHASES_DONE" = false ]; then
        jq -n --arg r "⛔ ${_P}verification 단계이지만 모든 개발 Phase가 완료되지 않았습니다. 미완료 Phase의 개발을 먼저 완료하세요." \
           '{decision:"block", reason:$r}'
        exit 0
      fi
    fi
  fi

  # CHECK 7: phase/step 아티팩트 검증
  [ "${CURRENT_DEV_PHASE}" -gt 0 ] && [ "${CURRENT_STEP}" -gt 0 ] || return 0

  local DEV_PHASE_KEY="${CURRENT_DEV_PHASE}"
  local STEP_KEY="${CURRENT_STEP}"
  local PHASE_FOLDER PHASE_DIR
  PHASE_FOLDER=$(_get_phase_folder "${STATE_FILE}" "$DEV_PHASE_KEY")
  PHASE_DIR="${TASK_DIR}/${PHASE_FOLDER}"

  # state.json 수정 → CHECK 7 전체 스킵 (deadlock 방지)
  if [[ "${GATE_FILE:-}" == */state.json ]]; then
    return 0
  fi

  # CHECK 7-PHASE: 이전 Phase 완료 검증
  local PREV_DEV_PHASE=$(( CURRENT_DEV_PHASE - 1 ))
  if [ "$PREV_DEV_PHASE" -gt 0 ]; then
    local _ppf _ppd PREV_PHASE_INCOMPLETE=false _psf
    _ppf=$(_get_phase_folder "${STATE_FILE}" "$PREV_DEV_PHASE")
    _ppd="${TASK_DIR}/${_ppf}"
    for _psf in "$_ppd"/step-*.md; do
      [ -f "$_psf" ] || continue
      if ! grep -q '✅' "$_psf" 2>/dev/null; then
        PREV_PHASE_INCOMPLETE=true; break
      fi
    done
    if [ "$PREV_PHASE_INCOMPLETE" = true ]; then
      jq -n --arg phase "$PREV_DEV_PHASE" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Phase " + $phase + "의 모든 Step이 완료되지 않았습니다. 이전 Phase를 먼저 완료하세요.")}'
      exit 0
    fi
  fi

  # CHECK 7a: phase.md 존재 + bootstrap 감지
  local _IS_PHASE_BOOTSTRAP=false
  if [ ! -f "${PHASE_DIR}/phase.md" ]; then
    if ! _gate_is_bootstrap_for "${PHASE_DIR}/phase.md"; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + "의 phase.md가 존재하지 않습니다. Main Claude가 phase.md를 먼저 생성해야 합니다.")}'
      exit 0
    fi
    _IS_PHASE_BOOTSTRAP=true
  fi

  # CHECK 7a-2: phase.md 필수 섹션 검증
  if [ "$_IS_PHASE_BOOTSTRAP" = false ]; then
    local _sec
    for _sec in "## 목표" "## 기술 접근" "## Steps"; do
      if ! LC_ALL=en_US.UTF-8 grep -q "$_sec" "${PHASE_DIR}/phase.md" 2>/dev/null; then
        jq -n --arg phase "$DEV_PHASE_KEY" --arg s "$_sec" --arg r "${_P}" \
           '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + "의 phase.md에 필수 섹션 누락: " + $s)}'
        exit 0
      fi
    done
  fi

  # 이전 step 검증
  local PREV_STEP=$(( CURRENT_STEP - 1 ))
  if [ "$PREV_STEP" -gt 0 ]; then
    local PREV_STEP_FILE="${PHASE_DIR}/step-${PREV_STEP}.md"

    # CHECK 7b: 이전 step 파일 미존재
    if [ ! -f "$PREV_STEP_FILE" ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + " 문서가 존재하지 않습니다.")}'
      exit 0
    fi

    # CHECK 7c: 이전 step ✅ 미포함
    if ! grep -q '✅' "$PREV_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + " 테스트가 통과되지 않았습니다 (✅ 없음). 테스트를 먼저 통과시킨 후 진행하세요.")}'
      exit 0
    fi

    # CHECK 7c-2: 실행출력 섹션 존재
    if ! LC_ALL=en_US.UTF-8 grep -qE '(실행출력|실행 결과|출력:|Output:)' "$PREV_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + "의 TC에 실행출력이 없습니다. 테스트 실행 결과를 반드시 기록하세요.")}'
      exit 0
    fi

    # CHECK 7c-3: 실행출력 섹션 내용 확인 (빈 섹션 방지)
    local _EXEC_LINES
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
    if [ "${_EXEC_LINES:-0}" -lt 2 ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + "의 실행출력이 비어있습니다. 실제 명령어 실행 결과를 붙여넣으세요.")}'
      exit 0
    fi
  fi

  # 현재 step 검증
  local CURRENT_STEP_FILE="${PHASE_DIR}/step-${STEP_KEY}.md"

  # CHECK 7d: 현재 step 파일 미존재 (bootstrap 허용)
  if [ ! -f "$CURRENT_STEP_FILE" ]; then
    if ! _gate_is_bootstrap_for "$CURRENT_STEP_FILE"; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + " 의 step.md가 존재하지 않습니다. Main Claude가 step.md를 먼저 생성해야 합니다.")}'
      exit 0
    fi
  fi

  # CHECK 7e: TC 미정의 (bootstrap 허용)
  if ! _gate_is_bootstrap_for "$CURRENT_STEP_FILE"; then
    if ! grep -E '^\| *TC-[0-9]+ *\| *[^ |]' "$CURRENT_STEP_FILE" >/dev/null 2>&1; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + " 의 테스트 기준이 정의되지 않았습니다. QA가 TC를 먼저 작성해야 합니다.")}'
      exit 0
    fi

    # CHECK 7e-2: TC 내용 충실도 (시나리오/기대결과 5자 미만 방지)
    local _TC_SHALLOW
    _TC_SHALLOW=$(grep -E '^\| *TC-[0-9]+' "$CURRENT_STEP_FILE" 2>/dev/null | python3 -c "
import sys
shallow = 0
for line in sys.stdin:
    cols = [c.strip() for c in line.strip().strip('|').split('|')]
    if len(cols) >= 4:
        # 신형 5컬럼: cols[1]=유형, cols[2]=시나리오, cols[3]=기대결과
        if len(cols[2].strip()) < 5 or len(cols[3].strip()) < 5:
            shallow += 1
    elif len(cols) == 3:
        # 구형 4컬럼: cols[1]=시나리오, cols[2]=기대결과
        if len(cols[1].strip()) < 5 or len(cols[2].strip()) < 5:
            shallow += 1
print(shallow)
" 2>/dev/null || echo 0)
    if [ "${_TC_SHALLOW:-0}" -gt 0 ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" --arg n "$_TC_SHALLOW" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + ": TC " + $n + "개의 시나리오/기대결과가 너무 짧습니다 (5자 미만). 구체적으로 작성하세요.")}'
      exit 0
    fi

    # CHECK 7e-3: 검증 명령어(backtick) 존재
    if ! LC_ALL=en_US.UTF-8 grep -q '`' "$CURRENT_STEP_FILE" 2>/dev/null; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" --arg r "${_P}" \
         '{decision:"block", reason:("⛔ " + $r + "Dev Phase " + $phase + " Step " + $step + "에 검증 명령어(backtick)가 없습니다. 실행 가능한 명령어를 포함하세요.")}'
      exit 0
    fi
  fi
}
