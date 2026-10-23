#!/usr/bin/env bash
# 케이스 27 — verify 에서 갇히지 않는다.
#
# 2026-10-17: verify 에서 optional 스크린샷이 .venv 가 없어 실패했는데
# 미실행으로 취급돼 on_fail 반송도 skip 제안도 안 나왔다.
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
      - {label: 선택검사, run: "exit 3", blocking: true, optional: true}
      - {label: 필수검사, run: "test -f ok.txt", blocking: true}
      - {label: 보고, blocking: done, inject: "보고해라."}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

bouncer start plan vf >/dev/null
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify 로 간다" || no "전이" "$(stage)"

# ── run 실패는 done 대기와 상관없이 on_fail 로 반송 ──
# (optional 은 "시작할 때 끌 수 있다"는 뜻이다. 켜져 있으면 게이트다 — 케이스 4)
bouncer run 'verify/선택검사' >/dev/null 2>&1
r=$(stop)
printf "%s" "$r" | jq -r .reason | grep -q "실패 (1회)" && ok "실패한 run 은 미실행이 아니라 실패로 알린다" || no "실패 표기" "${r:0:160}"
bouncer run 'verify/선택검사' >/dev/null 2>&1      # max_attempts(2) 소진
r=$(stop)
[ "$(stage)" = implement ] && ok "보고 done 이 남아 있어도 on_fail 로 반송" || no "반송" "$(stage)"
[ "$(state '.attempts["verify/선택검사"] // 0')" = 0 ] && ok "반송하면 run 실패 횟수도 지운다" || no "attempts 잔존" "$(state .attempts)"
finish
