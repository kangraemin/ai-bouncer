#!/usr/bin/env bash
# PreToolUse — 현재 스테이지의 forbid를 강제한다.
#
# ⚠️ 매 도구 호출마다 돈다. 그리고 이 hook이 타임아웃되면 차단이 **아예 안 된다**
#    (공식 문서: "don't count on a stalled hook to act as a gate").
#    그래서 여기서는 jq로 compiled.json을 읽기만 한다. 명령 실행 금지.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

SESSION="$(jq -r '.session_id // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty'            <<<"$INPUT")"
TOOL="$(jq -r '.tool_name // empty'     <<<"$INPUT")"
[ -n "$CWD" ] || CWD="$PWD"
[ -n "$SESSION" ] && [ -n "$TOOL" ] || exit 0

TASK="$(bouncer_my_task "$CWD" "$SESSION")" || exit 0

# 여기까지 왔다는 건 이 세션에 활성 작업이 있다는 뜻이다.
# 그런데 상태나 설정을 못 읽으면 "규칙 없음"이 아니라 "규칙을 알 수 없음"이다.
# 그때 통과시키면 파일 하나 깨뜨리는 것으로 모든 가드가 사라진다 — 막는 쪽이 맞다.
COMPILED="$(bouncer_compiled_file "$CWD")"
if ! jq -e . "$COMPILED" >/dev/null 2>&1; then
  bouncer_block "⛔ [ai-bouncer] 워크플로우 설정을 읽을 수 없다: $COMPILED
규칙을 알 수 없는 상태에서는 진행할 수 없다.
  \`bouncer check\` 로 workflow.yaml을 확인하거나, 되돌린 뒤 다시 시도하라."
fi
if ! jq -e . "$TASK/state.json" >/dev/null 2>&1; then
  bouncer_block "⛔ [ai-bouncer] 작업 상태 파일이 손상됐다: $TASK/state.json
진행할 수 없다. \`bouncer cancel\` 로 정리하고 다시 시작하라."
fi

STAGE="$(bouncer_state "$TASK" '.current_stage')"
[ "$STAGE" = "cancelled" ] && exit 0
if [ -z "$STAGE" ]; then
  bouncer_block "⛔ [ai-bouncer] 현재 단계를 알 수 없다. \`bouncer cancel\` 로 정리하고 다시 시작하라."
fi

# ── 엔진 전용 파일 보호 (스테이지와 무관하게 항상) ────────────
# 이 파일들을 고치면 단계 건너뛰기나 가드 무력화가 가능해진다.
ENGINE_FILE_MSG="⛔ [ai-bouncer] 엔진 파일은 직접 수정할 수 없다.
단계 전이와 규칙은 엔진이 관리한다. 조건을 충족시켜서 넘어가라."

FILE_PATH="$(jq -r '.tool_input.file_path // .tool_input.path // empty' <<<"$INPUT")"
case "$FILE_PATH" in
  */.ai-bouncer/tasks/*/state.json|*/.ai-bouncer/tasks/*/.active|\
  */workflow.compiled.json|*/.claude/ai-bouncer/*)
    bouncer_block "$ENGINE_FILE_MSG" ;;
esac

# 셸을 통한 접근도 같은 기준으로 막는다. Edit/Write만 막으면
# `echo '{' > .claude/ai-bouncer/workflow.compiled.json` 한 줄로 전부 무력화된다.
if [ "$TOOL" = "Bash" ]; then
  _CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
  case "$_CMD" in
    bouncer\ *|*/bouncer.sh\ *) ;;   # 엔진 자신의 명령은 예외
    *)
      if printf '%s' "$_CMD" | grep -Eq '(\.ai-bouncer/tasks/[^[:space:]]*/(state\.json|\.active)|workflow\.compiled\.json|\.claude/ai-bouncer/)' \
         && printf '%s' "$_CMD" | grep -Eq '(^|[;&|[:space:]])(rm|mv|cp|touch|truncate|tee|sed|perl|python3?|dd|install|ex|ed|chmod|ln)\b|[^|>]>' ; then
        bouncer_block "$ENGINE_FILE_MSG"
      fi ;;
  esac
fi

FORBID="$(bouncer_stage "$CWD" "$STAGE" | jq -c '.forbid // {}')"
REASON="$(jq -r '.reason // ""' <<<"$FORBID")"
[ -n "$REASON" ] || REASON="현재 단계에서 허용되지 않는 동작이다."
deny() {
  # 판정기가 낸 사유와 yaml의 reason 이 같은 말이면 두 번 보여주지 않는다.
  if [ "$1" = "$REASON" ] || printf '%s' "$1" | grep -qF "$REASON"; then
    bouncer_block "⛔ [ai-bouncer / $STAGE] $1"
  else
    bouncer_block "⛔ [ai-bouncer / $STAGE] $1

$REASON"
  fi
}

EDIT="$(jq -c '.edit_files // null' <<<"$FORBID")"
PUSH="$(jq -r '.push'               <<<"$FORBID")"

# 경로가 edit_files 스코프에 걸리는가. true면 전체, 배열이면 glob(선두 !는 예외).
path_forbidden() {
  local p="$1"
  [ "$EDIT" = "null" ] && return 1
  [ "$EDIT" = "true" ] && return 0
  local pat neg matched=1
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    neg=0; case "$pat" in "!"*) neg=1; pat="${pat#!}" ;; esac
    # shellcheck disable=SC2254
    case "$p" in $pat) [ "$neg" = 1 ] && return 1 || matched=0 ;; esac
  done < <(jq -r '.[]?' <<<"$EDIT")
  return $matched
}

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    # 프로젝트 기준 상대경로로만 판정한다. 절대경로로 한 번 더 보면
    # "!docs/**" 같은 예외가 앞의 "**"에 다시 걸려 무효화된다.
    REL="${FILE_PATH#"$CWD"/}"
    if path_forbidden "$REL"; then
      deny "파일 수정이 차단되었다: ${REL:-$FILE_PATH}"
    fi
    exit 0 ;;

  Bash)
    CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
    [ -n "$CMD" ] || exit 0
    # 정규식 블랙리스트로는 못 막는다는 게 감사로 확인됐다 —
    # 따옴표(`"rm" -f`), 인터프리터(`python3 -c "open(...,'w')"`), 에디터(`ed`),
    # git write 서브커맨드가 전부 빠져나갔고, `bouncer status; rm x` 처럼
    # 허용 명령 뒤에 붙이면 통째로 통과했다.
    # 그래서 명령을 세그먼트로 쪼개고 실행 파일 이름을 정규화해서 판정한다.
    GUARD="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/engine/lib/guard.py"
    # 이 스테이지에 아무 제약이 없으면 판정할 것도 없다.
    if [ "$(jq -r '(.edit_files|tostring) + (.push|tostring) + ((.bash|length)|tostring)' <<<"$FORBID")" = "nullfalse0" ]; then
      exit 0
    fi
    # 제약이 있는데 판정기를 못 쓰면 "제약 없음"이 아니라 "판정 불가"다. 막는다.
    if [ ! -f "$GUARD" ] || ! command -v python3 >/dev/null 2>&1; then
      deny "명령 판정기를 사용할 수 없다 ($GUARD).
이 단계에는 제약이 걸려 있는데 무엇이 허용되는지 판정할 수 없다.
설치가 손상됐을 수 있다 — 다시 설치하라."
    fi
    REASON="$(printf '%s' "$CMD" | python3 "$GUARD" \
      "$(jq -c '.edit_files // null' <<<"$FORBID")" \
      "$(jq -r '.push' <<<"$FORBID")" \
      "$(jq -c '.bash // []' <<<"$FORBID")" \
      "$CWD")" || deny "명령 판정 중 오류가 발생했다. 안전을 위해 차단한다."
    [ -n "$REASON" ] && deny "$REASON"
    exit 0 ;;
esac
exit 0
