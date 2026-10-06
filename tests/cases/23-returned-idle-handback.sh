#!/usr/bin/env bash
# 케이스 23 — 반송돼 온 스테이지에서 도구를 하나도 안 쓰고 다시 멈추면 즉시 사용자에게 넘긴다.
#
# 고칠 수 없는 게이트(예: 지운 npm 스크립트를 부르는 run)로 반송되면 모델은 할 게 없다.
# 예전엔 "작업 트리가 그대로다 (N/10)" 차단을 상한까지 똑같이 반복했다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [impl, verify, done]}
stages:
  impl:
    steps: [{label: 구현, inject: "구현해라."}]
  verify:
    on_fail: impl
    steps:
      - label: 지운 스크립트
        run: 'exit 1'
        by: engine
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }

bouncer start plan idle >/dev/null
stop >/dev/null; stop >/dev/null; stop >/dev/null
[ "$(stage)" = impl ] || abort_setup "impl 로 반송" "$(stage)"
r=$(stop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null && ok "반송 직후 첫 Stop 은 차단" || no "첫 차단" "${r:0:80}"
r=$(restop)
printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 && no "도구 없이 재진입했는데 또 차단" "${r:0:80}" || ok "도구 없이 재진입하면 차단하지 않는다"
printf '%s' "$r" | grep -q '사용자에게 넘긴다' && ok "사용자에게 넘긴다고 알린다" || no "넘김 안내" "${r:0:120}"
printf '%s' "$r" | grep -q '도구 호출 0회' && ok "넘긴 이유(도구 0회) 표시" || no "이유 표시" "${r:0:120}"

echo "[도구를 쓰면서 멈추면 기존처럼 횟수를 센다]"
cleanup; setup "$FIXTURE_DIR/_wf.yaml" >/dev/null || exit 1
bouncer start plan busy >/dev/null
stop >/dev/null; stop >/dev/null; stop >/dev/null
r=$(stop)
pre Bash '{"command":"ls"}' >/dev/null 2>&1
r=$(restop); printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null && ok "도구를 쓴 뒤 멈추면 다시 차단" || no "재차단" "${r:0:80}"
finish
