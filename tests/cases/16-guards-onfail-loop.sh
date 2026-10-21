#!/usr/bin/env bash
# 케이스 16-2 — on_fail 무한 왕복 가드.
# Stop 을 순차로 80번 넘게 부르는 섹션이라 16번에서 떼어 냈다 (16번이 전체 병렬 실행의 꼬리였다).
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 픽스처는 케이스마다 따로 둔다. 전역 경로를 쓰면 케이스끼리 덮어쓴다.
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT

echo "[on_fail 무한 왕복 가드]"
cat > "$FIXTURE_DIR/_loop.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [impl, verify, done]}
stages:
  impl:
    steps: [{label: 구현, inject: "구현해라."}]
  verify:
    on_fail: impl
    steps:
      - label: 게이트
        run: 'exit 1'
        by: engine
        blocking: true
    forbid:
      edit_files: true
      reason: 검증 단계에선 수정 금지.
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_loop.yaml" >/dev/null || exit 1
trap cleanup EXIT
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=3 max_attempts=2 max_loops=3
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan pingpong >/dev/null
rel=0; esc=""
for i in $(seq 1 40); do
  o=$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}")
  printf '%s' "$o" | jq -e '.decision == "block"' >/dev/null 2>&1 || { rel=$((rel+1)); [ -z "$esc" ] && esc="$o"; }
done
[ "$rel" -gt 0 ] && ok "무한히 밀어붙이지 않는다 (40회 중 ${rel}회 사용자에게 넘김)" \
  || no "무한 차단" "40회 내내 block"
# 연속으로 몇 번이나 막히는지가 핵심이다. max_continue(3)를 크게 넘기면 안 된다.
MAXRUN=0; run=0
for i in $(seq 1 40); do
  o=$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}")
  if printf '%s' "$o" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    run=$((run+1)); [ "$run" -gt "$MAXRUN" ] && MAXRUN=$run
  else run=0; fi
done
[ "$MAXRUN" -le 6 ] && ok "연속 차단이 상한 안에 머문다 (최대 ${MAXRUN}회 연속)" \
  || no "과도한 연속 차단" "${MAXRUN}회 연속 — 사용자가 세션을 못 돌려받는다"
RT=$(state '[.history[]|select(.returned_from)]|length')
# 근본 원인 수정 전에는 2 Stop마다 1왕복이라 40회에 20왕복이 났다.
# 아무것도 안 고치면 애초에 다시 내보내지 않으므로 왕복은 1~2회에 그쳐야 한다.
[ "$RT" -le 3 ] && ok "고친 게 없으면 왕복 자체가 안 생긴다 (${RT}회)" || no "헛바퀴" "${RT}회 왕복"
printf '%s' "$esc" | grep -qE '작업 트리가 그대로|왕복했다' && ok "막힌 이유를 설명한다" || no "이유 설명" "${esc:0:60}"

# 실제로 고치면 다시 전진해야 한다
echo "change" >> app.js
hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\"}" >/dev/null
[ "$(stage)" = verify ] && ok "고치면 다시 검증으로 전진" || no "전진" "$(stage)"
printf '%s' "$esc" | grep -q 'AskUserQuestion' && ok "사용자에게 선택지를 제시하도록 안내" || no "선택지 안내"
finish
