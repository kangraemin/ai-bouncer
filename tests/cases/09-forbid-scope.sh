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
# `!docs/**` 는 "여기는 써도 된다"는 뜻이다. 셸도 같은 스코프를 따라야 한다.
# (예전엔 배열이어도 전면 읽기 전용으로 다뤄서, 구현 단계에 스코프를 걸면
#  npm test 조차 못 돌리는 죽은 스테이지가 됐다)
r=$(pre Bash "{\"command\":\"echo x > docs/plan.md\"}"); [ -z "$r" ] && ok "예외 경로에는 셸로도 쓸 수 있다" || no "예외 경로 차단됨" "$r"
r=$(pre Bash "{\"command\":\"rm -f docs/old.md\"}");     [ -z "$r" ] && ok "예외 경로 삭제도 허용" || no "삭제 차단됨"
r=$(pre Bash "{\"command\":\"rm -f src/app.js\"}");      [ -n "$r" ] && ok "스코프 밖 삭제는 차단" || no "삭제 통과됨"
r=$(pre Bash "{\"command\":\"cp src/app.js docs/copy.js\"}"); [ -z "$r" ] && ok "스코프 밖에서 읽어 예외 경로에 쓰기" || no "읽기 원본까지 막힘" "$r"
r=$(pre Bash "{\"command\":\"npm test\"}");              [ -z "$r" ] && ok "스코프 모드에선 임의 명령 실행 가능" || no "npm test 차단됨" "$r"
r=$(pre Bash "{\"command\":\"git checkout -- .\"}");     [ -n "$r" ] && ok "워킹트리 되돌리기는 차단" || no "git checkout 통과"
r=$(pre Bash "{\"command\":\"cat docs/plan.md\"}");      [ -z "$r" ] && ok "읽기는 자유" || no "읽기 차단됨"
r=$(pre Bash "{\"command\":\"bouncer status\"}");     [ -z "$r" ] && ok "bouncer 명령은 항상 허용" || no "bouncer 허용"
finish
