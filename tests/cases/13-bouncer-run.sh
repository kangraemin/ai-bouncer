#!/usr/bin/env bash
# 케이스 13 — by: model 경로. 모델이 `bouncer run`으로 실행하고 엔진이 종료코드로 판정한다.
#              명령 문자열은 엔진(compiled.json)이 소유하므로 모델이 바꿔치기할 수 없다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 픽스처는 케이스마다 따로 둔다. 전역 경로를 쓰면 케이스끼리 덮어쓴다.
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_run.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - label: 게이트
        run: 'test -f PASS'
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_run.yaml" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "run 경로" >/dev/null

[ "$(jq -r '.stages.verify.steps[0].by' .claude/ai-bouncer/workflow.compiled.json)" = model ] \
  && ok "by 기본값이 model" || no "by 기본값"

out=$(stop); printf '%s' "$out" | jq -r '.reason' | grep -q '게이트' && ok "실행 지시 주입" || no "실행 지시"
[ "$(stage)" = verify ] && ok "실행 전엔 못 넘어감" || no "게이트" "$(stage)"

says '실패' bouncer run "verify/게이트" && ok "실패하면 실패로 보고" || no "실패 보고"
[ "$(state '.evidence["verify/게이트"]')" = false ] && ok "실패는 evidence=false" || no "실패 기록"
[ "$(state '.attempts["verify/게이트"]')" = 1 ] && ok "시도 횟수 누적" || no "시도 누적"

says '없다' bouncer run "verify/존재안함" && ok "없는 step은 거부" || no "없는 step 거부"
says '실행 step이다' bouncer done "verify/게이트" && ok "run step은 done으로 우회 불가" || no "done 우회 차단"
stop >/dev/null; [ "$(stage)" = verify ] && ok "우회 시도 후에도 못 넘어감" || no "우회 차단" "$(stage)"

touch PASS
bouncer run "verify/게이트" >/dev/null && ok "조건 충족하면 통과" || no "통과"
[ "$(state '.evidence["verify/게이트"]')" = true ] && ok "성공은 evidence=true" || no "성공 기록"
stop >/dev/null; [ "$(stage)" = done ] && ok "done으로 전이" || no "전이" "$(stage)"
finish
