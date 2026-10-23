#!/usr/bin/env bash
# 케이스 31 — `bouncer run` 이 도는 동안 Stop 은 끝날 때까지 기다렸다가 결과로 판정한다.
#
# 2026-10-22 감사: 백그라운드 e2e 를 두고 멈추면 "통과 기록 없음"으로 막혀 턴을 계속 열었다.
# 그 뒤 systemMessage 로 통과시켰더니 결과를 안 보고 끝났다. 이제 훅이 직접 기다린다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_run.yaml" <<'Y'
version: 1
workflows:
  simple: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 검사, run: "sleep 3", blocking: true}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_run.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }
waitrun(){ for i in $(seq 1 40); do [ -n "$(state '.running["verify/검사"] // ""')" ] && break; sleep 0.1; done; }

bouncer start simple running >/dev/null
bouncer run "verify/검사" >/dev/null 2>&1 &
RP=$!; waitrun
[ -n "$(state '.running["verify/검사"] // ""')" ] && ok "실행 중 표시를 남긴다" || no "실행 중 표시 없음"
r=$(stop)
[ "$(stage)" = done ] && ok "끝날 때까지 기다렸다가 결과로 전이한다" || no "기다리지 않음" "$(stage): ${r:0:100}"
wait "$RP"
[ -z "$(state '.running["verify/검사"] // ""')" ] && ok "끝나면 표시를 지운다" || no "표시 잔류"

# 대기 상한을 넘기면 막는다(안 끝났으니). 도구 없이 또 멈추면 같은 차단을 반복하지 않는다.
bouncer cancel >/dev/null 2>&1
bouncer start simple slow >/dev/null
bouncer run "verify/검사" >/dev/null 2>&1 &
RP=$!; waitrun
r=$(RUN_WAIT_MAX=1 stop)
printf '%s' "$r" | jq -r '.reason // ""' | grep -q '실행 중: 검사' && ok "상한을 넘기면 무엇이 도는지 알리며 막는다" || no "안내 없음" "${r:0:100}"
r=$(RUN_WAIT_MAX=1 restop); [ -z "$r" ] && ok "도구 없이 또 멈추면 다시 막지 않는다" || no "반복 차단" "${r:0:100}"
[ "$(stage)" = verify ] && ok "단계는 넘기지 않는다" || no "넘어감" "$(stage)"
wait "$RP"
stop >/dev/null
[ "$(stage)" = done ] && ok "끝난 뒤에는 결과로 전이한다" || no "전이" "$(stage)"

# 실행 기록이 없으면 평소대로 통과 기록을 요구한다
bouncer cancel >/dev/null 2>&1
bouncer start simple dead >/dev/null
r=$(stop)
printf '%s' "$r" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "실행 기록 없으면 평소대로 막는다" || no "안 막음" "${r:0:100}"
finish
