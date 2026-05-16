#!/bin/bash
# block-logger: ai-bouncer hook 차단 이벤트를 한 줄 JSONL로 영속 기록한다.
# 호출자는 source 전에 HOOK_NAME 환경변수를 설정한다.
# 실패해도 hook 정상 흐름을 깨지 않도록 모든 에러를 흡수한다.

log_block() {
  local code="$1"
  local reason="$2"
  local hook="${HOOK_NAME:-unknown}"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local proj="${CLAUDE_PROJECT_DIR:-$PWD}"
  local logfile="${HOME}/.claude/ai-bouncer-blocks.log"
  mkdir -p "${HOME}/.claude" 2>/dev/null || true
  jq -nc \
    --arg ts "$ts" \
    --arg hook "$hook" \
    --arg code "$code" \
    --arg proj "$proj" \
    --arg reason "$reason" \
    '{ts:$ts, hook:$hook, code:$code, project:$proj, reason:$reason}' \
    >> "$logfile" 2>/dev/null || true
}
