#!/bin/bash
# --- ai-bouncer start ---
# ai-bouncer NORMAL 모드 팀 작업 중이면 미커밋 체크 스킵
# stdin을 먼저 읽고, 절대경로로 체크 후, 원본 스크립트에 stdin 재주입
_bouncer_stdin=$(cat)
_bouncer_cwd=$(echo "$_bouncer_stdin" | jq -r '.cwd' 2>/dev/null)
if [ -n "$_bouncer_cwd" ] && { [ -f "$_bouncer_cwd/.claude/ai-bouncer/config.json" ] || [ -f "$HOME/.claude/ai-bouncer/config.json" ]; }; then
  for _bouncer_active in "$_bouncer_cwd"/.ai-bouncer-tasks/*/*/.active "$_bouncer_cwd"/.ai-bouncer-tasks/*/.active; do
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
