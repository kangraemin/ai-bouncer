#!/bin/bash
# stop-active-cleanup: Stop hook
# 각 응답 종료 시, 현재 세션의 .active 중 state=done인 것을 자동 정리.
# Phase S3/4에서 rm .active가 실패한 경우의 안전망.

INPUT=$(cat)
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
cd "$REPO_ROOT" || exit 0

[ -d "docs" ] || exit 0

# docs/*/*/.active 스캔 (날짜별 구조)
find docs -mindepth 3 -maxdepth 3 -name ".active" 2>/dev/null | while read -r active_file; do
  stored_sid=$(cat "$active_file" 2>/dev/null | tr -d '[:space:]')
  # 현재 세션 것만 처리
  [ "$stored_sid" = "$SESSION_ID" ] || continue

  task_dir=$(dirname "$active_file")
  state_file="${task_dir}/state.json"
  [ -f "$state_file" ] || continue

  phase=$(jq -r '.workflow_phase // ""' "$state_file" 2>/dev/null)
  if [ "$phase" = "done" ]; then
    rm -f "$active_file"
  fi
done

exit 0
