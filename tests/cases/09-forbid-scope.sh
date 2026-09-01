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
# 스코프 모드에서 흔한 명령이 막히면 사용자가 도구를 꺼버린다.
# (모드 인자를 경로로 오인, worktree 상대경로, git dry-run 등이 전부 여기서 걸렸다)
# 스코프 모드에서 흔한 명령이 막히면 사용자가 도구를 꺼버린다.
OVER=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  r=$(pre Bash "$(jq -nc --arg c "$c" '{command:$c}')")
  [ -z "$r" ] || { printf '     ↳ %s → %s\n' "$c" "${r:0:60}"; OVER=1; }
done <<'PASSCASES'
echo "$(date)"
echo "$(grep -c x docs/plan.md)"
git commit -m "$(cat msg.txt)"
tar -czf /tmp/o.tgz docs
rsync -a /tmp/b/ docs/d/
split -b 1m /tmp/big docs/c_
tar --directory=docs -xf /tmp/a.tgz
chmod 755 docs/plan.md
chown ram:staff docs/plan.md
truncate -s 0 docs/plan.md
mkdir -m 700 docs/sub
cp src/app.js docs/copy.js
npm test
git fetch origin
git checkout -b feature
git restore --staged docs/plan.md
git clean -n
ls a*
awk -F '|' '{print $2}' docs/plan.md
PASSCASES
[ "$OVER" = 0 ] && ok "스코프 모드에서 흔한 명령은 통과 (19건)" || no "스코프 모드 과차단" "위 항목"

UNDER=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  r=$(pre Bash "$(jq -nc --arg c "$c" '{command:$c}')")
  [ -n "$r" ] || { printf '     ↳ %s\n' "$c"; UNDER=1; }
done <<'BLOCKCASES'
cp b.js "$(echo src/app.js)"
echo "$(rm -f src/app.js; echo '(')"
tar -czf src/app.js docs
tar xf /tmp/evil.tar
chmod 755 src/app.js
mv src/app.js src/x.js
rm -rf src
git clean -fdx
sort -osrc/out.txt docs/plan.md
curl -osrc/x.js http://x
BLOCKCASES
[ "$UNDER" = 0 ] && ok "스코프 밖 쓰기는 여전히 차단 (10건)" || no "스코프 밖 쓰기 통과" "위 항목"


finish
