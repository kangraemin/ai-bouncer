#!/usr/bin/env bash
# 케이스 32 — 검증 명령이 없으면(exit 127) 반송하지 않고, 두 번째엔 사람에게 넘긴다.
# 그리고 지시만 하는 step 에 `bouncer done`, `bouncer help` 는 오류 없이 처리한다.
#
# 2026-10-22 감사: exit 127 6건. 코드를 고쳐도 안 풀리는데 일반 실패처럼 구현 단계로
# 반송돼 왕복만 쌓였다. `는 blocking이 아니다` 거절 258건, `알 수 없는 명령: help` 44건.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_127.yaml" <<'Y'
version: 1
workflows:
  simple: {label: 테스트용, stages: [implement, verify, done]}
stages:
  implement:
    steps: [{label: 구현, inject: "구현해라."}]
  verify:
    on_fail: implement
    steps:
      - {label: 검사, run: "no_such_cmd_ai_bouncer_xyz", blocking: true}
      - {label: 보고, inject: "보고해라."}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_127.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start simple missing >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] || abort_setup "verify 진입" "$(stage)"

says '표시할 것 없다' bouncer done "verify/보고" && ok "지시만 하는 step 에 done 은 오류 없이 안내" || no "done 거절"
bouncer done "verify/보고" >/dev/null 2>&1 && ok "종료 코드 0" || no "done 실패 코드"
says 'bouncer scan' bouncer help && ok "bouncer help 는 사용법" || no "help 미지원"

says 'exit 127' bouncer run "verify/검사" && ok "run 이 명령 없음을 알린다" || no "127 안내 없음"
r=$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')
printf '%s' "$r" | grep -q '명령을 찾을 수 없다' && ok "Stop 이 명령 없음으로 판정" || no "판정 문구" "${r:0:100}"
[ "$(stage)" = verify ] && ok "구현 단계로 반송하지 않는다" || no "반송됨" "$(stage)"

bouncer run "verify/검사" >/dev/null 2>&1
r=$(stop)
printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 && no "두 번째도 막음" "${r:0:80}" || ok "두 번째엔 막지 않고 넘긴다"
printf '%s' "$r" | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -q "bouncer skip 'verify/검사'" \
  && ok "건너뛰기 선택지를 준다" || no "skip 안내 없음" "${r:0:120}"
says 'SKIPPED' bouncer skip "verify/검사" && ok "제안한 skip 은 열린다" || no "skip 거부"
finish
