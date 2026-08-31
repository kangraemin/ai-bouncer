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
r=$(pre Bash "{\"command\":\"echo x > docs/plan.md\"}"); [ -z "$r" ] && ok "docs/ 셸 쓰기 허용" || no "docs 셸 허용" "차단됨"
r=$(pre Bash "{\"command\":\"bouncer status\"}");     [ -z "$r" ] && ok "bouncer 명령은 항상 허용" || no "bouncer 허용"
finish
