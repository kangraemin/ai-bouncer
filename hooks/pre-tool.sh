#!/usr/bin/env bash
# PreToolUse — 엔진 파일(상태·설정·hook 등록) 직접 수정을 막고, 도구 호출 수를 센다.
#
# ⚠️ 매 도구 호출마다 돈다. 그리고 이 hook이 타임아웃되면 차단이 **아예 안 된다**
#    (공식 문서: "don't count on a stalled hook to act as a gate").
#    그래서 여기서는 jq로 compiled.json을 읽기만 한다. 명령 실행 금지.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

# 매 Bash 호출마다 돈다 — jq 를 필드마다 부르지 않고 한 번에 읽는다.
{ IFS= read -r SESSION; IFS= read -r CWD; IFS= read -r TOOL; } \
  < <(jq -r '(.session_id // "" | tostring), (.cwd // "" | tostring), (.tool_name // "" | tostring)' <<<"$INPUT" 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"
bouncer_defer_to_local "$CWD" "${BASH_SOURCE[0]}" && exit 0
[ -n "$SESSION" ] && [ -n "$TOOL" ] || exit 0
# 이 세션의 작업이 없으면 아무것도 강제하지 않는다. 아래 엔진 명령 면제 판정보다 먼저 본다 —
# 작업 없는 세션의 Bash 마다 정규식 grep 세 번을 돌릴 이유가 없다.
TASK="$(bouncer_my_task "$CWD" "$SESSION")" || exit 0
SESSION_CWD="$CWD"                    # 상대 경로는 세션 폴더 기준으로 푼다
CWD="$(bouncer_task_root "$TASK")"   # 보호 경로·설정은 작업을 시작한 레포 기준

# 아래 차단들은 전부 "bouncer cancel / check 로 정리하라"를 안내한다.
# 그 명령까지 막으면 모델이 빠져나갈 길이 없다 — 엔진 명령은 먼저 통과시킨다.
# 단 **연산자가 하나도 없는 순수 호출**만. 접두로 인정하면
# `bouncer scan && rm -rf x` 가 통째로 빠져나간다 (감사에서 실제로 뚫렸다).
if [ "$TOOL" = "Bash" ]; then
  _C="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
  _ROOT="$(bouncer_project_root "$CWD")"
  # 전역 엔진 경로(이 훅과 같은 설치본)로 부르는 것도 인정한다.
  _ENG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../engine" && pwd)/bouncer\.sh"
  # grep 의 `^…$` 는 **줄** 앵커다. 명령 어딘가에 `bouncer` 한 줄만 끼우면
  # 통째로 통과했다 (감사에서 실제로 뚫렸다). 개행이 있으면 아예 면제하지 않는다.
  case "$_C" in
    *"
"*) ;;
    *)
      # 경로 형태는 **이 프로젝트의 설치본**만 인정한다. 접미사만 보면
      # /tmp/e/.claude/ai-bouncer/engine/bouncer.sh 를 심어 hook 을 끌 수 있다.
      if printf '%s' "$_C" | grep -Eq '^[[:space:]]*bouncer([[:space:]]+[^;&|<>()`$'"'"'"]*)?[[:space:]]*$' \
         || printf '%s' "$_C" | grep -qE "^[[:space:]]*(\./)?${_ROOT//\//\\/}/\.claude/ai-bouncer/engine/bouncer\.sh([[:space:]]+[^;&|<>()\`\$'\"]*)?[[:space:]]*$" \
         || printf '%s' "$_C" | grep -qE "^[[:space:]]*(\./)?\.claude/ai-bouncer/engine/bouncer\.sh([[:space:]]+[^;&|<>()\`\$'\"]*)?[[:space:]]*$" \
         || printf '%s' "$_C" | grep -qE "^[[:space:]]*${_ENG//\//\\/}([[:space:]]+[^;&|<>()\`\$'\"]*)?[[:space:]]*$"; then
        exit 0
      fi ;;
  esac
fi

# 도구 호출 수를 센다. Stop 이 "직전 차단 이후 모델이 아무것도 안 했다"를
# 알아야 백그라운드 작업 대기를 무한 차단 루프로 만들지 않는다. state.json 잠금을
# 타면 매 호출이 느려지므로 별도 파일에 덮어쓴다.
_SEQ="$(cat "$TASK/.tool_seq" 2>/dev/null)"; case "$_SEQ" in ''|*[!0-9]*) _SEQ=0 ;; esac
printf '%s' "$(( _SEQ + 1 ))" > "$TASK/.tool_seq" 2>/dev/null || true

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

# ── 엔진 전용 파일 보호 ───────────────────────────────────────
# 이 파일들을 고치면 단계 건너뛰기나 hook 무력화가 가능해진다.
case "$TOOL" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
FILE_PATH="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' <<<"$INPUT")"
[ -n "$FILE_PATH" ] || exit 0
# `python3 -S` 로 site 초기화를 건너뛴다 — Homebrew python 은 기동 시간 대부분(약 230ms → 50ms)을 썼다.
GUARD="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/engine/lib/guard.py"
if [ ! -f "$GUARD" ] || ! command -v python3 >/dev/null 2>&1; then
  bouncer_block "⛔ [ai-bouncer / $STAGE] 경로 판정기를 사용할 수 없다 ($GUARD). 설치가 손상됐을 수 있다 — 다시 설치하라."
fi
R="$(python3 -S "$GUARD" --check-path "$(bouncer_project_root "$CWD")" "$FILE_PATH" "$SESSION_CWD" 2>/dev/null)" \
  || bouncer_block "⛔ [ai-bouncer / $STAGE] 경로 판정 중 오류가 발생했다. 안전을 위해 차단한다."
[ -n "$R" ] && bouncer_block "⛔ [ai-bouncer / $STAGE] $R"
exit 0
