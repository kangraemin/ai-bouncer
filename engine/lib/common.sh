#!/usr/bin/env bash
# ai-bouncer 공용 라이브러리 — 경로 해석, 상태 접근.
# hook과 CLI가 모두 source한다. 런타임 의존성은 jq 하나.

set -uo pipefail

BOUNCER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOUNCER_ROOT="$(cd "$BOUNCER_LIB_DIR/../.." && pwd)"

# ── 경로 ─────────────────────────────────────────────────────
# 설치는 프로젝트별로만 한다. 전역 설치는 없다 —
# 레포마다 워크플로우가 다른 게 정상이고, 전역을 두면 "어느 설정이 이겼나"를
# 매번 따져야 한다. 필요해지면 그때 더한다.
#
#   <프로젝트>/.claude/ai-bouncer/   설정 + 엔진 (workflow.yaml, hooks, engine)
#   <프로젝트>/.ai-bouncer/          런타임 상태 (state.json, .active)
bouncer_data_dir()      { printf '%s/.claude/ai-bouncer'                    "${1:-$PWD}"; }
bouncer_workflow_yaml() { printf '%s/.claude/ai-bouncer/workflow.yaml'      "${1:-$PWD}"; }
bouncer_compiled_file() { printf '%s/.claude/ai-bouncer/workflow.compiled.json' "${1:-$PWD}"; }
bouncer_tasks_dir()     { printf '%s/.ai-bouncer/tasks'                     "${1:-$PWD}"; }

# 설정은 workflow.yaml의 settings 섹션에 있고, 컴파일되어 compiled.json에 들어간다.
# 별도 config 파일은 없다.
bouncer_config() {
  local key="$1" default="${2:-}" project="${3:-$PWD}" f val
  f="$(bouncer_compiled_file "$project")"
  [ -f "$f" ] || { printf '%s' "$default"; return; }
  val="$(jq -r --arg k "$key" '.settings[$k] // empty' "$f" 2>/dev/null)"
  [ -n "${val:-}" ] && printf '%s' "$val" || printf '%s' "$default"
}

# ── 활성 태스크 ──────────────────────────────────────────────
# 이 세션이 소유한 .active만 찾는다. 남의 것은 읽지도 건드리지도 않는다.
bouncer_my_task() {
  local project="${1:-$PWD}" session="${2:-}" tasks active owner
  [ -n "$session" ] || return 1
  tasks="$(bouncer_tasks_dir "$project")"
  [ -d "$tasks" ] || return 1
  for active in "$tasks"/*/.active; do
    [ -f "$active" ] || continue
    owner="$(jq -r '.session_id // empty' "$active" 2>/dev/null)"
    if [ "$owner" = "$session" ]; then dirname "$active"; return 0; fi
  done
  return 1
}

# lock의 나이(초). 하트비트는 Stop hook이 갱신한다.
# CLI는 곧바로 종료되므로 pid로 생존을 판정할 수 없다 — 그래서 시간 기반이다.
# 시각을 읽을 수 없는 락은 "방금 갱신됨"이 아니라 "손상됨"이다.
# 0을 돌려주면 12시간 정리에 영원히 안 걸려 좀비 락이 된다.
# 파일 수정 시각으로 대체하고, 그것도 안 되면 아주 오래된 것으로 취급한다.
bouncer_lock_age() {
  local seen now t
  now=$(date -u +%s)
  seen="$(jq -r '.seen_at // .claimed_at // empty' "$1" 2>/dev/null)"
  if [ -n "$seen" ]; then
    t=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$seen" +%s 2>/dev/null) \
      || t=$(date -u -d "$seen" +%s 2>/dev/null) || t=""
  fi
  if [ -z "${t:-}" ]; then
    t=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || t=0
  fi
  # 미래 시각이면 시계가 어긋난 것 — 음수 대신 0으로 눕힌다
  local age=$(( now - t )); [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

# 읽을 수 없는(손상된) 락인지 — 소유자 판별이 안 되면 아무도 해제할 수 없다
bouncer_lock_broken() {
  jq -e '.session_id|strings' "$1" >/dev/null 2>&1 && return 1 || return 0
}

bouncer_touch_lock() {
  # tmp 이름을 공유하면 동시에 도는 프로세스끼리 서로의 임시 파일을 mv 해
  # 원본이 빈 파일로 바뀐다. 프로세스별로 다른 이름을 쓴다.
  local f="$1/.active" tmp="$1/.active.$$.tmp"
  [ -f "$f" ] || return 0
  if jq --arg t "$(date -u +%FT%TZ)" '.seen_at = $t' "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# 세션 무관하게 존재하는 모든 lock (충돌 안내용).
bouncer_live_locks() {
  local tasks active
  tasks="$(bouncer_tasks_dir "${1:-$PWD}")"
  [ -d "$tasks" ] || return 0
  for active in "$tasks"/*/.active; do
    [ -f "$active" ] && dirname "$active"
  done
}

# ── state.json ───────────────────────────────────────────────
bouncer_state() { jq -r "${2} // empty" "$1/state.json" 2>/dev/null; }

# 실패하면 원본을 건드리지 않고 1을 반환한다. 호출부는 반환값을 확인해야 한다.
bouncer_state_update() {
  local dir="$1"; shift
  local f="$dir/state.json" tmp="$dir/.state.$$.tmp"
  [ -f "$f" ] || return 1
  if jq "$@" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

# ── 워크플로우 정의 ──────────────────────────────────────────
bouncer_stage()  { jq -c --arg s "$2" '.stages[$s] // empty' "$(bouncer_compiled_file "$1")" 2>/dev/null; }
bouncer_chain()  { jq -r --arg w "$2" '.workflows[$w].stages[]? // empty' "$(bouncer_compiled_file "$1")" 2>/dev/null; }
bouncer_next_stage() {
  jq -r --arg w "$2" --arg c "$3" '
    (.workflows[$w].stages // []) as $st
    | ($st | index($c)) as $i
    | if $i == null then "" else ($st[$i+1] // "") end
  ' "$(bouncer_compiled_file "$1")" 2>/dev/null
}
bouncer_is_last_stage() {
  jq -e --arg w "$2" --arg c "$3" '
    (.workflows[$w].stages // []) | (index($c) != null and index($c) == (length - 1))
  ' "$(bouncer_compiled_file "$1")" >/dev/null 2>&1
}

# ── hook 출력 ────────────────────────────────────────────────
bouncer_block()   { jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }   # PreToolUse 차단 / Stop 계속
bouncer_notice()  { jq -n --arg c "$1" '{hookSpecificOutput:{additionalContext:$c}}'; exit 0; }
