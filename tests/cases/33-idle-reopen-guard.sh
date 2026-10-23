#!/usr/bin/env bash
# 케이스 33 — 턴을 다시 열었는데 모델이 도구 없이 또 멈추면, 경로와 상관없이 더 열지 않는다.
#
# 2026-10-22 ttuk-chiro-clinic: Stop 안내가 턴을 다시 열 때마다 모델이 도구 없이 한 줄만 답해
# 5회 이상 연속 루프가 54건 나왔다. 경로별 수정 대신 stop.sh 출구에서 거른다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
cat > "$FIXTURE_DIR/_idle.yaml" <<'Y'
version: 1
workflows:
  simple: {label: 테스트용, stages: [verify, done]}
stages:
  verify:
    steps:
      - {label: 검사, run: "false", blocking: true}
      - {label: 확인, inject: "확인하고 bouncer done 해라.", blocking: true}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_idle.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=10 >/dev/null
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null
export CLAUDE_CODE_SESSION_ID=S1
restop(){ hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}"; }
reopens(){ jq -e '(.decision == "block") or ((.hookSpecificOutput.additionalContext // "") != "")' >/dev/null 2>&1; }
bouncer start simple idle >/dev/null
TASKDIR="$(task_dir)"

# 어느 경로든: 도구 없이 재진입하는 동안 턴을 다시 여는 출력은 연속 2번을 넘지 않는다.
r=$(stop); printf '%s' "$r" | reopens && ok "첫 Stop 은 턴을 다시 연다" || no "첫 Stop" "${r:0:100}"
run=1; maxrun=1
for i in $(seq 1 8); do
  r=$(restop)
  if printf '%s' "$r" | reopens; then run=$((run+1)); [ "$run" -gt "$maxrun" ] && maxrun=$run; else run=0; fi
done
[ "$maxrun" -le 2 ] && ok "도구 없는 재진입에 턴을 연속 2번 넘게 열지 않는다 (최대 ${maxrun})" \
  || no "도구 없이 계속 연다" "최대 ${maxrun}회 연속"

# 안전장치 자체 — 어떤 출력이 오든 출구에서 바꾼다. 다른 차단 경로를 흉내 내려고
# 출구 직전 상태(재진입·도구 그대로·이미 한 번 도구 없이 열었음)를 만든다.
printf 1 > "$TASKDIR/.idle_reopens"; cp "$TASKDIR/.tool_seq" "$TASKDIR/.tool_seq_at_reopen" 2>/dev/null \
  || { printf 0 > "$TASKDIR/.tool_seq"; printf 0 > "$TASKDIR/.tool_seq_at_reopen"; }
jq '.continue_streak = 0 | .reentry_count = 0 | .allowed_stop = false' "$TASKDIR/state.json" > "$TASKDIR/s.tmp" && mv "$TASKDIR/s.tmp" "$TASKDIR/state.json"
rm -f "$TASKDIR/.tool_seq_at_block"
r=$(restop)
printf '%s' "$r" | reopens && no "출구에서 거르지 않는다" "${r:0:120}" || ok "출구에서 턴을 열지 않는 안내로 바꾼다"
printf '%s' "$r" | jq -r '.systemMessage // ""' | grep -q '도구 없이 2번 연속' \
  && ok "이유와 원래 안내를 사용자에게 보인다" || no "안내 없음" "${r:0:120}"

# 도구를 쓰고 멈춘 재진입은 진행 중이다 — 계속 열어야 한다.
r=$(stop)
for i in 1 2 3 4; do
  printf '%s' "$(( $(cat "$TASKDIR/.tool_seq" 2>/dev/null || echo 0) + 1 ))" > "$TASKDIR/.tool_seq"
  r=$(restop); printf '%s' "$r" | reopens || break
done
[ "$i" = 4 ] && printf '%s' "$r" | reopens && ok "도구를 쓰는 동안은 계속 연다" || no "진행 중인데 멈춤" "$i: ${r:0:100}"

# 사용자 턴 뒤 첫 Stop 은 카운터를 새로 센다.
r=$(stop); printf '%s' "$r" | reopens && ok "새 사용자 턴은 다시 센다" || no "카운터 잔존" "${r:0:100}"
finish
