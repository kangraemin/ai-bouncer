#!/bin/bash
# --- ai-bouncer start ---
# ai-bouncer NORMAL 모드 팀 작업 중이면 미커밋 체크 스킵
# stdin을 먼저 읽고, 절대경로로 체크 후, 원본 스크립트에 stdin 재주입
_bouncer_stdin=$(cat)
_bouncer_cwd=$(echo "$_bouncer_stdin" | jq -r '.cwd' 2>/dev/null)
if [ -n "$_bouncer_cwd" ] && [ -f "$_bouncer_cwd/.claude/ai-bouncer/config.json" ]; then
  for _bouncer_active in "$_bouncer_cwd"/docs/*/*/.active "$_bouncer_cwd"/docs/*/.active; do
    [ -f "$_bouncer_active" ] || continue
    _bouncer_state="$(dirname "$_bouncer_active")/state.json"
    [ -f "$_bouncer_state" ] || continue
    _bouncer_mode=$(jq -r '.mode // "simple"' "$_bouncer_state" 2>/dev/null)
    [ "$_bouncer_mode" != "normal" ] && continue
    _bouncer_wf=$(jq -r '.workflow_phase // "done"' "$_bouncer_state" 2>/dev/null)
    case "$_bouncer_wf" in
      development|verification)
        exit 0 ;;
    esac
  done
fi
exec <<< "$_bouncer_stdin"
# --- ai-bouncer end ---
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
