#!/usr/bin/env bash
# ai-bouncer CLI — 스킬과 사용자가 쓰는 진입점.
#
#   bouncer workflows                 모드 목록 (모드 선택 질문을 만들 때 쓴다)
#   bouncer options <workflow>        그 체인의 optional step 목록 (스테이지별)
#   bouncer start <workflow> <slug> [--on id --off id ...]
#   bouncer status                    현재 단계와 남은 조건
#   bouncer run <step-id>             그 step의 명령을 실행하고 결과를 기록
#   bouncer done <step-id>            사람 확인이 필요한 step을 완료 처리
#   bouncer cancel                    작업 취소
#   bouncer worktree create|finalize  병렬 작업용 브랜치·worktree
#
# current_stage / workflow / choices는 이 CLI로 바꿀 수 없다. 전이는 Stop hook만 한다.

set -uo pipefail
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_D/lib/common.sh"

PROJECT="${BOUNCER_PROJECT:-$PWD}"
SESSION="${CLAUDE_CODE_SESSION_ID:-}"

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq가 필요하다. brew install jq"
COMPILED="$(bouncer_compiled_file "$PROJECT")"

need_task() {
  TASK="$(bouncer_my_task "$PROJECT" "$SESSION")" \
    || die "이 세션의 활성 작업이 없다. 'bouncer start <workflow> <slug>'로 시작하라."
  WORK_ROOT="$(bouncer_state "$TASK" '.work_root')"; [ -d "$WORK_ROOT" ] || WORK_ROOT="$PROJECT"
  STAGE="$(bouncer_state "$TASK" '.current_stage')"
}
step_json() { bouncer_stage "$PROJECT" "$2" | jq -c --arg i "$1" '.steps[]? | select(.id == $i)'; }

# ── 목록 조회 (스킬이 질문을 만들 때 쓴다) ────────────────────
cmd_workflows() {
  [ -f "$COMPILED" ] || die "워크플로우가 컴파일되지 않았다: $COMPILED"
  jq -r '.workflows | to_entries[] | "\(.key)\t\(.value.label)"' "$COMPILED"
}

cmd_options() {
  local wf="${1:-}"; [ -n "$wf" ] || die "usage: bouncer options <workflow>"
  local stage
  while IFS= read -r stage; do
    bouncer_stage "$PROJECT" "$stage" \
      | jq -r --arg s "$stage" '.steps[]? | select(.optional) | "\($s)\t\(.id)\t\(.label)"'
  done < <(bouncer_chain "$PROJECT" "$wf")
}

# ── 시작 ─────────────────────────────────────────────────────
cmd_start() {
  local wf="${1:-}" slug="${2:-}"; shift 2 2>/dev/null || true
  [ -n "$wf" ] && [ -n "$slug" ] || die "usage: bouncer start <workflow> <slug> [--on <id>] [--off <id>]"
  [ -n "$SESSION" ] || die "세션 ID를 알 수 없다 (CLAUDE_CODE_SESSION_ID 미설정)."
  [ -f "$COMPILED" ] || die "워크플로우가 컴파일되지 않았다: $COMPILED"

  local first; first="$(bouncer_chain "$PROJECT" "$wf" | head -1)"
  [ -n "$first" ] || die "정의되지 않은 워크플로우: $wf"

  # 살아 있는 남의 lock을 보고한다. 뺏지 않는다 — 스킬이 사용자에게 묻는다.
  local other
  while IFS= read -r other; do
    [ -z "$other" ] && continue
    [ "$(jq -r '.session_id // empty' "$other/.active" 2>/dev/null)" = "$SESSION" ] && continue
    printf 'CONFLICT\t%s\t%s\n' "$other" "$(bouncer_state "$other" '.current_stage')"
  done < <(bouncer_live_locks "$PROJECT")

  # optional 기본값: 전부 켜짐. --off 로 끈다.
  local choices; choices="$(cmd_options "$wf" | jq -R -s 'split("\n") | map(select(length>0) | split("\t")[1]) | map({(.): true}) | add // {}')"
  while [ $# -gt 0 ]; do
    case "$1" in
      --on)  choices="$(jq --arg k "$2" '.[$k] = true'  <<<"$choices")"; shift 2 ;;
      --off) choices="$(jq --arg k "$2" '.[$k] = false' <<<"$choices")"; shift 2 ;;
      *) die "알 수 없는 인자: $1" ;;
    esac
  done

  local slug_safe task_id dir root head_sha base_branch
  slug_safe="$(printf '%s' "$slug" | tr -cs '[:alnum:]-' '-' | sed 's/^-*//;s/-*$//')"
  task_id="$(date +%Y%m%d-%H%M%S)-$slug_safe"
  dir="$(bouncer_tasks_dir "$PROJECT")/$task_id"
  mkdir -p "$dir" || die "태스크 디렉토리 생성 실패: $dir"

  root="$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null)"; [ -n "$root" ] || root="$PROJECT"
  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  base_branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"

  jq -n --arg id "$task_id" --arg slug "$slug" --arg wf "$wf" --arg stage "$first" \
        --arg sid "$SESSION" --arg root "$root" --arg sha "$head_sha" \
        --arg branch "$base_branch" --arg now "$(date -u +%FT%TZ)" \
        --argjson choices "$choices" '{
      task_id:$id, slug:$slug, workflow:$wf, current_stage:$stage,
      created_at:$now, session_id:$sid,
      repo_root:$root, work_root:$root, worktree:null,
      base_sha:$sha, base_branch:$branch,
      choices:$choices, evidence:{}, shown:{},
      continue_streak:0, allowed_stop:false,
      history:[{stage:$stage, at:$now}]
    }' > "$dir/state.json" || die "state.json 생성 실패"

  jq -n --arg s "$SESSION" --arg now "$(date -u +%FT%TZ)" \
     '{session_id:$s, claimed_at:$now, seen_at:$now}' > "$dir/.active"
  printf 'STARTED\t%s\tworkflow=%s\tstage=%s\n' "$task_id" "$wf" "$first"
}

# ── 상태 ─────────────────────────────────────────────────────
cmd_status() {
  need_task
  local wf; wf="$(bouncer_state "$TASK" '.workflow')"
  printf '작업:      %s\n워크플로우: %s\n체인:      %s\n현재 단계:  %s\n작업 위치:  %s\n' \
    "$(bouncer_state "$TASK" '.task_id')" "$wf" \
    "$(bouncer_chain "$PROJECT" "$wf" | tr '\n' ' ')" "$STAGE" "$WORK_ROOT"
  local wt; wt="$(bouncer_state "$TASK" '.worktree.path')"
  [ -n "$wt" ] && printf 'worktree:  %s (base %s)\n' "$wt" "$(bouncer_state "$TASK" '.worktree.base_branch')"

  printf '\n[%s] steps\n' "$STAGE"
  bouncer_stage "$PROJECT" "$STAGE" | jq -r --slurpfile st "$TASK/state.json" '
    .steps[]? |
    (($st[0].evidence[.id] // false) as $done |
     ($st[0].choices[.id]  // true)  as $on |
     "  \(if .optional and ($on|not) then "⃠ (건너뜀)" elif $done then "✅" elif .blocking then "⬜" else "·" end) \(.label)\(if .blocking then "  [\(.blocking)]" else "" end)")'
}

# ── 실행 / 완료 ──────────────────────────────────────────────
cmd_run() {
  need_task
  local id="${1:-}"; [ -n "$id" ] || die "usage: bouncer run <step-id>"
  local step; step="$(step_json "$id" "$STAGE")"
  [ -n "$step" ] || die "현재 단계($STAGE)에 '$id' step이 없다. 'bouncer status'로 확인하라."
  local kind cmd tmo
  kind="$(jq -r '.kind' <<<"$step")"
  [ "$kind" = "run" ] || die "'$id'는 실행 step이 아니다."
  cmd="$(jq -r '.run' <<<"$step")"; tmo="$(jq -r '.timeout' <<<"$step")"

  printf '▶ %s\n  $ %s\n\n' "$(jq -r '.label' <<<"$step")" "$cmd"
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$WORK_ROOT" && timeout "$tmo" bash -lc "$cmd" ) || rc=$?
  else
    ( cd "$WORK_ROOT" && bash -lc "$cmd" ) || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    bouncer_state_update "$TASK" --arg k "$id" '.evidence[$k] = true'
    printf '\n✅ 통과 — %s\n' "$id"
  else
    bouncer_state_update "$TASK" --arg k "$id" '.evidence[$k] = false
      | .attempts[$k] = ((.attempts[$k] // 0) + 1)'
    printf '\n❌ 실패 (exit %s) — %s\n출력을 읽고 고친 뒤 다시 실행하라.\n' "$rc" "$id"
    return 1
  fi
}

cmd_done() {
  need_task
  local id="${1:-}"; [ -n "$id" ] || die "usage: bouncer done <step-id>"
  local step; step="$(step_json "$id" "$STAGE")"
  [ -n "$step" ] || die "현재 단계($STAGE)에 '$id' step이 없다."
  local kind blocking
  kind="$(jq -r '.kind' <<<"$step")"; blocking="$(jq -r '.blocking // empty' <<<"$step")"
  [ "$kind" = "run" ] && die "'$id'는 실행 step이다. 'bouncer run $id'를 써라 — 결과는 엔진이 판정한다."
  case "$blocking" in
    plan_approved) die "'$id'는 plan mode 승인으로만 통과한다. ExitPlanMode를 호출하라." ;;
    skill:*)       die "'$id'는 '${blocking#skill:}' 스킬을 실제로 실행해야 통과한다." ;;
    "")            die "'$id'는 blocking이 아니다. 완료 처리할 필요가 없다." ;;
  esac
  bouncer_state_update "$TASK" --arg k "$id" '.evidence[$k] = true'
  printf 'DONE\t%s\n' "$id"
}

cmd_cancel() {
  need_task
  bouncer_state_update "$TASK" --arg n "$(date -u +%FT%TZ)" '.current_stage = "cancelled" | .cancelled_at = $n'
  rm -f "$TASK/.active"
  printf 'CANCELLED\t%s\n' "$TASK"
}

# ── worktree ─────────────────────────────────────────────────
cmd_wt_create() {
  need_task
  local root slug base_branch base_sha detached=false repo branch wt
  root="$(bouncer_state "$TASK" '.repo_root')"
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || die "git 레포가 아니다: $root"
  slug="${1:-$(bouncer_state "$TASK" '.slug')}"

  # base는 지금 확정해서 기록한다. 나중에 역추론하지 않는다.
  base_branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"
  base_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  [ -n "$base_sha" ] || die "HEAD를 읽을 수 없다 (커밋이 없는 레포?)"
  [ -n "$base_branch" ] || { detached=true; base_branch="$base_sha"; }

  repo="$(basename "$root")"
  branch="bouncer/$(printf '%s' "$slug" | tr -cs '[:alnum:]-' '-' | sed 's/^-*//;s/-*$//')-$(date +%H%M%S)"
  wt="$HOME/.ai-bouncer/worktrees/$repo/${branch//\//-}"
  mkdir -p "$(dirname "$wt")" || die "worktree 상위 디렉토리 생성 실패"
  git -C "$root" worktree add -b "$branch" "$wt" "$base_sha" >/dev/null 2>&1 || die "worktree 생성 실패: $wt"

  bouncer_state_update "$TASK" --arg p "$wt" --arg b "$branch" --arg bb "$base_branch" \
    --arg bs "$base_sha" --argjson det "$detached" \
    '.worktree = {path:$p, branch:$b, base_branch:$bb, base_sha:$bs, detached:$det}
     | .work_root = $p | .base_sha = $bs'
  printf 'WORKTREE\t%s\tbranch=%s\tbase=%s%s\n' "$wt" "$branch" "$base_branch" \
    "$([ "$detached" = true ] && printf ' (detached — FF 머지 대상 없음)')"
}

cmd_wt_finalize() {
  need_task
  local wt branch base root detached cur dirty
  wt="$(bouncer_state "$TASK" '.worktree.path')"; [ -n "$wt" ] || die "이 작업은 worktree를 쓰지 않는다."
  branch="$(bouncer_state "$TASK" '.worktree.branch')"
  base="$(bouncer_state "$TASK" '.worktree.base_branch')"
  detached="$(bouncer_state "$TASK" '.worktree.detached')"
  root="$(bouncer_state "$TASK" '.repo_root')"

  dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"
  [ -z "$dirty" ] || die "worktree에 커밋되지 않은 변경이 있다. 먼저 커밋하라:
$dirty"
  [ "$detached" = "true" ] && die "base가 detached HEAD($base)라 FF 머지할 수 없다. worktree는 보존된다: $wt"
  git -C "$root" show-ref --verify --quiet "refs/heads/$base" \
    || die "base 브랜치 '$base'가 사라졌다. worktree는 보존된다: $wt"

  if ! git -C "$wt" rebase "$base" >/dev/null 2>&1; then
    git -C "$wt" rebase --abort >/dev/null 2>&1
    die "base($base)와 충돌해 rebase 실패. worktree에서 수동 해결 후 재시도: $wt"
  fi
  cur="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"
  [ "$cur" = "$base" ] || die "메인 레포가 '$base'가 아니라 '$cur'에 있다.
'git -C $root switch $base' 후 재시도하라. worktree는 보존된다."
  git -C "$root" merge --ff-only "$branch" >/dev/null 2>&1 \
    || die "FF 머지 실패 ($base <- $branch). worktree는 보존된다: $wt"

  git -C "$root" worktree remove "$wt" --force >/dev/null 2>&1
  git -C "$root" branch -d "$branch" >/dev/null 2>&1
  bouncer_state_update "$TASK" '.worktree.merged = true | .work_root = .repo_root'
  printf 'MERGED\t%s -> %s\n' "$branch" "$base"
}

case "${1:-}" in
  workflows) shift; cmd_workflows "$@" ;;
  options)   shift; cmd_options "$@" ;;
  start)     shift; cmd_start "$@" ;;
  status)    shift; cmd_status "$@" ;;
  run)       shift; cmd_run "$@" ;;
  done)      shift; cmd_done "$@" ;;
  cancel)    shift; cmd_cancel "$@" ;;
  worktree)  shift
             case "${1:-}" in
               create)   shift; cmd_wt_create "$@" ;;
               finalize) shift; cmd_wt_finalize "$@" ;;
               *) die "usage: bouncer worktree {create|finalize}" ;;
             esac ;;
  ""|-h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "알 수 없는 명령: $1" ;;
esac
