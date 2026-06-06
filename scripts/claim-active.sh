#!/bin/bash
# .active 파일에 현재 session_id 기록 (claim)
# 사용법: claim-active.sh <active_file_path>
ACTIVE_FILE="$1"
[ -z "$ACTIVE_FILE" ] && { echo "⚠️ ACTIVE_FILE 인자 없음" >&2; exit 1; }
# session_id 출처: 프로세스별 env(CLAUDE_CODE_SESSION_ID)를 우선 사용 — 세션 격리 보장.
# 다중 세션 동시 실행 시 전역 파일(/tmp/.ai-bouncer-current-session) 공유로 인한
# .active 오염(TOCTOU: 가장 최근 bash 돌린 세션 id가 박힘)을 방지한다.
# env 부재 시(구버전 Claude Code 등)에만 전역 파일로 폴백한다.
SESSION_ID=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -d '[:space:]')
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat /tmp/.ai-bouncer-current-session 2>/dev/null | tr -d '[:space:]')
[ -z "$SESSION_ID" ] && { echo "⚠️ session_id 없음 (CLAUDE_CODE_SESSION_ID·/tmp/.ai-bouncer-current-session 모두 비어있음)" >&2; exit 1; }
mkdir -p "$(dirname "$ACTIVE_FILE")"
echo "$SESSION_ID" > "$ACTIVE_FILE"
