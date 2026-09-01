#!/usr/bin/env bash
# 케이스 9 — forbid.edit_files 경로 스코프: 계획 단계에서도 docs/ 는 쓸 수 있어야 한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/scope.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "스코프" >/dev/null

r=$(pre Edit "{\"file_path\":\"$T/src/app.js\"}");   [ -n "$r" ] && ok "src/ 수정 차단" || no "src 차단"
r=$(pre Write "{\"file_path\":\"$T/docs/plan.md\"}"); [ -z "$r" ] && ok "docs/ 는 예외로 허용" || no "docs 허용" "차단됨"
r=$(pre Bash "{\"command\":\"echo x > src/a.js\"}");  [ -n "$r" ] && ok "src/ 셸 우회 차단" || no "셸 우회 차단"
# 읽기 전용 단계에서는 셸 리다이렉트를 경로와 무관하게 막는다.
# 무엇을 쓰는지 셸 문법만으로는 확실히 알 수 없기 때문이다.
# 허용된 경로에 쓰는 것은 Edit/Write 도구로 하면 되고, 그건 스코프대로 통과한다.
r=$(pre Bash "{\"command\":\"echo x > docs/plan.md\"}"); [ -n "$r" ] && ok "읽기 전용 단계에선 셸 리다이렉트 전면 차단" || no "리다이렉트 차단"
r=$(pre Bash "{\"command\":\"cat docs/plan.md\"}");      [ -z "$r" ] && ok "읽기는 자유" || no "읽기 차단됨"
r=$(pre Bash "{\"command\":\"bouncer status\"}");     [ -z "$r" ] && ok "bouncer 명령은 항상 허용" || no "bouncer 허용"
finish
