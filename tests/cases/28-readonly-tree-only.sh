#!/usr/bin/env bash
# 케이스 28 — 읽기 전용(verify)은 **프로젝트 작업 트리 수정**만 막는다.
#
# 2026-10-18 ttuk-chiro-clinic: verify 에서 브라우저 캐시가 지워져 e2e 가 실패했는데
#   `playwright install chromium`, `npm run e2e`, `f=$(ls -t …); grep … "$f"` 가 전부
#   "파일을 쓸 수 있어 허용되지 않는다"로 막혔고, implement 로 돌아가도 고칠 소스가 없어
#   "작업 트리가 그대로다"로 계속 갇혔다.
# 이제 판정은 명령 이름이 아니라 "작업 트리를 바꿨나"다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [implement, verify, done]}
stages:
  implement:
    steps: [{label: 구현, inject: "구현."}]
  verify:
    on_fail: implement
    steps:
      - {label: 필수검사, run: "test -f ok.txt", blocking: true}
      - {label: 보고, blocking: done, inject: "보고해라."}
    forbid: {edit_files: true, reason: 읽기 전용}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR" "$CACHE"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
CACHE="$(mktemp -d)"
printf 'test-results/\ndist-shot/\n' >> .gitignore; git add .gitignore; git commit -qm ign
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }
post(){ hook post-tool "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x\"}}"; }

bouncer start plan ro >/dev/null
echo "new work" > feature.js          # 구현 단계의 미커밋 새 파일
echo "edited" >> app.js               # 구현 단계의 미커밋 수정
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify 로 간다" || no "전이" "$(stage)"
[ -n "$(state '.ro_base.tree // empty')" ] && ok "verify 진입 때 작업 트리 기준선을 찍는다" || no "기준선 없음" "$(state .ro_base)"

# ── 막혔던 사례 3가지 + 환경 작업은 허용 ──
allowed(){ r=$(pre Bash "$(jq -n --arg c "$1" '{command:$c}')"); [ -z "$r" ]; }
group "도구 설치·테스트 실행·셸 문법은 허용" allowed <<X
./node_modules/.bin/playwright install chromium
npm run e2e -- --reporter=line
f=\$(ls -t test-results 2>/dev/null | head -1); grep -n error "\$f"
npx playwright --version
PLAYWRIGHT_BROWSERS_PATH=$CACHE npx playwright install chromium
mkdir -p $CACHE/ms-playwright && touch $CACHE/ms-playwright/x
printf x > /tmp/bouncer-ro-test.txt
for f in a b; do echo \$f; done
( cd /tmp && ls )
python3 -m venv .venv-ignored-or-not
echo hi > test-results/report.txt
rm -rf dist-shot
X

# ── 작업 트리를 직접 바꾸는 명령은 여전히 사전 차단 ──
blocked(){ r=$(pre Bash "$(jq -n --arg c "$1" '{command:$c}')"); isblock "$r"; }
group "프로젝트 소스를 직접 고치는 명령은 막는다" blocked <<'X'
sed -i '' s/hello/bye/ app.js
echo x > app.js
rm app.js
cp /etc/hosts src.js
git checkout -- app.js
git stash
X
r=$(pre Write "{\"file_path\":\"$T/app.js\",\"content\":\"x\"}"); isblock "$r" && ok "소스 Write 는 막는다" || no "소스 Write 통과" ""
r=$(pre Edit "{\"file_path\":\"$T/feature.js\",\"old_string\":\"a\",\"new_string\":\"b\"}"); isblock "$r" && ok "구현 중 만든 새 파일 Edit 도 막는다" || no "새 파일 Edit 통과" ""
r=$(pre Write "{\"file_path\":\"$T/test-results/r.txt\",\"content\":\"x\"}"); [ -z "$r" ] && ok ".gitignore 된 산출물 Write 는 허용" || no "ignored Write" "${r:0:100}"
r=$(pre Write "{\"file_path\":\"$CACHE/cfg.json\",\"content\":\"x\"}"); [ -z "$r" ] && ok "작업 트리 밖 Write 는 허용" || no "밖 Write" "${r:0:100}"
r=$(pre Bash '{"command":"printf x > ~/.claude/settings.json"}'); isblock "$r" && ok "~/.claude 는 계속 막는다" || no "~/.claude 통과" ""
r=$(pre Bash '{"command":"rm -rf .ai-bouncer"}'); isblock "$r" && ok "엔진 디렉토리 삭제는 계속 막는다" || no "엔진 삭제 통과" ""

# ── 사전에 못 본 쓰기(스크립트 안)는 실행 뒤 트리 비교가 잡는다 ──
mkdir -p test-results && echo r > test-results/out.txt; mkdir -p "$CACHE/x"
r=$(post); [ -z "$r" ] && ok "무시된 경로·트리 밖 쓰기 뒤에는 조용하다" || no "오탐" "${r:0:120}"
echo sneaky >> app.js; echo new > leaked.js; echo more >> feature.js
r=$(post)
isblock "$r" && printf '%s' "$r" | jq -r .reason | grep -q 'app.js' \
  && printf '%s' "$r" | jq -r .reason | grep -q 'bouncer restore' \
  && ok "명령 뒤 작업 트리가 바뀌면 경로와 함께 알린다" || no "사후 감지" "${r:0:160}"
r=$(hook post-tool "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x\"}}")
isblock "$r" && ok "실패한 명령 뒤에도 감지한다" || no "실패 후 감지" "${r:0:120}"
touch ok.txt   # 무시 안 된 새 파일 — 이것도 트리 변경이다
r=$(stop); isblock "$r" && printf '%s' "$r" | jq -r .reason | grep -q 'bouncer restore' \
  && ok "바뀐 채로는 단계를 끝낼 수 없다" || no "Stop 통과" "${r:0:160}"
[ "$(stage)" = verify ] && ok "단계는 그대로" || no "전이됨" "$(stage)"
out="$(bouncer restore 2>&1)"
printf '%s' "$out" | grep -q RESTORED && ok "bouncer restore 로 되돌린다" || no "restore" "$out"
[ "$(cat app.js)" = "$(printf 'hello\nedited')" ] && ok "구현 단계 수정은 남기고 verify 수정만 되돌린다" || no "app.js" "$(cat app.js)"
[ "$(cat feature.js)" = "new work" ] && ok "구현 단계 새 파일 내용도 복원" || no "feature.js" "$(cat feature.js)"
[ ! -e leaked.js ] && [ ! -e ok.txt ] && ok "verify 에서 생긴 새 파일은 지운다" || no "새 파일 잔존" "$(ls)"
[ -f test-results/out.txt ] && ok "무시된 산출물은 건드리지 않는다" || no "산출물 삭제됨" ""
git diff --cached --quiet && ok "진짜 인덱스는 건드리지 않는다" || no "인덱스 변경" "$(git diff --cached --stat)"
r=$(post); [ -z "$r" ] && ok "되돌린 뒤엔 조용하다" || no "잔여 감지" "${r:0:120}"
bouncer restore 2>&1 | grep -q CLEAN && ok "바뀐 게 없으면 restore 는 CLEAN" || no "CLEAN"

# ── 반송 뒤 트리 그대로여도, 도구를 썼다면 재검증 허용 (원인이 환경일 수 있다) ──
bouncer run 'verify/필수검사' >/dev/null 2>&1
stop >/dev/null
[ "$(stage)" = implement ] && ok "검증 실패로 implement 반송" || no "반송" "$(stage)"
r=$(stop); isblock "$r" && printf '%s' "$r" | jq -r .reason | grep -q '그대로' \
  && ok "아무것도 안 하고 멈추면 여전히 막는다" || no "무행동 통과" "${r:0:160}"
pre Bash '{"command":"npx playwright install chromium"}' >/dev/null   # 환경 정리 (트리 변화 없음)
r=$(stop)
[ "$(stage)" = verify ] && ok "트리가 그대로여도 도구를 썼으면 verify 재진입" || no "재진입 막힘" "$(stage) ${r:0:160}"
finish
