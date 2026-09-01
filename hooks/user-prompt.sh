#!/usr/bin/env bash
# UserPromptSubmit — 사용자가 실제로 입력했다는 사실만 기록한다.
#
# `inject` + `blocking: true` 는 "사람이 실제로 답해야 통과"를 뜻한다.
# 그걸 확인할 수단이 이 hook뿐이다. 이게 없으면 모델이 같은 턴에
# `bouncer done` 을 쳐서 통과할 수 있고, 그러면 게이트가 자기 보고가 된다.
#
# 프롬프트 내용은 읽지도 저장하지도 않는다. 턴이 발생했다는 카운터만 올린다.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
SESSION="$(jq -r '.session_id // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"
[ -n "$CWD" ] || CWD="$PWD"
[ -n "$SESSION" ] || exit 0

TASK="$(bouncer_my_task "$CWD" "$SESSION")" || exit 0
bouncer_state_update "$TASK" '.user_turns = ((.user_turns // 0) + 1)'
exit 0
