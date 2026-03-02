#!/bin/bash
# plan-gate: PreToolUse hook
# Write/Edit 시도 전 plan_approved 상태 체크, 미승인 시 차단

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Write/Edit/MultiEdit 계열만 체크
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# --- ai-bouncer start ---
STATE_FILE="$HOME/.claude/ai-bouncer/state.json"

# state.json 없으면 통과 (ai-bouncer 미설치 환경)
[ -f "$STATE_FILE" ] || exit 0

# plan_approved 체크
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

if [ "$PLAN_APPROVED" != "true" ]; then
  jq -n '{
    decision: "block",
    reason: "계획이 승인되지 않았습니다. /dev로 계획을 수립하고 승인 후 개발을 시작하세요."
  }'
  exit 0
fi

# current_step 체크
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)

if [ "$CURRENT_STEP" -gt 0 ]; then
  # 이전 step 테스트 통과 여부 체크
  PREV_STEP=$((CURRENT_STEP - 1))
  if [ "$PREV_STEP" -gt 0 ]; then
    PREV_PASSED=$(jq -r ".steps[\"$PREV_STEP\"].passed // false" "$STATE_FILE" 2>/dev/null)
    if [ "$PREV_PASSED" != "true" ]; then
      jq -n --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Step " + $step + " 테스트가 통과되지 않았습니다. 테스트를 먼저 통과시킨 후 진행하세요.")
      }'
      exit 0
    fi
  fi

  # 현재 step 테스트 정의 체크
  TEST_DEFINED=$(jq -r ".steps[\"$CURRENT_STEP\"].test_defined // false" "$STATE_FILE" 2>/dev/null)
  if [ "$TEST_DEFINED" != "true" ]; then
    jq -n --arg step "$CURRENT_STEP" '{
      decision: "block",
      reason: ("Step " + $step + " 의 테스트 기준이 정의되지 않았습니다. QA가 테스트를 먼저 작성해야 합니다.")
    }'
    exit 0
  fi
fi
# --- ai-bouncer end ---

exit 0
