#!/usr/bin/env bash
# 케이스 21 — done 전에는 사람을 기다리지 않고, 기다리는 동안 Stop 이 턴을 계속 깨우지 않는다.
#
# 1) 기본 워크플로우에서 사용자 턴 없이 done 까지 간다 (중간에 승인을 물을 이유가 없다).
# 2) 직전 차단 이후 도구를 하나도 안 쓰고 다시 멈추면(백그라운드 작업 대기) 차단하지 않는다.
#    도구를 쓴 뒤 멈추면 다시 차단한다.
# 3) 사람 대기(plan 승인) 상태에서 재진입한 Stop 은 출력 없이 멈춘다
#    (additionalContext 는 턴을 다시 열어 9회 상한까지 돈다).
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }

echo
echo "[사용자 턴 없이 done 까지]"
bouncer start simple noask >/dev/null
stop >/dev/null
bouncer todo add 'x' >/dev/null; bouncer todo done 1 >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] && ok "implement → verify (사람 턴 없음)" || no "implement 전이" "$(stage)"
bouncer done "verify/검증 보고" >/dev/null
stop >/dev/null; [ "$(stage)" = finalize ] && ok "verify → finalize (사람 턴 없음)" || no "verify 전이" "$(stage)"
[ "$(state '.user_turns // 0')" = 0 ] && ok "사용자 턴 0회" || no "사용자 턴" "$(state .user_turns)"

echo
echo "[백그라운드 대기: 도구 안 쓰고 재진입하면 차단하지 않는다]"
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null || exit 1
bouncer start simple bgwait >/dev/null
stop >/dev/null
bouncer todo add 'x' >/dev/null; bouncer todo done 1 >/dev/null
stop >/dev/null                                   # verify 진입
r=$(stop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null && ok "첫 Stop 은 차단(할 일 남음)" || no "첫 차단" "${r:0:80}"
r=$(restop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && no "도구 없이 재진입했는데 또 차단" "${r:0:80}" || ok "도구 없이 재진입하면 멈추게 둔다"
[ "$(stage)" = verify ] && ok "단계는 그대로" || no "단계" "$(stage)"
pre Bash '{"command":"ls"}' >/dev/null 2>&1      # 도구 사용
r=$(restop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null && ok "도구를 쓴 뒤 멈추면 다시 차단" || no "재차단" "${r:0:80}"

for i in 1 2 3 4 5; do pre Bash '{"command":"ls"}' >/dev/null 2>&1; stop >/dev/null; done
[ "$(stage)" = verify ] && ok "done 전 여러 번 멈춰도 implement 로 반송되지 않음" || no "반송됨" "$(stage)"

echo
echo "[사람 대기 상태 재진입은 조용히 멈춘다]"
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null || exit 1
bouncer start plan humanwait >/dev/null
r=$(stop); [ "$(stage)" = plan ] || abort_setup "plan 유지" "$(stage)"
r=$(restop)
[ -z "$r" ] && ok "재진입 Stop 은 출력 없음(턴을 다시 열지 않음)" || no "재진입 출력" "${r:0:80}"
finish
