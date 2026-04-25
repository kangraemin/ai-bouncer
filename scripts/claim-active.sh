#!/bin/bash
# .active 파일에 현재 session_id 기록 (claim)
# 사용법: claim-active.sh <active_file_path>
ACTIVE_FILE="$1"
[ -z "$ACTIVE_FILE" ] && { echo "⚠️ ACTIVE_FILE 인자 없음" >&2; exit 1; }
SESSION_ID=$(cat /tmp/.ai-bouncer-current-session 2>/dev/null | tr -d '[:space:]')
[ -z "$SESSION_ID" ] && { echo "⚠️ session_id 없음 (/tmp/.ai-bouncer-current-session 없거나 비어있음)" >&2; exit 1; }
mkdir -p "$(dirname "$ACTIVE_FILE")"
echo "$SESSION_ID" > "$ACTIVE_FILE"
