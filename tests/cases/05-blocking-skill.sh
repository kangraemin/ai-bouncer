#!/usr/bin/env bash
# 케이스 5 — blocking: skill:<이름> 은 스킬을 실제로 호출해야만 통과한다 (자기신고 불가)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/skill.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "정책 정리" >/dev/null

stop >/dev/null; [ "$(stage)" = policy ] && ok "policy 유지 (스킬 미실행)" || no "유지" "$(stage)"
says '스킬을 실제로 실행' bouncer done "policy/정책 정리" && ok "bouncer done으로 우회 불가" || no "우회 차단"

# 다른 스킬을 호출해도 통과되면 안 된다
hook post-tool "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"other\"}}"
stop >/dev/null; [ "$(stage)" = policy ] && ok "다른 스킬로는 통과 못 함" || no "오탐" "$(stage)"

hook post-tool "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"policy-cleanup\"}}"
[ "$(state '.evidence["policy/정책 정리"]')" = true ] && ok "해당 스킬 호출을 관찰해 기록" || no "관찰 기록"
stop >/dev/null; [ "$(stage)" = done ] && ok "done으로 전이" || no "전이" "$(stage)"
finish
