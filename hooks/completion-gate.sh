#!/bin/bash
# completion-gate: Stop hook
# Claude가 각 응답 턴을 마칠 때 실행
# 검증 단계에서 round-*.md 아티팩트 기반으로 3회 연속 통과 여부 검증

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

# cancelled/done/development 상태 → 통과
# development: plan-gate가 step 단위 강제, context restore가 재개 담당
# 어떤 모드/팀 구성이든 development에서는 block하지 않음 (다른 stop hook과 충돌 방지)
case "$WORKFLOW_PHASE" in
  cancelled|done|development|planning|pending) exit 0 ;;
esac

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
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] 3회 연속 검증 통과 필요 (현재 round 파일: " + $rounds + "개). verifier 에이전트를 통해 검증을 완료하세요. 작업 취소하려면 state.json의 workflow_phase를 \"cancelled\"로 변경하세요.")
    }'
    exit 0
  fi

  # 마지막 3개 round 파일 체크: "통과" 포함 + "실패" 미포함
  LAST_3=$(echo "$ROUND_FILES" | tail -3)
  CONSECUTIVE_PASS=0

  while IFS= read -r rfile; do
    [ -z "$rfile" ] && continue
    ROUND_NUM=$(basename "$rfile" | grep -o '[0-9]*')
    HAS_REQUIRED=1
    # 공통: ## 결론 섹션 필수 (행 시작 기준)
    if ! grep -q "^## 결론" "$rfile" 2>/dev/null; then HAS_REQUIRED=0; fi
    # Round 2 추가: ## 발견된 이슈 섹션 + 최소 내용 필요
    if [ "$ROUND_NUM" = "2" ] && [ "$HAS_REQUIRED" = "1" ]; then
      if ! grep -q "^## 발견된 이슈" "$rfile" 2>/dev/null; then HAS_REQUIRED=0; fi
      ISSUES_CONTENT=$(grep -A3 "^## 발견된 이슈" "$rfile" 2>/dev/null | tail -3)
      if [ -z "$(echo "$ISSUES_CONTENT" | tr -d '[:space:]')" ]; then HAS_REQUIRED=0; fi
    fi
    # 통과/실패: ## 결론 다음 줄 기준
    HAS_PASS=$(grep -A1 "^## 결론" "$rfile" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
    HAS_FAIL=$(grep -A1 "^## 결론" "$rfile" 2>/dev/null | grep -q "^실패" && echo 1 || echo 0)
    if [ "$HAS_PASS" = "1" ] && [ "$HAS_FAIL" = "0" ] && [ "$HAS_REQUIRED" = "1" ]; then
      CONSECUTIVE_PASS=$((CONSECUTIVE_PASS + 1))
    else
      CONSECUTIVE_PASS=0
    fi
  done <<< "$LAST_3"

  if [ "$CONSECUTIVE_PASS" -lt 3 ]; then
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] 마지막 3회 연속 round가 모두 통과해야 합니다. verifier 에이전트를 통해 검증을 완료하세요. 작업 취소하려면 state.json의 workflow_phase를 \"cancelled\"로 변경하세요.")
    }'
    exit 0
  fi
fi

exit 0
