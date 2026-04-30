#!/bin/bash
# subagent-track: SubagentStart hook
# 메인 세션이 sub-agent 스폰 시, 해당 sub-agent의 session_id를 승인 목록에 등록
# 승인된 sub-agent는 부모 task의 plan 기준으로 Write/Bash 허용

INPUT=$(cat)

# sub-agent의 session_id 추출
AGENT_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -z "$AGENT_SESSION_ID" ] && exit 0

# 부모의 활성 task 찾기: development/verification phase인 .active task 검색
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
FOUND_TASK_DIR=""

# 날짜별 구조 스캔
# 다중 세션 안전: development/verification task가 정확히 1개일 때만 등록.
# 여러 개이면 어느 세션의 task인지 알 수 없으므로 등록 안 함
# (잘못된 task 규칙 적용보다 gate 비적용이 안전)
_CANDIDATE_COUNT=0
if [ -d "$REPO_ROOT/.ai-bouncer-tasks" ]; then
  for date_dir in "$REPO_ROOT/.ai-bouncer-tasks"/*/; do
    [ -d "$date_dir" ] || continue
    for active_file in "${date_dir}"*/.active; do
      [ -f "$active_file" ] || continue
      stored_sid=$(cat "$active_file" 2>/dev/null | tr -d '[:space:]')
      [ -z "$stored_sid" ] && continue  # 아직 claim 안 된 .active는 스킵
      task_dir=$(dirname "$active_file")
      state_file="${task_dir}/state.json"
      [ -f "$state_file" ] || continue
      phase=$(jq -r '.workflow_phase // ""' "$state_file" 2>/dev/null)
      case "$phase" in
        development|verification)
          _CANDIDATE_COUNT=$((_CANDIDATE_COUNT + 1))
          FOUND_TASK_DIR="$task_dir" ;;
      esac
    done
  done
fi

# 다중 세션 감지 시 등록 안 함
if [ "$_CANDIDATE_COUNT" -gt 1 ]; then
  FOUND_TASK_DIR=""
fi

# persistent 경로도 확인 (local에서 못 찾은 경우만)
if [ -z "$FOUND_TASK_DIR" ] && [ "$_CANDIDATE_COUNT" -eq 0 ]; then
  REPO_NAME=$(basename "$REPO_ROOT" 2>/dev/null)
  PERSISTENT_BASE="$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/.ai-bouncer-tasks"
  _PERSIST_COUNT=0
  if [ -d "$PERSISTENT_BASE" ]; then
    for active_file in "$PERSISTENT_BASE"/*/.active; do
      [ -f "$active_file" ] || continue
      stored_sid=$(cat "$active_file" 2>/dev/null | tr -d '[:space:]')
      [ -z "$stored_sid" ] && continue  # 아직 claim 안 된 .active는 스킵
      task_dir=$(dirname "$active_file")
      state_file="${task_dir}/state.json"
      [ -f "$state_file" ] || continue
      phase=$(jq -r '.workflow_phase // ""' "$state_file" 2>/dev/null)
      case "$phase" in
        development|verification)
          _PERSIST_COUNT=$((_PERSIST_COUNT + 1))
          FOUND_TASK_DIR="$task_dir" ;;
      esac
    done
    [ "$_PERSIST_COUNT" -gt 1 ] && FOUND_TASK_DIR=""
  fi
fi

# 활성 development/verification task 없으면 등록 불필요
[ -z "$FOUND_TASK_DIR" ] && exit 0

# team 모드에서 team_name 없으면 등록 거부 (팀 미구성 서브에이전트 차단)
_BCFG="${REPO_ROOT}/.claude/ai-bouncer/config.json"
[ -f "$_BCFG" ] || _BCFG="${HOME}/.claude/ai-bouncer/config.json"
_AGENT_MODE=$(jq -r '.agent_mode // "team"' "$_BCFG" 2>/dev/null || echo "team")
if [ "$_AGENT_MODE" = "team" ]; then
  _DP=$(jq -r '.current_dev_phase // 0' "${FOUND_TASK_DIR}/state.json" 2>/dev/null)
  _DP=${_DP//[^0-9]/}; _DP=${_DP:-0}
  _TN=""
  if [ "$_DP" -gt 0 ]; then
    _TN=$(jq -r --argjson ph "$_DP" '.dev_phases[($ph|tostring)].team_name // ""' "${FOUND_TASK_DIR}/state.json" 2>/dev/null)
  fi
  # per-phase 미설정/빈값이면 top-level team_name 폴백
  [ -z "$_TN" ] && _TN=$(jq -r '.team_name // ""' "${FOUND_TASK_DIR}/state.json" 2>/dev/null)
  [ -z "$_TN" ] && exit 0
fi

# 승인 목록에 등록: session_id → task_dir 매핑
APPROVED_FILE="/tmp/.ai-bouncer-approved-agents"
echo "${AGENT_SESSION_ID}|${FOUND_TASK_DIR}" >> "$APPROVED_FILE"

exit 0
