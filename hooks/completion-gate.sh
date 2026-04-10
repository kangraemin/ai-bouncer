#!/bin/bash
# completion-gate: Stop hook
# Claude가 각 응답 턴을 마칠 때 실행
# 검증 단계에서 round-*.md 아티팩트 기반으로 검증 통과 여부 확인

# 세션 격리: session_id 추출 (Stop hook도 stdin JSON 수신)
INPUT=$(cat)
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# 승인된 sub-agent는 completion-gate 스킵 (부모 세션이 관리)
APPROVED_FILE="/tmp/.ai-bouncer-approved-agents"
if [ -n "$SESSION_ID" ] && [ -f "$APPROVED_FILE" ]; then
  if grep -q "^${SESSION_ID}|" "$APPROVED_FILE" 2>/dev/null; then
    exit 0
  fi
fi

# resolve_task_dir: 공유 라이브러리 사용
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"

[ -z "$TASK_NAME" ] && exit 0
[ -f "$STATE_FILE" ] || exit 0

WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

# cancelled/done/planning/pending 상태 → 통과
# development는 별도 체크 (NORMAL 모드에서 step ✅ 완료 여부 확인)
case "$WORKFLOW_PHASE" in
  cancelled|done|planning|pending) exit 0 ;;
esac

# development 상태에서 NORMAL 모드: 모든 phase/step ✅ 체크
if [ "$WORKFLOW_PHASE" = "development" ] && [ "$PLAN_APPROVED" = "true" ]; then
  MODE=$(jq -r '.mode // "simple"' "$STATE_FILE" 2>/dev/null)
  if [ "$MODE" = "normal" ]; then
    PHASE_COUNT=$(jq 'if .dev_phases | type == "object" then .dev_phases | keys | length else 0 end' "$STATE_FILE" 2>/dev/null || echo 0)
    if [ "$PHASE_COUNT" -gt 0 ]; then
      ALL_DONE=true
      BLOCK_REASON=""

      for i in $(seq 1 "$PHASE_COUNT"); do
        PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$i")
        PHASE_PATH="${TASK_DIR}/${PHASE_FOLDER}"

        if [ ! -d "$PHASE_PATH" ]; then
          ALL_DONE=false
          BLOCK_REASON="Phase ${i} (${PHASE_FOLDER}) 디렉토리가 없습니다"
          break
        fi

        STEP_FILES=$(ls "${PHASE_PATH}"/step-*.md 2>/dev/null)
        if [ -z "$STEP_FILES" ]; then
          ALL_DONE=false
          BLOCK_REASON="Phase ${i} (${PHASE_FOLDER}) step 파일이 없습니다"
          break
        fi

        for step_file in $STEP_FILES; do
          if ! grep -q "✅" "$step_file" 2>/dev/null; then
            ALL_DONE=false
            STEP_NAME=$(basename "$step_file")
            BLOCK_REASON="Phase ${i} / ${STEP_NAME} 미완료 (✅ 없음)"
            break 2
          fi
        done
      done

      if [ "$ALL_DONE" = "false" ]; then
        jq -n --arg reason "$BLOCK_REASON" --arg task "$TASK_NAME" '{
          decision: "block",
          reason: ("개발이 완료되지 않았습니다. [" + $task + "] " + $reason + ". 현재 Phase/Step을 완료 후 ✅ 표시하세요. 작업 취소하려면 state.json의 workflow_phase를 \"cancelled\"로 변경하세요.")
        }'
        exit 0
      fi

      # 모든 step ✅ 완료 — verification 전환 필요 여부 확인
      CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 1' "$STATE_FILE" 2>/dev/null)
      if [ "$CURRENT_DEV_PHASE" -le "$PHASE_COUNT" ]; then
        jq -n --arg task "$TASK_NAME" '{
          decision: "block",
          reason: ("모든 Phase/Step이 완료되었습니다. [" + $task + "] state.json의 workflow_phase를 \"verification\"으로 전환하고 verifier 에이전트를 실행하세요.")
        }'
        exit 0
      fi
    fi
  fi
  # SIMPLE 모드 또는 dev_phases 없음 → 통과
  exit 0
fi

# 검증 단계에서만 체크 (NORMAL 모드)
if [ "$PLAN_APPROVED" = "true" ] && [ "$WORKFLOW_PHASE" = "verification" ]; then
  VERIFY_DIR="${TASK_DIR}/verifications"

  # round-*.md 파일 수집 (숫자 순 정렬)
  if [ -d "$VERIFY_DIR" ]; then
    ROUND_FILES=$(ls "$VERIFY_DIR"/round-*.md 2>/dev/null | sort -t- -k2 -n)
  else
    ROUND_FILES=""
  fi

  if [ -z "$ROUND_FILES" ]; then
    TOTAL_ROUNDS=0
  else
    TOTAL_ROUNDS=$(echo "$ROUND_FILES" | grep -c 'round-' 2>/dev/null || echo 0)
  fi

  if [ "$TOTAL_ROUNDS" -lt 3 ]; then
    jq -n --arg rounds "$TOTAL_ROUNDS" --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] 3라운드 검증 통과 필요 (현재 round 파일: " + $rounds + "개). verifier 에이전트를 통해 검증을 완료하세요. 작업 취소하려면 state.json의 workflow_phase를 \"cancelled\"로 변경하세요.")
    }'
    exit 0
  fi

  # 마지막 round 파일 체크: "통과" 포함 + "실패" 미포함
  LAST_ROUND=$(echo "$ROUND_FILES" | tail -1)
  PASS=0

  if [ -n "$LAST_ROUND" ]; then
    HAS_REQUIRED=1
    # ## 결론 섹션 필수 (행 시작 기준)
    if ! grep -q "^## 결론" "$LAST_ROUND" 2>/dev/null; then HAS_REQUIRED=0; fi
    # 통과/실패: ## 결론 다음 줄 기준
    HAS_PASS=$(grep -A1 "^## 결론" "$LAST_ROUND" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
    HAS_FAIL=$(grep -A1 "^## 결론" "$LAST_ROUND" 2>/dev/null | grep -q "^실패" && echo 1 || echo 0)
    if [ "$HAS_PASS" = "1" ] && [ "$HAS_FAIL" = "0" ] && [ "$HAS_REQUIRED" = "1" ]; then
      PASS=1
    fi
  fi

  if [ "$PASS" -lt 1 ]; then
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] round 파일이 통과해야 합니다. verifier 에이전트를 통해 검증을 완료하세요. 작업 취소하려면 state.json의 workflow_phase를 \"cancelled\"로 변경하세요.")
    }'
    exit 0
  fi
fi

exit 0
