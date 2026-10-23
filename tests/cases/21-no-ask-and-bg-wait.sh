#!/usr/bin/env bash
# 케이스 21 — done 전에는 사람을 기다리지 않고, 기다리는 동안 Stop 이 턴을 계속 깨우지 않는다.
#
# 1) 기본 워크플로우에서 사용자 턴 없이 done 까지 간다 (중간에 승인을 물을 이유가 없다).
# 2) 직전 차단 이후 도구를 하나도 안 쓰고 다시 멈추면(백그라운드 작업 대기) 차단하지 않는다.
#    done 표시만 남은 같은 조건이면 도구를 쓴 뒤에도 다시 막지 않는다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 2) 은 done 표시 게이트가 있어야 재현된다. 기본값엔 이제 없으니(검증 보고 자기신고 제거) 픽스처로 둔다.
FIXTURE_DIR="$(mktemp -d)"
python3 - "$R/config/default.yaml" "$FIXTURE_DIR/_done.yaml" <<'PY2'
import sys
s = open(sys.argv[1]).read()
k = "      - label: 검증 보고\n"
assert k in s
open(sys.argv[2], 'w').write(s.replace(k, k + "        blocking: done\n", 1))
PY2
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }

echo
echo "[사용자 턴 없이 done 까지]"
bouncer start simple noask >/dev/null
bouncer todo add 'x' >/dev/null; bouncer todo done 1 >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] && ok "implement → verify (사람 턴 없음)" || no "implement 전이" "$(stage)"
stop >/dev/null; [ "$(stage)" = finalize ] && ok "verify → finalize (사람 턴 없음)" || no "verify 전이" "$(stage)"

echo
echo "[백그라운드 대기: 도구 안 쓰고 재진입하면 차단하지 않는다]"
cleanup; setup "$FIXTURE_DIR/_done.yaml" "$R/config/prompts" >/dev/null || exit 1
bouncer start simple bgwait >/dev/null
bouncer todo add 'x' >/dev/null; bouncer todo done 1 >/dev/null
stop >/dev/null                                   # verify 진입
r=$(stop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null && ok "첫 Stop 은 차단(할 일 남음)" || no "첫 차단" "${r:0:80}"
r=$(restop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && no "도구 없이 재진입했는데 또 차단" "${r:0:80}" || ok "도구 없이 재진입하면 멈추게 둔다"
[ "$(stage)" = verify ] && ok "단계는 그대로" || no "단계" "$(stage)"
pre Bash '{"command":"ls"}' >/dev/null 2>&1      # 도구 사용
# 도구를 썼으면 진행 중이다 — 아직 안 끝났으니 다시 막는다
r=$(restop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "도구를 쓰고 멈추면 다시 막는다" || no "안 끝났는데 통과" "${r:0:80}"

for i in 1 2 3 4 5; do pre Bash '{"command":"ls"}' >/dev/null 2>&1; stop >/dev/null; done
[ "$(stage)" = verify ] && ok "done 전 여러 번 멈춰도 implement 로 반송되지 않음" || no "반송됨" "$(stage)"

finish
