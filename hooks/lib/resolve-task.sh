#!/bin/bash
# resolve-task: 공유 라이브러리
# 소싱 후 TASK_NAME, DOCS_BASE, TASK_DIR, STATE_FILE 설정
#
# 사용법: 호출 전 SESSION_ID 환경변수 설정 (hook stdin에서 추출)
# SESSION_ID가 있으면 해당 세션의 태스크만 매칭
# SESSION_ID가 없으면 첫 번째 활성 태스크 사용 (하위 호환)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
REPO_NAME=$(basename "$REPO_ROOT" 2>/dev/null)

TASK_NAME=""
DOCS_BASE=""
TASK_DIR=""
STATE_FILE=""

# .active 파일 스캔: base 디렉토리 아래 */.active 찾아 session_id 매칭
_resolve_from_base() {
  local base="$1"
  [ -d "$base" ] || return 1

  local found_unclaimed_task=""
  local found_unclaimed_base=""

  for active_file in "$base"/*/.active; do
    [ -f "$active_file" ] || continue
    local stored_sid
    stored_sid=$(cat "$active_file" 2>/dev/null | tr -d '[:space:]')
    local task_folder
    task_folder=$(basename "$(dirname "$active_file")")

    # state.json 존재 확인
    local state_file="${base}/${task_folder}/state.json"
    [ -f "$state_file" ] || continue

    # SESSION_ID가 없으면 첫 번째 활성 태스크 사용
    if [ -z "$SESSION_ID" ]; then
      TASK_NAME="$task_folder"
      DOCS_BASE="$base"
      return 0
    fi

    # SESSION_ID 매칭
    if [ "$stored_sid" = "$SESSION_ID" ]; then
      TASK_NAME="$task_folder"
      DOCS_BASE="$base"
      return 0
    fi

    # 다른 세션의 태스크 → stale 여부 확인
    if [ -n "$stored_sid" ] && [ "$stored_sid" != "$SESSION_ID" ]; then
      local phase
      phase=$(jq -r '.workflow_phase // ""' "$state_file" 2>/dev/null)
      local approved
      approved=$(jq -r '.plan_approved // false' "$state_file" 2>/dev/null)
      # 미승인 planning 태스크 → stale, .active 삭제하여 자동 정리
      if [ "$phase" = "planning" ] && [ "$approved" != "true" ]; then
        rm -f "$active_file"
        continue
      fi
    fi

    # 미클레임 태스크 (빈 .active) 기록
    if [ -z "$stored_sid" ] && [ -z "$found_unclaimed_task" ]; then
      found_unclaimed_task="$task_folder"
      found_unclaimed_base="$base"
    fi
  done

  # 매칭 실패 + 미클레임 태스크 있음 → claim
  if [ -n "$found_unclaimed_task" ] && [ -n "$SESSION_ID" ]; then
    echo "$SESSION_ID" > "${found_unclaimed_base}/${found_unclaimed_task}/.active"
    TASK_NAME="$found_unclaimed_task"
    DOCS_BASE="$found_unclaimed_base"
    return 0
  fi

  return 1
}

# 날짜별 구조 스캔: docs/YYYY-MM-DD/ 하위 각 디렉토리에서 _resolve_from_base 호출
_resolve_date_dirs() {
  local root="$1"
  [ -d "$root" ] || return 1

  for date_dir in "$root"/*/; do
    [ -d "$date_dir" ] || continue
    _resolve_from_base "$date_dir" && return 0
  done

  return 1
}

# 1. persistent dir (worktree용)
PERSISTENT_BASE="$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs"
_resolve_from_base "$PERSISTENT_BASE"

# 2. local docs/ — 날짜별 구조 (docs/YYYY-MM-DD/task-name/.active)
if [ -z "$TASK_NAME" ]; then
  _resolve_date_dirs "docs"
fi

# 3. fallback: 기존 flat 구조 (docs/task-name/.active — 하위 호환)
if [ -z "$TASK_NAME" ]; then
  _resolve_from_base "docs"
fi

# 결과 설정
if [ -n "$TASK_NAME" ]; then
  TASK_DIR="${DOCS_BASE}/${TASK_NAME}"
  STATE_FILE="${TASK_DIR}/state.json"
fi
