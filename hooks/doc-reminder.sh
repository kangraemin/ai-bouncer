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

exit 0
