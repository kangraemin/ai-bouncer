#!/usr/bin/env bash
# ai-bouncer 공용 라이브러리 — 경로 해석, 상태 접근.
# hook과 CLI가 모두 source한다. 런타임 의존성은 jq 하나.

set -uo pipefail

# ── 경로 ─────────────────────────────────────────────────────
# 엔진·훅은 이 컴퓨터에 한 벌(~/.claude/ai-bouncer)이고, 레포에는 설정만 둔다.
# 레포마다 워크플로우가 다른 건 workflow.yaml(기본값 위 override)로 표현한다.
# workflow.yaml 이 없는 레포에서는 훅이 아무것도 하지 않는다.
#
#   ~/.claude/ai-bouncer/            엔진 + 훅 (전역)
#   <프로젝트>/.claude/ai-bouncer/   설정 (workflow.yaml)
#   <프로젝트>/.ai-bouncer/          런타임 상태 (state.json, .active)
# 설정 지점을 현재 위치에서 위로 올라가며 찾는다. 하위 디렉토리에서 실행해도 같은 작업을 본다.
bouncer_project_root() {
  local d="${1:-$PWD}"
  d="$(cd "$d" 2>/dev/null && pwd)" || { printf '%s' "${1:-$PWD}"; return; }
  while [ "$d" != "/" ]; do
    [ -f "$d/.claude/ai-bouncer/workflow.yaml" ] && { printf '%s' "$d"; return; }
    d="$(dirname "$d")"
  done
  # 설치를 못 찾으면 git 루트, 그것도 없으면 준 경로 그대로
  d="$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
    && { printf '%s' "$d"; return; }
  printf '%s' "${1:-$PWD}"
}
bouncer_workflow_yaml() { printf '%s/.claude/ai-bouncer/workflow.yaml'      "$(bouncer_project_root "${1:-$PWD}")"; }
bouncer_compiled_file() { printf '%s/.claude/ai-bouncer/workflow.compiled.json' "$(bouncer_project_root "${1:-$PWD}")"; }
bouncer_tasks_dir()     { printf '%s/.ai-bouncer/tasks'                     "$(bouncer_project_root "${1:-$PWD}")"; }

# 설치 목록·거절 목록이 사는 곳.
bouncer_registry_dir() { printf '%s' "${BOUNCER_REGISTRY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ai-bouncer}"; }
# 사용자가 "이 레포엔 켜지 않는다"고 답했는가. 답한 레포는 세션 시작 때 다시 묻지 않는다.
bouncer_init_declined() {
  local f; f="$(bouncer_registry_dir)/declined"
  [ -f "$f" ] && grep -qxF "$1" "$f"
}
# 이 세션이 프로젝트 settings 의 옛 로컬 훅도 같이 부르고 있으면(전역 설치 뒤, bouncer init 전) 그쪽에 맡긴다.
# 둘 다 돌면 차단 문구·도구 카운트가 두 번씩 난다. 로컬 훅이 전역으로 넘겨준 호출(BOUNCER_FORWARDED)은 처리한다.
bouncer_defer_to_local() {
  [ -n "${BOUNCER_FORWARDED:-}" ] && return 1
  local root lh; root="$(bouncer_project_root "$1")"; lh="$root/.claude/ai-bouncer/hooks"
  [ -f "$lh/$(basename "$2")" ] || return 1
  [ "$(cd "$lh" && pwd -P)" != "$(cd "$(dirname "$2")" && pwd -P)" ] || return 1
  grep -qs '/\.claude/ai-bouncer/hooks/' "$root/.claude/settings.json" "$root/.claude/settings.local.json"
}

# ── 활성 태스크 ──────────────────────────────────────────────
# 세션이 연 폴더와 작업을 시작한 레포가 다를 수 있다 (my-sns 에서 열고 `cd mukmap && bouncer start`).
# hook 은 세션 폴더 기준으로만 찾았어서, 그런 작업은 Stop 이 못 보고 구현 단계에서 그냥 멈췄다.
# 그래서 start 가 세션별 표지(작업 경로)를 남기고, 폴더에서 못 찾으면 표지를 본다.
bouncer_session_mark() {
  case "$1" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s/sessions/%s' "$(bouncer_registry_dir)" "$1"
}
# 작업 디렉토리(<레포>/.ai-bouncer/tasks/<id>)의 레포 루트
bouncer_task_root() { printf '%s' "${1%/.ai-bouncer/tasks/*}"; }

# 이 세션이 소유한 .active만 찾는다. 남의 것은 읽지도 건드리지도 않는다.
bouncer_my_task() {
  local project="${1:-$PWD}" session="${2:-}" tasks active owner mark
  [ -n "$session" ] || return 1
  tasks="$(bouncer_tasks_dir "$project")"
  for active in "$tasks"/*/.active; do
    [ -f "$active" ] || continue
    owner="$(jq -r '.session_id // empty' "$active" 2>/dev/null)"
    if [ "$owner" = "$session" ]; then dirname "$active"; return 0; fi
  done
  # 표지는 가리키는 곳의 .active 가 여전히 이 세션 것일 때만 믿는다. 끝났거나 남의 것이면 무시한다.
  mark="$(bouncer_session_mark "$session")" && [ -f "$mark" ] || return 1
  active="$(cat "$mark")/.active"
  [ -f "$active" ] && [ "$(jq -r '.session_id // empty' "$active" 2>/dev/null)" = "$session" ] || return 1
  dirname "$active"
}

# ── state.json ───────────────────────────────────────────────
bouncer_state() { jq -r "${2} // empty" "$1/state.json" 2>/dev/null; }

# 실패하면 원본을 건드리지 않고 1을 반환한다. 호출부는 반환값을 확인해야 한다.
#
# tmp+mv 는 교체를 원자적으로 만들지만 read-modify-write 전체를 직렬화하지는 않는다.
# 동시에 여러 프로세스가 각자 읽고 자기 키만 얹어 쓰면 마지막 것만 남는다(lost update).
# mkdir 은 원자적이라 그것으로 짧은 임계구역을 만든다.
bouncer_state_update() {
  local dir="$1"; shift
  local f="$dir/state.json" lock="$dir/.lock" tmp="$dir/.state.$$.tmp"
  [ -f "$f" ] || return 1

  local i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i+1))
    # 잠금을 쥔 프로세스가 죽었을 수 있다. 오래된 것은 걷어낸다.
    if [ "$i" -gt 50 ]; then
      local age
      age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0) ))
      [ "$age" -gt 30 ] && rm -rf "$lock" || return 1
    fi
    sleep 0.02
  done

  local rc=0
  if jq "$@" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; rc=1
  fi
  rmdir "$lock" 2>/dev/null
  return $rc
}

# ── 워크플로우 정의 ──────────────────────────────────────────
bouncer_chain()  { jq -r --arg w "$2" '.workflows[$w].stages[]? // empty' "$(bouncer_compiled_file "$1")" 2>/dev/null; }
bouncer_next_stage() {
  jq -r --arg c "$2" '(.chain // []) as $st | ($st | index($c)) as $i
    | if $i == null then "" else ($st[$i+1] // "") end' "$1/state.json" 2>/dev/null
}
bouncer_is_last_stage() {
  jq -e --arg c "$2" '(.chain // []) | (index($c) != null and index($c) == (length - 1))' "$1/state.json" >/dev/null 2>&1
}
# 이 작업에서 실제로 적용할 단계 내용 {prompt, run}. 시작할 때 고른 단계(state.choices 에 있는 단계)면 고른 항목만 넣는다.
# 지시 끝에는 엔진이 "이 단계만 하고 끝내라"를 붙인다. 레포가 prompt 를 덮어써도 빠지지 않게 여기서 붙인다.
# 없으면 모델이 다음 단계 일을 미리 꺼내거나("이제 리뷰합니다") 한 응답에 몰아 한다.
BOUNCER_STAGE_TAIL='이 단계 일만 한다. 다음 단계 일은 미리 하거나 예고하지 않는다. 마치면 응답을 끝낸다 — 끝내면 엔진이 검사하고 다음 지시를 준다.'
BOUNCER_LAST_TAIL='마지막 단계다. 마치면 응답을 끝낸다 — 끝내면 엔진이 검사하고 작업을 닫는다.'
bouncer_stage_view() {
  jq -c --arg s "$3" --slurpfile st "$2/state.json" --arg tail "$BOUNCER_STAGE_TAIL" --arg last "$BOUNCER_LAST_TAIL" '
    .stages[$s] // empty | . as $x
    | ($x.items | if ($st[0].choices // {} | has($s)) then map(select(.id as $i | $st[0].choices[$s] | index($i))) else . end) as $it
    | ([$x.prompt] + ($it | map(.prompt)) | map(select(. != "")) | join("\n\n")) as $p
    | (if ($st[0].chain // [] | last) == $s then $last else $tail end) as $t
    | {prompt: (if $p == "" then "" else $p + "\n\n" + $t end),
       run: ($x.run + ([$it[].run[]]))}' "$(bouncer_compiled_file "$1")" 2>/dev/null
}

# timeout 명령이 없는 맥에서도 쓸 수 있게 직접 감시한다. 시간을 넘기면 124.
bouncer_run_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$((secs * 5))" ]; then
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null; return 124
    fi
    sleep 0.2; waited=$((waited + 1))
  done
  wait "$pid"
}

# ── hook 출력 ────────────────────────────────────────────────
bouncer_block()   { jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }   # PreToolUse 차단 / Stop 계속
