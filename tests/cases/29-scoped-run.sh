#!/usr/bin/env bash
# 케이스 29 — bouncer scope. run 명령의 {scope} 자리에 이번 작업이 건드린 테스트만 넣어 돌린다.
#              안 적으면 전체, 적으면 그것만. 경로만 받고, 범위가 바뀌면 이전 통과는 무효다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_scope.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - label: e2e
        run: 'printf "%s\n" {scope} > RAN; for f in {scope}; do grep -q ok "$f" || exit 1; done; [ -n "$(cat RAN)" ] || ! grep -q bad t/*.txt'
        blocking: true
      - label: 빌드
        run: 'true && true'
        blocking: true
      - label: 단일
        run: 'bash t/rec.sh'
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_scope.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "범위" >/dev/null
mkdir -p t; echo ok > t/a.txt; echo bad > t/b.txt; echo ok > "t/c d.txt"
# 받은 인자를 적고, 인자가 없으면(전체) bad 가 섞여 실패한다
printf '%s\n' 'printf "%s\n" "$@" > ARGS; [ $# -gt 0 ] || set -- t/a.txt t/b.txt; for f in "$@"; do grep -q ok "$f" || exit 1; done' > t/rec.sh

out=$(stop); printf '%s' "$out" | jq -r '.reason' | grep -q "bouncer scope 'verify/e2e'" \
  && ok "범위 지정 방법을 안내" || no "범위 안내"
bouncer status | grep -q '범위: 전체' && ok "status에 전체로 보임" || no "status 범위"

says '실패' bouncer run "verify/e2e" && ok "범위 없으면 전체를 돌린다 (b가 섞여 실패)" || no "전체 실행"

bouncer scope "verify/e2e" t/a.txt "t/c d.txt" >/dev/null && ok "범위 지정" || no "범위 지정"
bouncer run "verify/e2e" >/dev/null && ok "범위만 돌려 통과" || no "범위 통과"
[ "$(sed -n 1p RAN)" = "t/a.txt" ] && [ "$(sed -n 2p RAN)" = "t/c d.txt" ] \
  && ok "공백 든 경로도 하나로 넘긴다" || no "인자 전달" "$(cat RAN)"
bouncer status | grep -q '범위: t/a.txt t/c d.txt' && ok "status에 범위 표시" || no "status 표시"

bouncer scope "verify/e2e" t/b.txt >/dev/null
[ "$(state '.evidence["verify/e2e"]')" = false ] && ok "범위를 바꾸면 이전 통과 무효" || no "증거 초기화"

says '경로만' bouncer scope "verify/e2e" --list && ok "옵션은 거부" || no "옵션 거부"
says '없는 경로' bouncer scope "verify/e2e" t/zzz.txt && ok "없는 경로 거부" || no "없는 경로"
bouncer scope "verify/e2e" t/a.txt:3 >/dev/null && ok "줄 번호 붙은 경로 허용" || no "줄 번호"
says '이어져 있어' bouncer scope "verify/빌드" t/a.txt && ok "{scope} 없이 이어진 명령은 거부" || no "이어진 명령 거부"
says '실패' bouncer run "verify/단일" && ok "{scope} 없는 단일 명령도 범위 없으면 전체" || no "단일 전체"
r=$(stop | jq -r '.reason // ""'); printf '%s' "$r" | grep -q "실패가 이번 작업과 무관하면" \
  && ok "전체 실패 뒤 범위로 좁히라고 안내" || no "실패 뒤 안내" "${r:0:80}"
bouncer scope "verify/단일" "t/c d.txt" >/dev/null && ok "{scope} 없는 단일 명령도 범위 지정" || no "단일 범위 지정"
bouncer run "verify/단일" >/dev/null && [ "$(cat ARGS)" = "t/c d.txt" ] \
  && ok "단일 명령은 범위를 끝에 붙여 돌린다" || no "끝에 붙이기" "$(cat ARGS 2>/dev/null)"

bouncer scope "verify/e2e" --clear >/dev/null
[ "$(state '.scope["verify/e2e"] // "none"')" = none ] && ok "--clear로 전체로 되돌림" || no "clear"

bouncer scope "verify/e2e" t/a.txt >/dev/null
bouncer run "verify/e2e" >/dev/null; bouncer run "verify/빌드" >/dev/null
stop >/dev/null; [ "$(stage)" = done ] && ok "범위만 통과해도 다음 단계로" || no "전이" "$(stage)"
finish
