#!/bin/bash
# completion-gate: Stop hook
# Claude가 각 응답 턴을 마칠 때 실행
# 검증 미완료(rounds_passed < 3) 상태에서 응답 종료 시 차단

# docs/.active 확인
ACTIVE_FILE="docs/.active"
[ -f "$ACTIVE_FILE" ] || exit 0

TASK_NAME=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')
[ -z "$TASK_NAME" ] && exit 0

STATE_FILE="docs/${TASK_NAME}/state.json"
[ -f "$STATE_FILE" ] || exit 0

WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

# 개발 승인됐고 검증 단계에서만 체크
if [ "$PLAN_APPROVED" = "true" ] && [ "$WORKFLOW_PHASE" = "verification" ]; then
  ROUNDS_PASSED=$(jq -r '.verification.rounds_passed // 0' "$STATE_FILE" 2>/dev/null)
  if [ "$ROUNDS_PASSED" -lt 3 ]; then
    jq -n --arg rounds "$ROUNDS_PASSED" --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] 3회 연속 검증 통과 필요 (현재: " + $rounds + "/3). verifier 에이전트를 통해 검증을 완료하세요.")
    }'
    exit 0
  fi
fi

exit 0
