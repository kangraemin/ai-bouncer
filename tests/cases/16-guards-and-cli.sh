#!/usr/bin/env bash
# 케이스 16 — Stop 재진입 가드, cancel/check 경로, uninstall의 .gitignore 복원
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cat > /tmp/_g.yaml <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [work, done]}
stages:
  work:
    steps:
      - label: 절대 통과 못 함
        run: 'exit 1'
        by: engine
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup /tmp/_g.yaml || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan guards >/dev/null

echo "[Stop 재진입 가드]"
# stop_hook_active=true 로 계속 때려도 무한히 밀지 않아야 한다 (config: max_continue=3)
# 계속 때려도 "영원히 미는" 일이 없어야 한다 — 주기적으로 사용자에게 돌려줘야 한다.
released=0
for i in $(seq 1 12); do
  out=$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 || released=$((released+1))
done
[ "$(state .reentry_count)" != "" ] && ok "재진입 횟수를 기록한다" || no "재진입 기록"
[ "$released" -ge 2 ] && ok "반복 차단 시 주기적으로 세션을 돌려준다 (12회 중 ${released}회)" \
  || no "무한루프 방지" "12회 내내 밀어붙임"

# 상한을 0으로 두면 아예 밀지 않아야 한다
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=0 max_attempts=2
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
out=$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\"}")
printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && no "max_continue=0" "그래도 밀어붙임" || ok "max_continue=0이면 바로 사용자에게 넘긴다"
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=3 max_attempts=2
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null

echo "[cancel]"
bouncer cancel >/dev/null && ok "cancel 실행" || no "cancel"
[ "$(stage)" = cancelled ] && ok "상태가 cancelled" || no "cancelled" "$(stage)"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "cancel 시 lock 해제" "남음" || ok "cancel 시 lock 해제"
ls "$T"/.ai-bouncer/tasks/*/state.json >/dev/null 2>&1 && ok "기록은 보존" || no "기록 보존"
out=$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\"}")
[ -z "$out" ] && ok "취소 뒤엔 Stop이 관여 안 함" || no "취소 후 관여" "$out"

echo "[check]"
says 'OK' bouncer check && ok "정상 yaml은 OK" || no "check OK"
printf 'blocking: 이상\n' >> .claude/ai-bouncer/workflow.yaml
says '유효하지 않' bouncer check && ok "깨진 yaml은 거부" || no "check 거부"
git checkout -q .claude/ai-bouncer/workflow.yaml 2>/dev/null || sed -i '' '$d' .claude/ai-bouncer/workflow.yaml

echo "[uninstall의 .gitignore 복원]"
grep -qxF '.ai-bouncer/' .gitignore && ok "설치가 .gitignore에 넣음" || no "설치 gitignore"
printf '내-규칙.txt\n' >> .gitignore
bash "$R/uninstall.sh" >/dev/null 2>&1
grep -qxF '.ai-bouncer/' .gitignore && no ".ai-bouncer/ 제거" "남음" || ok "제거 시 .ai-bouncer/ 줄도 되돌림"
grep -qxF '내-규칙.txt' .gitignore && ok "내가 쓴 줄은 보존" || no "사용자 줄 보존"
finish
