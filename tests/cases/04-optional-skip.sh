#!/usr/bin/env bash
# 케이스 4 — 시작할 때 끈 optional step은 실행되지 않고, 켜면 게이트로 작동한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/optional.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

OPTS="$(bouncer options plan)"
printf '%s' "$OPTS" | grep -q '선택검사' && ok "options가 선택 항목을 나열" || no "options"

# 끈 채로 시작 — 실패하는 선택검사를 건너뛰므로 통과해야 한다
bouncer start plan "옵션 끔" --off "verify/선택검사" >/dev/null
[ "$(state '.choices["verify/선택검사"]')" = false ] && ok "choices에 off 기록" || no "choices off"
stop >/dev/null
[ "$(stage)" = done ] && ok "끈 항목은 게이트로 안 걸림" || no "skip 동작" "$(stage)"

cleanup; setup "$R/tests/fixtures/optional.yaml" >/dev/null || exit 1
# 켠 채로 시작 — 실패하는 검사가 게이트로 작동해 못 넘어가야 한다
bouncer start plan "옵션 켬" >/dev/null
[ "$(state '.choices["verify/선택검사"]')" = true ] && ok "기본값은 켜짐" || no "기본값"
stop >/dev/null
[ "$(stage)" = verify ] && ok "켠 항목은 게이트로 작동" || no "게이트 작동" "$(stage)"
finish
