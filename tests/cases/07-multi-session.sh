#!/usr/bin/env bash
# 케이스 7 — 세션 격리: 남의 작업을 읽지도 지우지도 않는다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT

CLAUDE_CODE_SESSION_ID=S1 bouncer start plan "세션1 작업" >/dev/null
T1=$(ls -d "$T"/.ai-bouncer/tasks/*/ | head -1)
[ -f "$T1/.active" ] && ok "S1이 lock 확보" || no "lock 확보"

out=$(CLAUDE_CODE_SESSION_ID=S2 bouncer start plan "세션2 작업" 2>&1)
printf '%s' "$out" | grep -q CONFLICT && ok "S2 시작 시 CONFLICT 보고" || no "CONFLICT 보고"
[ -f "$T1/.active" ] && ok "S1 lock을 뺏지 않음" || no "lock 보존"
[ "$(ls -d "$T"/.ai-bouncer/tasks/*/ | wc -l | tr -d ' ')" = 2 ] && ok "각자 별도 태스크" || no "태스크 분리"

r=$(pre Edit "{\"file_path\":\"$T/app.js\"}" S3)
[ -z "$r" ] && ok "무관한 세션엔 개입 안 함" || no "무관 세션 개입"

printf '{"session_id":"S1","cwd":"%s","reason":"logout"}' "$T" | bash "$R/hooks/session-end.sh"
[ -f "$T1/.active" ] && no "S1 종료 시 lock 해제" || ok "S1 종료 시 자기 lock만 해제"
[ "$(ls "$T"/.ai-bouncer/tasks/*/.active 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && ok "S2 lock은 그대로" || no "S2 lock 보존"
[ -f "$T1/state.json" ] && ok "종료해도 작업 기록은 남음" || no "작업 기록 보존"
finish
