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

# docs/.active에서 현재 작업 이름 찾기
ACTIVE_FILE="docs/.active"
if [ ! -f "$ACTIVE_FILE" ]; then
  # .active 없으면 ai-bouncer 미실행 환경 → 통과
  exit 0
fi

TASK_NAME=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$TASK_NAME" ]; then
  exit 0
fi

STATE_FILE="docs/${TASK_NAME}/state.json"

# state.json 없으면 통과 (ai-bouncer 미설치 환경)
[ -f "$STATE_FILE" ] || exit 0

# workflow_phase 체크
WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)

# plan.md는 planning 단계에도 항상 허용 (planner-lead가 작성해야 함)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
if [[ "$FILE_PATH" == */plan.md ]]; then
  exit 0
fi

# step/phase doc 파일은 항상 허용 (Lead 뼈대 생성, QA TC 채우기 시 test_defined=false여도 허용)
if [[ "$FILE_PATH" == */step-*.md ]] || [[ "$FILE_PATH" == */phase-*.md ]]; then
  exit 0
fi

if [ "$WORKFLOW_PHASE" = "planning" ]; then
  jq -n '{
    decision: "block",
    reason: "Planning 단계입니다. Q&A가 완료되고 계획이 승인된 후 개발을 시작하세요."
  }'
  exit 0
fi

# plan_approved 체크
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

if [ "$PLAN_APPROVED" != "true" ]; then
  jq -n '{
    decision: "block",
    reason: "계획이 승인되지 않았습니다. /dev-bounce로 계획을 수립하고 승인 후 개발을 시작하세요."
  }'
  exit 0
fi

# Lead 에이전트 스폰 여부 체크
TEAM_SPAWNED=$(jq -r '.team_spawned // false' "$STATE_FILE" 2>/dev/null)

if [ "$WORKFLOW_PHASE" = "development" ] && [ "$TEAM_SPAWNED" != "true" ]; then
  jq -n '{
    decision: "block",
    reason: "Lead 에이전트가 스폰되지 않았습니다. Phase 3-1을 따라 Lead 에이전트를 먼저 스폰하고 state.json team_spawned를 true로 설정하세요."
  }'
  exit 0
fi

# 현재 dev_phase와 step 체크
CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)

if [ "$CURRENT_DEV_PHASE" -gt 0 ] && [ "$CURRENT_STEP" -gt 0 ]; then
  DEV_PHASE_KEY="$CURRENT_DEV_PHASE"
  STEP_KEY="$CURRENT_STEP"

  # 이전 step 테스트 통과 여부 체크
  PREV_STEP=$((CURRENT_STEP - 1))
  if [ "$PREV_STEP" -gt 0 ]; then
    PREV_PASSED=$(jq -r ".dev_phases[\"$DEV_PHASE_KEY\"].steps[\"$PREV_STEP\"].passed // false" "$STATE_FILE" 2>/dev/null)
    if [ "$PREV_PASSED" != "true" ]; then
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
        decision: "block",
        reason: ("Dev Phase " + $phase + " Step " + $step + " 테스트가 통과되지 않았습니다. 테스트를 먼저 통과시킨 후 진행하세요.")
      }'
      exit 0
    fi
  fi

  # 현재 step 테스트 정의 체크
  TEST_DEFINED=$(jq -r ".dev_phases[\"$DEV_PHASE_KEY\"].steps[\"$STEP_KEY\"].test_defined // false" "$STATE_FILE" 2>/dev/null)
  if [ "$TEST_DEFINED" != "true" ]; then
    jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
      decision: "block",
      reason: ("Dev Phase " + $phase + " Step " + $step + " 의 테스트 기준이 정의되지 않았습니다. QA가 테스트를 먼저 작성해야 합니다.")
    }'
    exit 0
  fi
fi

# --- ai-bouncer end ---

exit 0
