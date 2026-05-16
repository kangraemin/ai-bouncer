#!/bin/bash
# completion-gate: Stop hook
# Claude가 각 응답 턴을 마칠 때 실행
# 검증 단계에서 e2e-result.md 기반으로 검증 통과 여부 확인

HOOK_NAME="completion-gate"
source "$(dirname "${BASH_SOURCE[0]}")/lib/block-logger.sh"

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

[ "$IS_MY_TASK" != "true" ] && exit 0
[ -f "$STATE_FILE" ] || exit 0

WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

# cancelled/planning/pending 상태 → 통과
case "$WORKFLOW_PHASE" in
  cancelled|planning|pending) exit 0 ;;
esac

# done 상태: e2e 검증 완료 여부 확인 (검증 없이 done 처리된 경우 차단)
if [ "$WORKFLOW_PHASE" = "done" ] && [ "$PLAN_APPROVED" = "true" ]; then
  E2E_RESULT="${TASK_DIR}/verifications/e2e-result.md"
  if [ ! -f "$E2E_RESULT" ]; then
    log_block "CG-DONE-NO-VERIFY-FILE" "⛔ 검증 없이 done 처리됨. e2e-result.md 없음."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("⛔ 검증 없이 done 처리됨. [" + $task + "] verifications/e2e-result.md가 없습니다. Phase 4에서 e2e-writer를 실행하세요.")
    }'
    exit 0
  fi
  HAS_PASS=$(grep -A1 "^## 결론" "$E2E_RESULT" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
  if [ "$HAS_PASS" != "1" ]; then
    log_block "CG-DONE-NOT-PASSED" "⛔ 검증 미통과 상태로 done 처리됨."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("⛔ 검증 미통과 상태로 done 처리됨. [" + $task + "] e2e-result.md의 \"## 결론\"이 통과여야 합니다.")
    }'
    exit 0
  fi
  exit 0
fi

# development 상태에서: 모든 phase/step ✅ 체크
if [ "$WORKFLOW_PHASE" = "development" ] && [ "$PLAN_APPROVED" = "true" ]; then
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
        # TC 실제결과 컬럼(6번째 필드)에 ✅ 없는 행 탐지 — ⏸️/❌/빈셀/임의텍스트 모두 차단
        INCOMPLETE_TC=$(awk -F'|' '/^\| TC-[0-9]/{gsub(/ /,"",$6); if ($6 !~ /✅/) print NR}' "$step_file" 2>/dev/null | head -1)
        if [ -n "$INCOMPLETE_TC" ]; then
          ALL_DONE=false
          STEP_NAME=$(basename "$step_file")
          BLOCK_REASON="Phase ${i} / ${STEP_NAME} 미완료 (TC 실제결과 컬럼에 ✅ 없는 행 존재)"
          break 2
        fi
      done
    done

    if [ "$ALL_DONE" = "false" ]; then
      log_block "CG-DEV-PHASE-STEP-INCOMPLETE" "⛔ 개발 미완료 — Phase/Step ✅ 누락."
      jq -n --arg reason "$BLOCK_REASON" --arg task "$TASK_NAME" '{
        decision: "block",
        reason: ("개발이 완료되지 않았습니다. [" + $task + "] " + $reason + ". 현재 Phase/Step을 완료 후 ✅ 표시하세요.")
      }'
      exit 0
    fi

    # 모든 step ✅ 완료 → verification 전환 강제 (current_dev_phase 값 무관)
    log_block "CG-DEV-ALL-DONE-AWAIT-VERIFY" "⛔ 모든 Phase/Step 완료 — verification 전환 필요."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("모든 Phase/Step이 완료되었습니다. [" + $task + "] state.json의 workflow_phase를 \"verification\"으로 전환하고 e2e-writer 에이전트를 실행하세요.")
    }'
    exit 0
  fi
  exit 0
fi

# 검증 단계에서만 체크
if [ "$PLAN_APPROVED" = "true" ] && [ "$WORKFLOW_PHASE" = "verification" ]; then
  E2E_RESULT="${TASK_DIR}/verifications/e2e-result.md"

  if [ ! -f "$E2E_RESULT" ]; then
    log_block "CG-VERIFY-NO-FILE" "⛔ verification 단계 — e2e-result.md 없음."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] verifications/e2e-result.md 없음. e2e-writer 에이전트를 통해 e2e 테스트를 실행하세요.")
    }'
    exit 0
  fi

  # ## 결론 섹션 + 통과 확인
  HAS_PASS=$(grep -A1 "^## 결론" "$E2E_RESULT" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
  if [ "$HAS_PASS" != "1" ]; then
    log_block "CG-VERIFY-NOT-PASSED" "⛔ verification 단계 — e2e-result.md 미통과."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] e2e-result.md가 통과해야 합니다. e2e-writer 에이전트를 통해 재실행하세요.")
    }'
    exit 0
  fi
fi

exit 0
