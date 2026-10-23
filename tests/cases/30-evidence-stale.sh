#!/usr/bin/env bash
# 케이스 30 — 검증 통과 기록은 그때의 코드 내용에 묶인다.
#
# 2026-10-22 transcript 감사: verify 에서 `bouncer run` 통과 뒤 코드를 고치고 그대로
# finalize 로 넘어간 경우가 291번 중 5번. 읽기 전용으로 쓰기를 미리 막는 대신,
# 통과 뒤 추적 파일 내용이 바뀌면 그 통과를 무효로 돌려 다시 돌리게 한다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_ev.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 검사, run: "grep -q ok app.js", blocking: true}
      - {label: 보고, blocking: done, inject: "보고해라."}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_ev.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=10 >/dev/null
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
export CLAUDE_CODE_SESSION_ID=S1
echo ok > app.js; git add app.js; git commit -qm app
bouncer start plan "증거" >/dev/null

bouncer run "verify/검사" >/dev/null && ok "통과 기록" || no "첫 실행"
[ -n "$(state '.evidence_tree["verify/검사"] // ""')" ] && ok "통과 때 코드 지문을 남긴다" || no "지문 없음"

# 추적 안 되는 산출물과 커밋은 코드 내용을 안 바꾼다
echo r > report.html
git add app.js; git commit -qm same --allow-empty
stop >/dev/null
[ "$(state '.evidence["verify/검사"]')" = true ] && ok "산출물·커밋으로는 무효가 안 된다" || no "오탐 무효"

# 새 파일을 만들어 통과시킨 뒤 커밋해도 내용은 그대로다 (커밋마다 검사를 다시 돌렸다)
echo new > lib.js
bouncer run "verify/검사" >/dev/null
git add lib.js; git commit -qm lib
stop >/dev/null
[ "$(state '.evidence["verify/검사"]')" = true ] && ok "새 파일을 커밋해도 무효가 안 된다" || no "커밋으로 무효"
echo changed > lib.js
stop >/dev/null
[ "$(state '.evidence["verify/검사"]')" = false ] && ok "그 파일을 고치면 무효" || no "수정 놓침"
bouncer run "verify/검사" >/dev/null

# 통과 뒤 코드를 고친다
echo 'ok // fix' > app.js
r=$(stop | jq -r '.reason // ""')
printf '%s' "$r" | grep -q "통과한 뒤 코드가 바뀌었다" && ok "고치면 다시 돌리라고 알린다" || no "안내 없음" "${r:0:120}"
[ "$(state '.evidence["verify/검사"]')" = false ] && ok "이전 통과는 무효" || no "무효 처리"
[ "$(stage)" = verify ] && ok "다음 단계로 안 넘어간다" || no "넘어감" "$(stage)"

bouncer run "verify/검사" >/dev/null && bouncer done "verify/보고" >/dev/null
stop >/dev/null
[ "$(stage)" = done ] && ok "다시 돌려 통과하면 넘어간다" || no "전이" "$(stage)"

finish
