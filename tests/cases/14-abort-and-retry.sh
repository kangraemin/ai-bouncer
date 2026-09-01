#!/usr/bin/env bash
# 케이스 14 — on_fail: abort 로 실패 종료 / 수정 가능한 스테이지는 max_attempts 만큼 제자리 재시도
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 픽스처는 케이스마다 따로 둔다. 전역 경로를 쓰면 케이스끼리 덮어쓴다.
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT

echo "[abort]"
cat > "$FIXTURE_DIR/_abort.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [check, done]}
stages:
  check:
    on_fail: abort
    steps:
      - label: 불가능한 조건
        run: 'exit 1'
        by: engine
        blocking: true
    forbid:
      edit_files: true
      reason: 여기선 수정 불가.
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_abort.yaml" || exit 1
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "중단" >/dev/null
out=$(stop)
[ "$(stage)" = cancelled ] && ok "abort로 작업 중단" || no "abort" "$(stage)"
printf '%s' "$out" | grep -q '중단했다' && ok "중단 사유 알림" || no "중단 사유"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "abort 시 lock 해제" "남음" || ok "abort 시 lock 해제"
[ -f "$(ls -d "$T"/.ai-bouncer/tasks/*/ | head -1)/state.json" ] && ok "기록은 보존" || no "기록 보존"
cleanup

echo "[제자리 재시도]"
cat > "$FIXTURE_DIR/_retry.yaml" <<'Y'
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
        run: 'test -f PASS'
        by: engine
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_retry.yaml" || exit 1   # config: max_attempts=2
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan "재시도" >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] && ok "verify 진입" || no "진입" "$(stage)"
r=$(pre Edit "{\"file_path\":\"$T/app.js\"}")
[ -z "$r" ] && ok "수정 허용 스테이지" || no "수정 허용"
stop >/dev/null; [ "$(stage)" = verify ] && ok "1회 실패는 제자리 유지" || no "제자리 유지" "$(stage)"
stop >/dev/null; [ "$(stage)" = impl ] && ok "max_attempts(2) 소진 후 반송" || no "반송" "$(stage)"
finish
