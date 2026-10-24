#!/usr/bin/env bash
# Stop — 엔진 본체. 모델이 응답을 끝내려는 순간 개입한다:
#   1. 이 단계의 prompt 를 아직 안 줬으면 주고 막는다.
#   2. 이 단계의 run 을 전부 돌린다. 전부 exit 0 이면 다음 단계로, 아니면 출력을 주고 막는다.
#
# current_stage를 쓰는 유일한 곳이다. 모델도 CLI도 못 바꾼다.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

SESSION="$(jq -r '.session_id // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty'        <<<"$INPUT")"
# 이 Stop이 직전 Stop hook의 차단 때문에 재진입한 것이면 true다.
REENTRY="$(jq -r '.stop_hook_active // false' <<<"$INPUT")"
[ -n "$CWD" ] || CWD="$PWD"
bouncer_defer_to_local "$CWD" "${BASH_SOURCE[0]}" && exit 0
[ -n "$SESSION" ] || exit 0

TASK="$(bouncer_my_task "$CWD" "$SESSION")" || exit 0      # 내 작업 없으면 관여 안 함
CWD="$(bouncer_task_root "$TASK")"                          # 설정·검사는 작업을 시작한 레포 기준
COMPILED="$(bouncer_compiled_file "$CWD")"

CONFIG_BROKEN=0
{ [ -f "$COMPILED" ] && jq -e . "$COMPILED" >/dev/null 2>&1; } || CONFIG_BROKEN=1

WORKFLOW="$(bouncer_state "$TASK" '.workflow')"
STAGE="$(bouncer_state "$TASK" '.current_stage')"
WORK_ROOT="$(bouncer_state "$TASK" '.work_root')"
[ -n "$WORK_ROOT" ] || WORK_ROOT="$CWD"
STATE_BROKEN=0
jq -e . "$TASK/state.json" >/dev/null 2>&1 || STATE_BROKEN=1
if [ "$STATE_BROKEN" = 0 ]; then
  [ -n "$WORKFLOW" ] && [ -n "$STAGE" ] || exit 0
fi
[ "$STAGE" = "cancelled" ] && exit 0

# 연속으로 이만큼 막았으면 사용자에게 넘긴다.
MAX_CONTINUE="${BOUNCER_MAX_CONTINUE:-10}"

emit_context() { jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'; exit 0; }

# 어떤 경로로 차단하든 여기를 지난다.
#  · 직전 차단과 같은 사유인데 그 뒤 도구를 하나도 안 썼으면 다시 막아봐야 같은 답만 반복한다
#    (도구 없는 재진입 루프 54건, 최대 939회) — 막지 않고 끝내게 둔다. 단계는 그대로다.
#  · 연속으로 MAX_CONTINUE 번 막았으면 더 밀지 않고 사용자에게 넘긴다.
guarded_block() {
  local key seq streak
  # 숫자는 뺀다 — 횟수·시각이 매번 바뀌어 같은 차단을 새 차단으로 보면 안 된다.
  key="$STAGE:$(printf '%s' "$1" | tr -d '0-9' | cksum | cut -d' ' -f1)"
  seq="$(cat "$TASK/.tool_seq" 2>/dev/null)"; case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  if [ "$REENTRY" = "true" ] && [ "$(cat "$TASK/.block_key" 2>/dev/null)" = "$key" ] \
     && [ "$(cat "$TASK/.tool_seq_at_block" 2>/dev/null)" = "$seq" ]; then
    exit 0
  fi
  printf '%s' "$key" > "$TASK/.block_key" 2>/dev/null || true
  printf '%s' "$seq" > "$TASK/.tool_seq_at_block" 2>/dev/null || true
  streak="$(bouncer_state "$TASK" '.continue_streak')"; case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
  if [ "$streak" -ge "$MAX_CONTINUE" ] 2>/dev/null; then
    bouncer_state_update "$TASK" '.continue_streak = 0'
    emit_context "$1

⛔ ${MAX_CONTINUE}회 연속으로 [$STAGE] 단계를 벗어나지 못했다. 더 밀지 않고 사용자에게 넘긴다.
AskUserQuestion으로 물어라 (도구가 없으면 텍스트로 제시하고 답을 기다려라):
  1. 계속 시도한다
  2. 접근을 바꾼다
  3. 작업을 중단한다 (bouncer cancel)"
  fi
  bouncer_state_update "$TASK" '.continue_streak = (.continue_streak // 0) + 1'
  bouncer_block "$1"
}

if [ "$STATE_BROKEN" = 1 ]; then
  guarded_block "⛔ [ai-bouncer] 작업 상태 파일이 손상됐다.
진행 상황을 알 수 없어 단계를 넘길 수 없다.
  · 작업을 포기한다: bouncer cancel"
fi
if [ "$CONFIG_BROKEN" = 1 ]; then
  guarded_block "⛔ [ai-bouncer] 워크플로우 설정을 읽을 수 없다.
  · \`bouncer check\` 로 workflow.yaml 을 확인하라 (yaml 이 멀쩡하면 다음 세션 시작 때 다시 컴파일된다)
  · 작업을 포기한다: bouncer cancel"
fi
# chain 이 생기기 전에 시작한 작업은 모드의 체인을 그대로 쓴다.
if ! jq -e '.chain | type == "array"' "$TASK/state.json" >/dev/null 2>&1; then
  bouncer_state_update "$TASK" --argjson c "$(jq -c --arg w "$WORKFLOW" '.workflows[$w].stages // []' "$COMPILED")" '.chain = $c'
fi
STAGE_JSON="$(bouncer_stage_view "$CWD" "$TASK" "$STAGE")"
if [ -z "$STAGE_JSON" ]; then
  guarded_block "⛔ [ai-bouncer] 진행 중인 단계 '$STAGE' 가 workflow.yaml에 없다.
작업 도중 삭제되었거나 이름이 바뀐 것으로 보인다.
  · workflow.yaml에서 '$STAGE' 를 되돌린다
  · 이 작업을 포기한다: bouncer cancel"
fi
# 작업 트리가 사라졌는데 조용히 다른 곳에서 run 을 돌리면 검사 대상이 예고 없이 바뀐다.
if [ ! -d "$WORK_ROOT" ]; then
  guarded_block "⛔ [ai-bouncer] 이 작업의 디렉토리가 사라졌다: $WORK_ROOT
  · 작업을 포기한다: bouncer cancel"
fi

# ── 1. 진입 지시 ─────────────────────────────────────────────
# 지시를 보기 전에 검사를 돌리면 무엇을 하라는지 모른 채 실패 출력만 받는다.
PROMPT="$(jq -r '.prompt // ""' <<<"$STAGE_JSON")"
if [ -n "$PROMPT" ] && [ "$(jq -r --arg s "$STAGE" '.shown[$s] // false' "$TASK/state.json")" != true ]; then
  bouncer_state_update "$TASK" --arg s "$STAGE" '.shown[$s] = true'
  guarded_block "$PROMPT"
fi

# ── 2. 검사 ──────────────────────────────────────────────────
# 전부 WORK_ROOT 에서 돌린다. 합계 상한은 Stop hook timeout(1800초)보다 짧아야 한다.
REPORT=""
DEADLINE=$(( $(date +%s) + ${BOUNCER_RUN_BUDGET:-1700} ))
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  # 예산을 다 써도 남은 명령은 1초로라도 돌려 시간 초과(124)로 보고한다 — 건너뛰면 통과로 보인다.
  LEFT=$(( DEADLINE - $(date +%s) )); [ "$LEFT" -gt 0 ] || LEFT=1
  # run 에서 `bouncer passed`·`bouncer fresh` 같은 엔진 명령을 쓸 수 있게 실행 파일 위치를 PATH 에 넣는다 (hook 의 PATH 에 없을 수 있다).
  OUT="$(cd "$WORK_ROOT" && PATH="$HOME/.local/bin:$PATH" BOUNCER_STAGE="$STAGE" BOUNCER_TASK_DIR="$TASK" \
           bouncer_run_timeout "$LEFT" bash -c "$CMD" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && continue
  case "$RC" in
    2)   WHY="아직 통과하지 못했다" ;;
    124) WHY="시간 초과 (${BOUNCER_RUN_BUDGET:-1700}초 안에 안 끝났다 — 검사는 prompt 에서 `bouncer record <이름> <명령>` 으로 직접 돌리고, run 에는 `bouncer passed <이름>` 만 둬라)" ;;
    127) WHY="명령을 찾을 수 없다 — 경로·의존성을 확인하라" ;;
    *)   WHY="검사가 실패했다" ;;
  esac
  REPORT="[$STAGE] \`$CMD\` — $WHY (exit $RC)
$(printf '%s' "$OUT" | tail -30)"
  break
done < <(jq -r '.run[]?' <<<"$STAGE_JSON")

if [ -n "$REPORT" ]; then
  guarded_block "$REPORT

고친 뒤 다시 끝내려 하면 검사를 다시 돌린다."
fi

# ── 3. 전이 ──────────────────────────────────────────────────
NEXT="$(bouncer_next_stage "$TASK" "$STAGE")"
# 다음 단계가 비었다고 곧장 "끝"으로 보면 안 된다. 작업 도중 워크플로우를 지우거나
# 이름을 바꿔도 빈 값이 나오는데, 그러면 남은 단계가 통째로 건너뛰어진다.
if [ -z "$NEXT" ] && ! bouncer_is_last_stage "$TASK" "$STAGE"; then
  guarded_block "⛔ [ai-bouncer] 단계 '$STAGE' 가 이 작업의 체인에 없다 (state.json 손상).
  · 이 작업을 포기한다: bouncer cancel"
fi

finish() {
  # 실패하면 .active 만 지워져 끝난 작업이 영구히 미완(ORPHAN)으로 뜬다.
  bouncer_state_update "$TASK" --arg n "$1" --arg t "$(date -u +%FT%TZ)" \
    '.current_stage = $n | .finished_at = $t | .continue_streak = 0
     | if $n != .history[-1].stage then .history += [{stage:$n, at:$t}] else . end' \
    || guarded_block "⛔ [ai-bouncer] 완료를 기록하지 못했다 (상태 파일 잠금 경합). 잠시 뒤 다시 시도하면 된다."
  rm -f "$TASK/.active"
}

# 마지막 단계까지 통과했다 — 이제야 멈출 수 있다.
if [ -z "$NEXT" ]; then
  finish "$STAGE"
  emit_context "✅ [ai-bouncer] 모든 단계를 마쳤다. 작업 종료."
fi

NEXT_TXT="$(bouncer_stage_view "$CWD" "$TASK" "$NEXT" | jq -r '.prompt // ""')"
# 갱신이 실패하면 단계는 그대로인데 "완료" 를 보고하게 된다.
bouncer_state_update "$TASK" --arg n "$NEXT" --arg t "$(date -u +%FT%TZ)" \
  '.current_stage = $n | .continue_streak = 0 | .shown[$n] = true | .history += [{stage:$n, at:$t}]' \
  || guarded_block "⛔ [ai-bouncer] 단계 전이를 기록하지 못했다 (상태 파일 잠금 경합). 잠시 뒤 다시 시도하면 된다."
bouncer_block "✅ [$STAGE] 완료 → [$NEXT] 진입${NEXT_TXT:+$'\n\n'}$NEXT_TXT"
