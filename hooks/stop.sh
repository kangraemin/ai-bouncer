#!/usr/bin/env bash
# Stop — 엔진 본체.
# 모델이 응답을 끝내려는 순간 개입한다:
#   미처리 step 수행 → blocking 판정 → 통과면 다음 스테이지, 아니면 계속 일 시킴.
#
# current_stage를 쓰는 유일한 곳이다. 모델도 CLI도 못 바꾼다.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

SESSION="$(jq -r '.session_id // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty'        <<<"$INPUT")"

# 이 Stop이 직전 Stop hook의 차단 때문에 재진입한 것이면 true다.
# 여기서 또 차단하면 사용자 개입 없이 영원히 도는 구간이 생긴다.
# continue_streak 상한이 1차 방어지만, 그 카운터가 어떤 이유로 리셋되면
# 그것만으로는 못 막는다. 그래서 재진입 자체를 별도로 센다.
REENTRY="$(jq -r '.stop_hook_active // false' <<<"$INPUT")"
[ -n "$CWD" ] || CWD="$PWD"
[ -n "$SESSION" ] || exit 0

TASK="$(bouncer_my_task "$CWD" "$SESSION")" || exit 0      # 내 작업 없으면 관여 안 함
COMPILED="$(bouncer_compiled_file "$CWD")"
[ -f "$COMPILED" ] || exit 0

WORKFLOW="$(bouncer_state "$TASK" '.workflow')"
STAGE="$(bouncer_state "$TASK" '.current_stage')"
WORK_ROOT="$(bouncer_state "$TASK" '.work_root')"
[ -d "$WORK_ROOT" ] || WORK_ROOT="$CWD"
[ -n "$WORKFLOW" ] && [ -n "$STAGE" ] || exit 0
[ "$STAGE" = "cancelled" ] && exit 0

bouncer_touch_lock "$TASK"   # 하트비트 — 방치 판정의 근거
STAGE_JSON="$(bouncer_stage "$CWD" "$STAGE")"
[ -n "$STAGE_JSON" ] || exit 0

MAX_CONTINUE="$(bouncer_config max_continue 10 "$CWD")"
MAX_ATTEMPTS="$(bouncer_config max_attempts 3 "$CWD")"
MAX_LOOPS="$(bouncer_config max_loops 3 "$CWD")"

# 직전 Stop에서 멈춤을 허용했다면, 지금 Stop이 왔다는 건 그 사이에 사용자 턴이 있었다는 뜻.
# (모델은 사용자 입력 없이 새 턴을 시작하지 못한다.) UserPromptSubmit hook이 필요 없는 이유다.
USER_TURN_HAPPENED="$(bouncer_state "$TASK" '.allowed_stop')"

INJECT=""      # 이번에 주입할 텍스트
FAILURES=""    # blocking 미충족 사유
HUMAN_WAIT=0   # 사람/승인 UI를 기다리는 중인가

add_inject()  { INJECT="${INJECT}${INJECT:+$'\n\n'}$1"; }

# 전이·반송 등 어떤 경로로 차단하든 여기를 지난다. 상한을 넘으면 세션을 돌려준다.
# 전이가 continue_streak 을 리셋해도 이 카운터는 리셋되지 않는다.
MAX_BLOCKS=$(( MAX_CONTINUE * 2 + 4 ))
guarded_block() {
  local n
  n="$(jq -r '.blocks_total // 0' "$TASK/state.json" 2>/dev/null)"; [ -n "$n" ] || n=0
  n=$(( n + 1 ))
  if [ "$n" -gt "$MAX_BLOCKS" ] 2>/dev/null; then
    bouncer_state_update "$TASK" '.blocks_total = 0 | .continue_streak = 0 | .reentry_count = 0
      | .allowed_stop = true | .returned_to = null | .returned_tree = null'
    jq -n --arg c "⛔ 사용자 개입 없이 ${MAX_BLOCKS}번 연속으로 진행했다. 세션을 돌려준다.

$1

AskUserQuestion으로 물어라 (도구가 없으면 텍스트로 제시하고 답을 기다려라):
  1. 계속 진행한다
  2. 접근을 바꾼다
  3. 작업을 중단한다 (bouncer cancel)" \
      '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
    exit 0
  fi
  bouncer_state_update "$TASK" --argjson n "$n" '.blocks_total = $n'
  bouncer_block "$1"
}
add_failure() { FAILURES="${FAILURES}${FAILURES:+$'\n'}- $1"; }

while IFS= read -r step; do
  [ -z "$step" ] && continue
  ID="$(jq -r '.id'       <<<"$step")"
  KIND="$(jq -r '.kind'   <<<"$step")"
  LABEL="$(jq -r '.label' <<<"$step")"
  BLOCKING="$(jq -r '.blocking // empty' <<<"$step")"
  OPTIONAL="$(jq -r '.optional' <<<"$step")"

  # 시작할 때 사용자가 끈 항목은 건너뛴다 (choices는 hook 전용 필드)
  if [ "$OPTIONAL" = "true" ]; then
    CHOSEN="$(jq -r --arg k "$ID" '.choices[$k] // false' "$TASK/state.json" 2>/dev/null)"
    [ "$CHOSEN" = "true" ] || continue
  fi

  DONE="$(jq -r --arg k "$ID" '.evidence[$k] // false' "$TASK/state.json" 2>/dev/null)"
  SHOWN="$(jq -r --arg k "$ID" '.shown[$k] // false'    "$TASK/state.json" 2>/dev/null)"

  if [ "$KIND" = "inject" ]; then
    if [ "$SHOWN" != "true" ]; then
      add_inject "$(jq -r '.text' <<<"$step")"
      bouncer_state_update "$TASK" --arg k "$ID" '.shown[$k] = true'
    fi
    [ -z "$BLOCKING" ] && continue
    # plan_approved / skill: 은 hook이 도구 사용을 직접 관찰한 증거다 — 사용자 턴을 따로 요구하지 않는다.
    # 반면 순수 inject blocking은 모델의 자기신고이므로 실제 사용자 턴이 있어야 인정한다.
    if [ "$DONE" = "true" ]; then
      case "$BLOCKING" in
        plan_approved|skill:*) continue ;;
        *) [ "$USER_TURN_HAPPENED" = "true" ] && continue ;;
      esac
    fi

    case "$BLOCKING" in
      plan_approved)
        add_failure "계획이 아직 승인되지 않았다 — ExitPlanMode 승인 필요 ($LABEL)"
        HUMAN_WAIT=1 ;;
      skill:*)
        add_failure "'${BLOCKING#skill:}' 스킬을 아직 실행하지 않았다 ($LABEL)" ;;
      *)
        if [ "$DONE" != "true" ]; then
          add_inject "→ 위를 마쳤으면 실행: bouncer done '$ID'   ($LABEL)"
        fi
        add_failure "사용자 확인 대기 중 ($LABEL)"
        HUMAN_WAIT=1 ;;
    esac
    continue
  fi

  # ── run ────────────────────────────────────────────────────
  [ "$DONE" = "true" ] && continue
  CMD="$(jq -r '.run'     <<<"$step")"
  BY="$(jq -r '.by'       <<<"$step")"
  TMO="$(jq -r '.timeout' <<<"$step")"

  if [ "$BY" = "engine" ]; then
    # 짧은 명령만 여기 온다 (컴파일에서 60초 상한 강제).
    if command -v timeout >/dev/null 2>&1; then
      OUT="$( cd "$WORK_ROOT" && timeout "$TMO" bash -lc "$CMD" 2>&1 )"; RC=$?
    else
      OUT="$( cd "$WORK_ROOT" && bash -lc "$CMD" 2>&1 )"; RC=$?
    fi
    TAIL="$(printf '%s' "$OUT" | tail -30)"
    if [ "$RC" -eq 0 ]; then
      bouncer_state_update "$TASK" --arg k "$ID" '.evidence[$k] = true'
      [ -n "$TAIL" ] && add_inject "[$LABEL] 통과 (exit 0)"$'\n'"$TAIL"
    elif [ -n "$BLOCKING" ]; then
      add_failure "$LABEL — \`$CMD\` 실패 (exit $RC)"
      add_inject "[$LABEL] 실패 (exit $RC)"$'\n'"$TAIL"
    fi
  else
    # 모델이 직접 실행한다. PostToolUse가 결과를 관찰해 evidence를 기록한다.
    if [ "$SHOWN" != "true" ]; then
      add_inject "다음 명령을 실행하고 결과를 확인해라 ($LABEL):"$'\n'"    $CMD"
      bouncer_state_update "$TASK" --arg k "$ID" '.shown[$k] = true'
    fi
    [ -n "$BLOCKING" ] && add_failure "$LABEL — \`$CMD\`를 아직 통과하지 못했다"
  fi
done < <(jq -c '.steps[]?' <<<"$STAGE_JSON")

# ─────────────────────────────────────────────────────────────
# 판정
# ─────────────────────────────────────────────────────────────
if [ -z "$FAILURES" ]; then
  # 반송돼 온 스테이지라면, 뭔가 달라졌을 때만 다시 내보낸다.
  # 그러지 않으면 조건 없는 스테이지를 사이에 두고 같은 검사를 무한히 반복한다.
  RET_TO="$(bouncer_state "$TASK" '.returned_to')"
  if [ -n "$RET_TO" ] && [ "$RET_TO" = "$STAGE" ]; then
    RET_TREE="$(bouncer_state "$TASK" '.returned_tree')"
    NOW_TREE="$(bouncer_tree_hash "$WORK_ROOT")"
    if [ -n "$RET_TREE" ] && [ "$RET_TREE" = "$NOW_TREE" ]; then
      bouncer_state_update "$TASK" '.continue_streak = (.continue_streak // 0) + 1'
      NS="$(bouncer_state "$TASK" '.continue_streak')"; [ -n "$NS" ] || NS=1
      # 여기서 그냥 막으면 아래 상한 검사에 영영 도달하지 못한다.
      # 고칠 의사가 없거나 고칠 수 없는 상황이면 세션을 사용자에게 돌려줘야 한다.
      if [ "$NS" -ge "$MAX_CONTINUE" ] 2>/dev/null; then
        bouncer_state_update "$TASK" \
          '.allowed_stop = true | .continue_streak = 0 | .returned_to = null | .returned_tree = null'
        jq -n --arg c "⛔ [$STAGE] 되돌아온 뒤 ${NS}번 동안 작업 트리가 그대로다.
고칠 수 없거나 고칠 것이 없는 상태로 보인다. 사용자에게 넘긴다.

직전 실패:
$(bouncer_state "$TASK" '.last_failure')

AskUserQuestion으로 물어라 (도구가 없으면 텍스트로 제시하고 답을 기다려라):
  1. 접근을 바꿔서 다시 시도한다
  2. 이 조건을 이번 작업에서만 건너뛴다
  3. 작업을 중단한다 (bouncer cancel)" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
        exit 0
      fi
      guarded_block "[$STAGE] 되돌아온 뒤 작업 트리가 그대로다 — 아무것도 바뀌지 않았다. (${NS}/${MAX_CONTINUE})

이대로 다시 검증에 보내면 같은 결과가 나온다. 무엇이 틀렸는지 다시 보고 실제로 고쳐라.
직전 실패:
$(bouncer_state "$TASK" '.last_failure')"
    fi
    bouncer_state_update "$TASK" '.returned_to = null | .returned_tree = null'
  fi

  # ── 전이 ──
  NEXT="$(bouncer_next_stage "$CWD" "$WORKFLOW" "$STAGE")"
  if [ -z "$NEXT" ]; then
    # 종단 도달 — lock 해제. 작업 문서는 남긴다.
    bouncer_state_update "$TASK" --arg t "$(date -u +%FT%TZ)" \
      '.finished_at = $t | .allowed_stop = false'
    rm -f "$TASK/.active"
    [ -n "$INJECT" ] && jq -n --arg c "$INJECT" \
      '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
    exit 0
  fi
  # 다음 스테이지의 지시를 지금 함께 전달한다. 그러지 않으면 blocking 없는
  # 스테이지는 "진입 → 다음 Stop에서 즉시 통과"라 지시를 받는 턴이 없다.
  NEXT_TXT="$(bouncer_stage "$CWD" "$NEXT" \
    | jq -r --slurpfile st "$TASK/state.json" \
        '[.steps[]? | select(.kind=="inject")
          | select((.optional | not) or (($st[0].choices[.id]) // true))
          | .text] | join("\n\n")')"
  if [ -n "$NEXT_TXT" ]; then
    while IFS= read -r nid; do
      [ -n "$nid" ] && bouncer_state_update "$TASK" --arg k "$nid" '.shown[$k] = true'
    done < <(bouncer_stage "$CWD" "$NEXT" | jq -r --slurpfile st "$TASK/state.json" \
      '.steps[]? | select(.kind=="inject")
       | select((.optional | not) or (($st[0].choices[.id]) // true)) | .id')
  fi
  bouncer_state_update "$TASK" --arg n "$NEXT" --arg t "$(date -u +%FT%TZ)" \
    '.current_stage = $n
     | .continue_streak = 0
     | .reentry_count = 0
     | .allowed_stop = false
     | .history += [{stage:$n, at:$t}]'
  guarded_block "✅ [$STAGE] 완료 → [$NEXT] 진입${NEXT_TXT:+$'\n\n'}$NEXT_TXT"
fi

# ── 미충족 ──
STREAK="$(bouncer_state "$TASK" '.continue_streak')"; [ -n "$STREAK" ] || STREAK=0

# ── on_fail 되돌아가기 ───────────────────────────────────────
# 이 스테이지가 파일 수정을 금지한다면 제자리 재시도는 무의미하다 → 1회 실패로 즉시 반송.
# 수정이 가능하면 max_attempts만큼 제자리에서 고쳐보고 그래도 안 되면 반송.
ON_FAIL="$(jq -r '.on_fail // empty' <<<"$STAGE_JSON")"
if [ -n "$ON_FAIL" ] && [ "$HUMAN_WAIT" != "1" ]; then
  CAN_FIX_HERE=1
  [ "$(jq -r '.forbid.edit_files // "null"' <<<"$STAGE_JSON")" != "null" ] && CAN_FIX_HERE=0
  ATTEMPTS="$(jq -r --arg s "$STAGE" '.stage_attempts[$s] // 0' "$TASK/state.json" 2>/dev/null)"
  [ -n "$ATTEMPTS" ] || ATTEMPTS=0
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  [ "$ATTEMPTS" -le $(( MAX_ATTEMPTS + 1 )) ] 2>/dev/null \
    && bouncer_state_update "$TASK" --arg s "$STAGE" --argjson n "$ATTEMPTS" '.stage_attempts[$s] = $n'

  LIMIT="$MAX_ATTEMPTS"; [ "$CAN_FIX_HERE" = "0" ] && LIMIT=1
  if [ "$ATTEMPTS" -ge "$LIMIT" ] 2>/dev/null; then
    if [ "$ON_FAIL" = "abort" ]; then
      bouncer_state_update "$TASK" --arg t "$(date -u +%FT%TZ)" \
        '.current_stage = "cancelled" | .cancelled_at = $t'
      rm -f "$TASK/.active"
      jq -n --arg c "⛔ [$STAGE] 조건을 충족하지 못해 작업을 중단했다.

$FAILURES" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
      exit 0
    fi
    # 왕복 횟수는 전이가 리셋하지 않는다. 리셋하면 A→B→A→B 로 영원히 돈다.
    bouncer_state_update "$TASK" --arg f "$FAILURES" '.last_failure = $f'
    PAIR="$STAGE->$ON_FAIL"
    LOOPS="$(jq -r --arg k "$PAIR" '.loops[$k] // 0' "$TASK/state.json" 2>/dev/null)"
    [ -n "$LOOPS" ] && [ "$LOOPS" != "null" ] || LOOPS=0
    if [ "$(( LOOPS + 1 ))" -gt "$MAX_LOOPS" ] 2>/dev/null; then
      # 이미 상한이면 카운터를 더 올리지 않는다 — 숫자가 실제 왕복 횟수와 어긋난다.
      bouncer_state_update "$TASK" \
        '.allowed_stop = true | .continue_streak = 0 | .reentry_count = 0'
      jq -n --arg c "⛔ [$STAGE] ↔ [$ON_FAIL] 사이를 ${LOOPS}번 왕복했다.
같은 자리를 돌고 있으므로 더 밀지 않고 사용자에게 넘긴다.

미충족 조건:
$FAILURES

AskUserQuestion으로 물어라 (도구가 없으면 텍스트로 제시하고 답을 기다려라):
  1. 접근을 바꿔서 다시 시도한다
  2. 이 조건을 이번 작업에서만 건너뛴다
  3. 작업을 중단한다 (bouncer cancel)" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
      exit 0
    fi
    LOOPS=$(( LOOPS + 1 ))

    # 되돌아갈 때, 반송 대상부터 실패 스테이지까지의 진행 기록을 전부 지운다.
    # 실패 스테이지 것만 지우면 사이 스테이지의 게이트가 "한 번 통과했으니 통과"로
    # 영원히 건너뛰어진다 — 그 사이에 코드가 바뀌었는데도.
    IDS="$(
      { CH="$(bouncer_chain "$CWD" "$WORKFLOW")"
        started=0
        while IFS= read -r st; do
          [ "$st" = "$ON_FAIL" ] && started=1
          [ "$started" = 1 ] && bouncer_stage "$CWD" "$st" | jq -r '.steps[]?.id'
          [ "$st" = "$STAGE" ] && break
        done <<< "$CH"
      } | jq -R -s 'split("\n") | map(select(length > 0))'
    )"
    # 되돌려 보낸 시점의 작업 트리를 기억해둔다. 아무것도 안 바뀌었는데
    # 다시 전진시키면 같은 검사를 같은 코드에 돌리는 헛바퀴가 된다.
    TREE="$(bouncer_tree_hash "$WORK_ROOT")"
    bouncer_state_update "$TASK" --arg back "$ON_FAIL" --argjson ids "$IDS" \
      --arg s "$STAGE" --arg t "$(date -u +%FT%TZ)" --argjson n "$LOOPS" --arg tree "$TREE" --arg pair "$PAIR" '
        .current_stage = $back
        | .returned_tree = $tree
        | .returned_to = $back
        | .loops[$pair] = $n
        | .evidence       |= with_entries(select(.key as $k | ($ids | index($k)) | not))
        | .shown          |= with_entries(select(.key as $k | ($ids | index($k)) | not))
        | .stage_attempts[$s] = 0
        | .continue_streak = 0
        | .allowed_stop = false
        | .history += [{stage:$back, at:$t, returned_from:$s}]'
    guarded_block "↩️ [$STAGE] 조건을 충족하지 못해 [$ON_FAIL] 단계로 되돌아간다. (${LOOPS}/${MAX_LOOPS}회)

미충족 조건:
$FAILURES${INJECT:+$'\n\n'}$INJECT"
  fi
fi

if [ "$HUMAN_WAIT" = "1" ]; then
  # 사람이 답해야 하는데 Stop을 막으면 답할 기회가 없다 — 멈추게 둔다.
  # 다만 지시와 미충족 사유는 반드시 전달해야 한다. 여기서 버리면
  # 이 스테이지의 프롬프트가 모델에게 한 번도 도달하지 않는다.
  bouncer_state_update "$TASK" '.allowed_stop = true'
  if [ -n "$INJECT" ] || [ -n "$FAILURES" ]; then
    jq -n --arg c "[$STAGE] 아직 끝나지 않았다.${FAILURES:+$'\n\n'}${FAILURES:+미충족 조건:
}$FAILURES${INJECT:+$'\n\n'}$INJECT" \
      '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
  fi
  exit 0
fi

# 재진입 상태에서 상한의 두 배를 넘겼다면 카운터가 어딘가에서 리셋되고 있다는 뜻이다.
# 그 경우 워크플로우 진행보다 세션을 사용자에게 돌려주는 쪽이 안전하다.
REENTRY_N="$(jq -r '.reentry_count // 0' "$TASK/state.json" 2>/dev/null)"
if [ "$REENTRY" = "true" ]; then
  REENTRY_N=$(( REENTRY_N + 1 ))
  bouncer_state_update "$TASK" --argjson n "$REENTRY_N" '.reentry_count = $n'
else
  bouncer_state_update "$TASK" '.reentry_count = 0'; REENTRY_N=0
fi
if [ "$REENTRY_N" -gt $(( MAX_CONTINUE * 2 )) ] 2>/dev/null; then
  bouncer_state_update "$TASK" '.allowed_stop = true | .continue_streak = 0 | .reentry_count = 0'
  jq -n --arg c "⛔ [$STAGE] Stop hook 재진입이 비정상적으로 반복됐다 (${REENTRY_N}회).
워크플로우를 더 밀지 않고 세션을 사용자에게 돌려준다.

미충족 조건:
$FAILURES" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
  exit 0
fi

if [ "$STREAK" -ge "$MAX_CONTINUE" ] 2>/dev/null; then
  bouncer_state_update "$TASK" '.allowed_stop = true | .continue_streak = 0'
  jq -n --arg c "⛔ ${MAX_CONTINUE}회 연속 진행했지만 [$STAGE] 단계를 벗어나지 못했다.

미충족 조건:
$FAILURES

AskUserQuestion으로 사용자에게 물어라:
  1. 계속 시도한다
  2. 접근을 바꾼다 (필요하면 이전 단계로 되돌린다)
  3. 이 조건을 이번 작업에서만 건너뛴다
  4. 작업을 중단한다" '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}'
  exit 0
fi

bouncer_state_update "$TASK" '.continue_streak = (.continue_streak // 0) + 1 | .allowed_stop = false'
guarded_block "[$STAGE] 아직 끝나지 않았다.

미충족 조건:
$FAILURES${INJECT:+$'\n\n'}$INJECT"
