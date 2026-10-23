#!/usr/bin/env bash
# 케이스 3 — verify 실패 시 implement로 반송되고, 고친 뒤 다시 통과한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/on-fail.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

bouncer start plan "반송 테스트" >/dev/null
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify 진입" || no "verify 진입" "$(stage)"

# max_attempts(2)까지는 제자리에서 고칠 기회를 준다. 소진하면 반송한다.
stop >/dev/null; [ "$(stage)" = verify ] && ok "1회 실패는 제자리 유지" || no "제자리 유지" "$(stage)"
out=$(stop); [ "$(stage)" = implement ] && ok "max_attempts 소진 후 implement 반송" || no "반송" "$(stage)"
printf '%s' "$out" | jq -r '.reason' | grep -q '되돌아간다' && ok "반송 사유 주입" || no "반송 사유"
[ "$(state '.evidence["verify/게이트"]')" = null ] && ok "반송 시 verify 진행기록 초기화" || no "기록 초기화"

# 조건 충족시키고 다시
touch PASS
stop >/dev/null; [ "$(stage)" = verify ] && ok "다시 verify 진입" || no "재진입" "$(stage)"
stop >/dev/null; [ "$(stage)" = done ] && ok "이번엔 통과해 done" || no "통과" "$(stage)"
h=$(state '[.history[] | select(.returned_from)] | length')
[ "$h" = 1 ] && ok "history에 반송 기록" || no "history 기록" "$h"
finish
