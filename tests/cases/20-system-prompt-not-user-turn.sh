#!/usr/bin/env bash
# 케이스 20 — 사람이 아닌 UserPromptSubmit 은 사람 턴이 아니다.
#
# UserPromptSubmit 은 백그라운드 작업 완료 알림(<task-notification>)과
# 시스템 리마인더에도 불린다. 그걸 사람 턴으로 세면 모델이 백그라운드 작업을
# 띄우고 기다리기만 해도 inject+blocking("사람 확인") 게이트가 열린다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

turns(){ state '.user_turns // 0'; }
prompt_turn(){ hook user-prompt "$1" >/dev/null; }

bouncer start simple sysprompt >/dev/null
BASE="$(turns)"

echo
echo "[사람이 아닌 입력은 세지 않는다]"
prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"<task-notification> <task-id>x</task-id> <status>completed</status> </task-notification>\"}"
[ "$(turns)" = "$BASE" ] && ok "task-notification 무시" || no "task-notification 무시" "$(turns) != $BASE"

prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"<system-reminder>x</system-reminder>\"}"
[ "$(turns)" = "$BASE" ] && ok "system-reminder 무시" || no "system-reminder 무시" "$(turns) != $BASE"

prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"평범한 문장\",\"origin\":{\"kind\":\"task-notification\"}}"
[ "$(turns)" = "$BASE" ] && ok "origin.kind≠human 무시" || no "origin.kind≠human 무시" "$(turns) != $BASE"

prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"평범한 문장\",\"turnOrigin\":\"task_notification\"}"
[ "$(turns)" = "$BASE" ] && ok "turnOrigin≠human 무시" || no "turnOrigin≠human 무시" "$(turns) != $BASE"


echo
echo "[사람 입력은 센다]"
prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"계속해\",\"origin\":{\"kind\":\"human\"}}"
[ "$(turns)" -gt "$BASE" ] && ok "origin.kind=human 카운트" || no "origin.kind=human 카운트" "$(turns)"


N="$(turns)"
prompt_turn "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"prompt\":\"출처 필드 없는 구버전 입력\"}"
[ "$(turns)" -gt "$N" ] && ok "출처 필드 없는 사람 입력 카운트" || no "출처 필드 없는 사람 입력 카운트" "$(turns)"

finish
