#!/usr/bin/env bash
# ai-bouncer CLI — 스킬과 사용자가 쓰는 진입점.
#
#   bouncer init [--defaults|--decline] 이 레포에 켠다 (기본값으로 채운 workflow.yaml) / 빈 설정에 기본값 채우기 / 켜지 않는다
#   bouncer scan                      시작 전에 알아야 할 것 (이 세션의 작업, 모드, 고를 항목)
#   bouncer start <모드> <slug> [--pick <단계>=<id>,<id> ...]
#                                     작업 시작. 고르는 단계(choosable ask·auto)는 전부 --pick 으로 답해야 한다 (빈 값 = 건너뜀)
#   bouncer status                    현재 단계의 지시와 검사(run)
#   bouncer cancel                    작업 취소
#   bouncer workflows                 정의된 모드 목록
#   bouncer check                     workflow.yaml이 유효한지 검사 (아무것도 쓰지 않는다)
#   bouncer fresh <리포트>             run 스크립트용: 리포트가 없거나 작업 시작 뒤 바뀐 파일보다 오래됐으면 exit 2
#
# current_stage 는 이 CLI로 바꿀 수 없다. 전이는 Stop hook만 한다.

set -uo pipefail
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_D/lib/common.sh"

PROJECT="${BOUNCER_PROJECT:-$PWD}"
SESSION="${CLAUDE_CODE_SESSION_ID:-}"

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq가 필요하다. brew install jq"
COMPILED="$(bouncer_compiled_file "$PROJECT")"

compiled_ok() {
  [ -f "$COMPILED" ] || die "워크플로우가 컴파일되지 않았다: $COMPILED"
  jq -e . "$COMPILED" >/dev/null 2>&1 \
    || die "컴파일 결과가 손상됐다: $COMPILED
'bouncer check' 로 workflow.yaml을 확인하라. 다음 세션 시작 때 다시 컴파일된다."
}

# need_task [--mutating]
# 사람이 자기 터미널에서 칠 때는 세션 ID가 없다. 진행 중 작업이 하나뿐이면 **보여주는** 것까지는
# 해준다. 바꾸는 명령(cancel)은 열어주지 않는다 — 그 작업을 쥔 세션이 알림 없이 게이트를 잃는다.
need_task() {
  TASK="$(bouncer_my_task "$PROJECT" "$SESSION")" || TASK=""
  if [ -z "$TASK" ] && [ -z "$SESSION" ] && [ "${1:-}" != "--mutating" ]; then
    local live; live="$(ls -d "$(bouncer_tasks_dir "$PROJECT")"/*/.active 2>/dev/null)"
    if [ "$(printf '%s\n' "$live" | grep -c .)" = 1 ]; then
      TASK="$(dirname "$live")"
      printf '(세션 ID가 없어 진행 중인 작업 하나를 대상으로 한다: %s)\n' "$(basename "$TASK")" >&2
    fi
  fi
  [ -n "$TASK" ] || die "이 세션의 활성 작업이 없다.
새로 시작하려면: bouncer start <모드> <slug>"
  STAGE="$(bouncer_state "$TASK" '.current_stage')"
}

# 모드에서 고르는 단계(choosable ask·auto)마다 고를 수 있는 것: "<단계>\t<id>\t<방식>\t<label>"
# items 가 없으면 단계 자체가 하나의 선택지다 (id = 단계 이름).
choices_of() {
  jq -r --arg w "$1" '. as $c | .workflows[$w] as $wf | $wf.stages[] as $s | $wf.choosable[$s] as $m
    | select($m != "all") | $c.stages[$s]
    | if (.items | length) > 0 then .items[] | "\($s)\t\(.id)\t\($m)\t\(.label)"
      else "\($s)\t\($s)\t\($m)\t이 단계를 한다" end' "$COMPILED"
}

# ── scan ─────────────────────────────────────────────────────
# 스킬이 제일 먼저, 한 번만 호출한다.
#   STATE    MINE <dir> <모드> <단계>        이 세션이 이어서 할 작업
#   STATE    NONE
#   WORKFLOW <이름> <label>                 모드 선택지
#   CHOICE   <모드> <단계> <id> <방식> <label>  시작 전에 골라야 할 항목. 방식 ask = 사용자에게 묻는다, auto = AI 가 고른다
#   ERROR    <메시지>
cmd_scan() {
  # 엔진은 전역이라 설정 없는 레포에서도 불린다. 모드 목록이 비어 보이면 모델이 이유를 모른다.
  if [ ! -f "$(bouncer_workflow_yaml "$PROJECT")" ]; then
    printf 'ERROR\t이 레포에는 ai-bouncer 설정이 없다 — 켜려면 bouncer init (켜지 않으려면 bouncer init --decline)\n'
    return 0
  fi
  local d wf
  if d="$(bouncer_my_task "$PROJECT" "$SESSION")"; then
    printf 'STATE\tMINE\t%s\t%s\t%s\n' "$d" "$(bouncer_state "$d" '.workflow')" "$(bouncer_state "$d" '.current_stage')"
  else
    printf 'STATE\tNONE\n'
  fi
  [ -f "$COMPILED" ] || return 0
  if ! jq -e . "$COMPILED" >/dev/null 2>&1; then
    printf 'ERROR\t컴파일 결과가 손상됐다: %s — `bouncer check` 로 workflow.yaml을 확인하라.\n' "$COMPILED"
    return 0
  fi
  jq -r '.workflows | to_entries[] | "WORKFLOW\t\(.key)\t\(.value.label)"' "$COMPILED"
  for wf in $(jq -r '.workflows | keys[]' "$COMPILED"); do
    choices_of "$wf" | sed "s/^/CHOICE	$wf	/"
  done
}

# ── workflows ────────────────────────────────────────────────
cmd_workflows() {
  compiled_ok
  jq -r '.workflows | to_entries[] |
    "\(.key)\t\(.value.label)\n    " + (.value.stages | join(" → "))' "$COMPILED"
}

# ── check ────────────────────────────────────────────────────
# workflow.yaml을 고친 뒤 검증용. 컴파일만 해보고 결과 파일은 만들지 않는다.
cmd_check() {
  local y err; y="$(bouncer_workflow_yaml "$PROJECT")"
  [ -f "$y" ] || die "워크플로우 파일이 없다: $y"
  if err="$(python3 "$_D/compile.py" "$y" 2>&1 >/dev/null)"; then
    printf 'OK\t%s\n' "$y"
    python3 "$_D/compile.py" "$y" | jq -r '
      "  워크플로우: " + (.workflows | to_entries | map("\(.key) [\(.value.stages | join(" → "))]") | join("\n              "))'
  else
    printf '%s\n' "$err" >&2
    die "workflow.yaml이 유효하지 않다. 고치기 전 상태로 되돌리거나 위 오류를 수정하라."
  fi
}

# ── 시작 ─────────────────────────────────────────────────────
cmd_start() {
  local wf="${1:-}" slug="${2:-}"
  [ -n "$wf" ] && [ -n "$slug" ] || die "usage: bouncer start <모드> <slug> [--pick <단계>=<id>,...]"
  shift 2
  [ -n "$SESSION" ] || die "세션 ID를 알 수 없다 (CLAUDE_CODE_SESSION_ID 미설정)."
  compiled_ok
  [ -n "$(bouncer_chain "$PROJECT" "$wf")" ] || die "정의되지 않은 모드: $wf"
  # 한 세션이 활성 작업을 둘 가지면 hook 은 하나만 본다.
  local mine
  mine="$(bouncer_my_task "$PROJECT" "$SESSION")" && die "이 세션에 이미 진행 중인 작업이 있다: $mine
'bouncer status' 로 확인하고 이어서 하거나, 'bouncer cancel' 로 정리한 뒤 새로 시작하라."

  # 고른 결과: {단계: [id...]}. 고르는 단계는 하나도 빠짐없이 답이 있어야 한다 —
  # 고르지 않고 시작하면 사용자가 원한 검사가 빠졌는지 아무도 모른다.
  local picks='{}' stage ids id
  while [ $# -gt 0 ]; do
    case "$1" in
      --pick)
        [ $# -ge 2 ] && [[ "$2" == *=* ]] || die "--pick 은 <단계>=<id>,<id> 형식이다 (아무것도 안 하면 <단계>=)"
        stage="${2%%=*}"; ids="${2#*=}"
        picks="$(jq --arg s "$stage" --arg v "$ids" '.[$s] = ($v | split(",") | map(select(. != "")))' <<<"$picks")"
        shift 2 ;;
      *) die "알 수 없는 인자: $1" ;;
    esac
  done
  local all missing=""
  all="$(choices_of "$wf")"
  for stage in $(jq -r 'keys[]' <<<"$picks"); do
    printf '%s\n' "$all" | cut -f1 | grep -qxF "$stage" || die "'$stage' 는 모드 '$wf' 에서 고르는 단계가 아니다."
    for id in $(jq -r --arg s "$stage" '.[$s][]' <<<"$picks"); do
      printf '%s\n' "$all" | awk -F'\t' -v s="$stage" -v i="$id" '$1==s && $2==i {f=1} END {exit !f}' \
        || die "'$stage' 단계에 '$id' 항목은 없다. 고를 수 있는 것:
$(printf '%s\n' "$all" | awk -F'\t' -v s="$stage" '$1==s {print "  " $2 "  " $4}')"
    done
  done
  for stage in $(printf '%s\n' "$all" | cut -f1 | uniq); do
    jq -e --arg s "$stage" 'has($s)' <<<"$picks" >/dev/null || missing="$missing$stage "
  done
  [ -z "$missing" ] || die "고를 단계에 답이 없다: $missing
bouncer scan 의 CHOICE 줄을 보고 정한다 — 방식 ask 는 AskUserQuestion 으로 사용자에게 묻고, auto 는 작업 내용을 보고 직접 고른다. 그다음:
  bouncer start $wf \"$slug\" $(printf '%s\n' "$all" | cut -f1 | uniq | sed 's/.*/--pick &=<id>,…/' | tr '\n' ' ')
아무것도 고르지 않은 단계는 '--pick <단계>=' 로 적는다 (그 단계는 건너뛴다)."

  # 아무것도 고르지 않은 단계는 체인에서 뺀다.
  local chain
  chain="$(jq -c --arg w "$wf" --argjson p "$picks" '. as $c | [.workflows[$w].stages[]
    | select(($c.workflows[$w].choosable[.] == "all") or (($p[.] // []) | length > 0))]' "$COMPILED")"
  [ "$chain" != "[]" ] || die "고른 결과 남는 단계가 없다."

  local slug_safe task_id dir root first prompt
  first="$(jq -r '.[0]' <<<"$chain")"
  slug_safe="$(printf '%s' "$slug" | tr -cs '[:alnum:]-' '-' | sed 's/^-*//;s/-*$//')"
  # 같은 초에 같은 slug로 두 세션이 시작해도 디렉토리가 겹치지 않게 세션 성분을 넣는다.
  task_id="$(date +%Y%m%d-%H%M%S)-$(printf '%s' "$SESSION" | shasum -a 256 | cut -c1-6)-$slug_safe"
  dir="$(bouncer_tasks_dir "$PROJECT")/$task_id"
  mkdir -p "$(dirname "$dir")" && mkdir "$dir" 2>/dev/null || die "태스크 디렉토리를 만들 수 없다: $dir"

  root="$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null)"; [ -n "$root" ] || root="$PROJECT"
  jq -n --arg id "$task_id" --arg slug "$slug" --arg wf "$wf" --arg stage "$first" \
        --arg sid "$SESSION" --arg root "$root" --arg now "$(date -u +%FT%TZ)" \
        --arg sha "$(git -C "$root" rev-parse HEAD 2>/dev/null)" \
        --argjson chain "$chain" --argjson picks "$picks" '{
      task_id:$id, slug:$slug, workflow:$wf, chain:$chain, choices:$picks, current_stage:$stage,
      created_at:$now, session_id:$sid, work_root:$root, base_sha:$sha,
      shown:{}, continue_streak:0, history:[{stage:$stage, at:$now}]
    }' > "$dir/state.json" || die "state.json 생성 실패"
  jq -n --arg s "$SESSION" --arg now "$(date -u +%FT%TZ)" '{session_id:$s, claimed_at:$now}' > "$dir/.active"

  # 첫 단계 지시는 여기서 바로 준다. Stop 을 기다리면 첫 응답이 지시 없이 나간다.
  prompt="$(bouncer_stage_view "$PROJECT" "$dir" "$first" | jq -r '.prompt // ""')"
  [ -n "$prompt" ] && bouncer_state_update "$dir" --arg s "$first" '.shown[$s] = true'
  printf 'STARTED\t%s\tworkflow=%s\tchain=%s\n' "$task_id" "$wf" "$(jq -r 'join(" → ")' <<<"$chain")"
  [ -n "$prompt" ] && printf '\n%s\n' "$prompt"
  return 0
}

# ── 상태 ─────────────────────────────────────────────────────
cmd_status() {
  need_task
  jq -e . "$TASK/state.json" >/dev/null 2>&1 \
    || die "state.json이 손상됐다: $TASK/state.json
hook은 이 상태에서 작업을 진행시키지 않는다. 작업을 포기하려면: bouncer cancel"
  compiled_ok
  local sj; sj="$(bouncer_stage_view "$PROJECT" "$TASK" "$STAGE")"
  [ -n "$sj" ] \
    || die "단계 '$STAGE' 가 workflow.yaml에 없다 (작업 도중 삭제·개명된 것으로 보인다). 되돌리거나 'bouncer cancel' 로 정리하라."
  printf '작업:      %s\n모드:      %s\n체인:      %s\n현재 단계:  %s\n' \
    "$(bouncer_state "$TASK" '.task_id')" "$(bouncer_state "$TASK" '.workflow')" \
    "$(bouncer_task_chain "$TASK" | tr '\n' ' ')" "$STAGE"
  jq -r '
    (if .prompt != "" then "\n[지시]\n" + .prompt else empty end),
    (if (.run | length) > 0
     then "\n[검사] 끝내려 할 때 순서대로 돈다. 전부 exit 0 이면 다음 단계로 넘어간다\n" + (.run | map("  $ " + .) | join("\n"))
     else "\n[검사] 없음 — 끝내려 하면 다음 단계로 넘어간다" end)' <<<"$sj"
}

# ── 취소 ─────────────────────────────────────────────────────
cmd_cancel() {
  need_task --mutating
  bouncer_state_update "$TASK" --arg n "$(date -u +%FT%TZ)" \
    '.current_stage = "cancelled" | .cancelled_at = $n' \
    || printf '⚠️ state.json 이 손상돼 취소 표시를 남기지 못했다. 잠금은 해제했다.\n' >&2
  rm -f "$TASK/.active"
  printf 'CANCELLED\t%s\n' "$TASK"
}

# ── fresh ────────────────────────────────────────────────────
# run 스크립트에서 "이 리포트가 지금 코드 기준인가"를 본다. 오래 걸리는 검사는 모델이 직접 돌리고
# run 에서는 결과만 확인하는데, 고친 뒤 다시 안 돌린 옛 리포트로 통과하면 안 된다.
# 비교 대상: 작업 시작 커밋(base_sha) 이후 바뀐 파일 + 추적 안 되는 새 파일. 리포트 자신은 뺀다.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
cmd_fresh() {
  local rep="${1:-}"
  [ -n "$rep" ] || die "usage: bouncer fresh <리포트 파일>"
  [ -f "$rep" ] || { printf '리포트가 없다: %s — 검사를 돌려 만들어라.\n' "$rep"; exit 2; }
  local root base rt f self
  root="$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null)" || return 0
  base=""
  [ -n "${BOUNCER_TASK_DIR:-}" ] && base="$(bouncer_state "$BOUNCER_TASK_DIR" '.base_sha')"
  [ -n "$base" ] || base=HEAD
  rt="$(mtime "$rep")"
  self="$(cd "$(dirname "$rep")" && pwd -P)/$(basename "$rep")"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$root/$f" ] || continue
    [ "$(cd "$(dirname "$root/$f")" && pwd -P)/$(basename "$f")" = "$self" ] && continue
    if [ "$(mtime "$root/$f")" -gt "$rt" ]; then
      printf '리포트(%s)가 %s 보다 오래됐다 — 고친 뒤 검사를 다시 돌려라.\n' "$rep" "$f"
      exit 2
    fi
  done < <(git -C "$root" diff --name-only "$base" 2>/dev/null; git -C "$root" ls-files --others --exclude-standard 2>/dev/null)
  return 0
}

case "${1:-}" in
  init)      shift; exec bash "$_D/init.sh" "$@" ;;
  scan)      shift; cmd_scan "$@" ;;
  check)     shift; cmd_check "$@" ;;
  start)     shift; cmd_start "$@" ;;
  status)    shift; cmd_status "$@" ;;
  cancel)    shift; cmd_cancel "$@" ;;
  workflows) shift; cmd_workflows "$@" ;;
  fresh)     shift; cmd_fresh "$@" ;;
  ""|-h|--help|help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "알 수 없는 명령: $1" ;;
esac
