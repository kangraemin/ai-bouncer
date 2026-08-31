#!/usr/bin/env bash
# 케이스 12 — 강제 종료로 SessionEnd가 못 뜬 경우, 오래 멈춘 잠금만 정리한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT

CLAUDE_CODE_SESSION_ID=DEAD bouncer start plan "dead" >/dev/null
CLAUDE_CODE_SESSION_ID=LIVE bouncer start plan "live" >/dev/null 2>&1
# 정렬 순서에 의존하지 말고 소유자로 찾는다
find_task(){ for d in "$T"/.ai-bouncer/tasks/*/; do
  [ "$(jq -r '.session_id // empty' "$d/.active" 2>/dev/null)" = "$1" ] && { printf '%s' "${d%/}"; return; }
done; }
D="$(find_task DEAD)"; L="$(find_task LIVE)"
[ -n "$D" ] && [ -n "$L" ] && ok "두 세션이 각자 잠금 확보" || no "잠금 확보" "D=$D L=$L"

# 방금 만든 잠금은 정리되면 안 된다
printf '{"session_id":"NEW","cwd":"%s"}' "$T" | bash "$R/hooks/session-start.sh" >/dev/null
[ -f "$D/.active" ] && [ -f "$L/.active" ] && ok "갓 생긴 잠금은 유지" || no "갓 생긴 잠금 유지"

# 하트비트를 13시간 전으로 되돌린다 (기본 임계 12시간)
OLD=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=13)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
jq --arg t "$OLD" '.seen_at = $t' "$D/.active" > "$D/.a" && mv "$D/.a" "$D/.active"

out=$(printf '{"session_id":"NEW","cwd":"%s"}' "$T" | bash "$R/hooks/session-start.sh")
[ -f "$D/.active" ] && no "방치 잠금 정리" "남아있음" || ok "13시간 멈춘 잠금 정리"
[ -f "$L/.active" ] && ok "살아있는 잠금은 보존" || no "살아있는 잠금 보존"
printf '%s' "$out" | grep -q '정리했다' && ok "정리 사실을 알림" || no "정리 알림"
[ -f "$D/state.json" ] && ok "작업 기록은 보존" || no "작업 기록 보존"

# 하트비트가 갱신되면 다시 살아난다
stop LIVE >/dev/null
AGE=$(jq -r '.seen_at' "$L/.active")
[ -n "$AGE" ] && ok "Stop이 하트비트를 갱신" || no "하트비트 갱신"
finish
