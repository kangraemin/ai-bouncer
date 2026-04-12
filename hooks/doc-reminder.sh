#!/bin/bash
# doc-reminder: PostToolUse hook
# Write/Edit 완료 후 .ai-bouncer-tasks/ 문서 업데이트 여부 경고

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

# FILE_PATH 조기 추출 (.active 처리에 resolve-task.sh 불필요)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')

# .active 파일: Write 즉시 SESSION_ID 기록 (중복 방지 포함)
if [[ "$FILE_PATH" == */.active ]] && [ -n "$SESSION_ID" ]; then
  _dup=false
  for _af in .ai-bouncer-tasks/*/*/.active; do
    [ -f "$_af" ] || continue
    [ "$_af" = "$FILE_PATH" ] && continue
    [ "$(cat "$_af" 2>/dev/null | tr -d '[:space:]')" = "$SESSION_ID" ] && { _dup=true; break; }
  done
  [ "$_dup" = "false" ] && echo "$SESSION_ID" > "$FILE_PATH"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"
[ -z "$TASK_NAME" ] && exit 0
[ -f "$STATE_FILE" ] || exit 0

WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)

# development 단계에서만 체크
[ "$WORKFLOW_PHASE" != "development" ] && exit 0

# .ai-bouncer-tasks/ 경로 수정은 건너뜀
[[ "$FILE_PATH" == .ai-bouncer-tasks/* || "$FILE_PATH" == */.ai-bouncer-tasks/* ]] && exit 0
[[ "$FILE_PATH" == *.md ]] && exit 0

# 현재 step 문서 경로 찾기
CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)

if [ "$CURRENT_DEV_PHASE" -gt 0 ] && [ "$CURRENT_STEP" -gt 0 ]; then
  DOC_PATH=$(jq -r ".dev_phases[\"$CURRENT_DEV_PHASE\"].steps[\"$CURRENT_STEP\"].doc_path // \"\"" "$STATE_FILE" 2>/dev/null)

  if [ -n "$DOC_PATH" ]; then
    # 문서 파일의 최근 수정 시간 확인
    if [ ! -f "$DOC_PATH" ]; then
      jq -n --arg doc "$DOC_PATH" '{
        decision: "block",
        reason: ("Step 문서가 없습니다. 먼저 문서를 작성한 후 코드를 수정하세요: " + $doc)
      }'
    fi
  fi
fi

exit 0
