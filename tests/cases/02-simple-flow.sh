#!/usr/bin/env bash
# 케이스 2 — simple 워크플로우는 plan 단계 없이 바로 구현부터 시작한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

bouncer start simple "오타 수정" >/dev/null
[ "$(stage)" = implement ] && ok "plan 없이 implement에서 시작" || no "시작 단계" "$(stage)"

r=$(pre Edit "{\"file_path\":\"$T/app.js\"}")
[ -z "$r" ] && ok "바로 수정 가능" || no "수정 가능" "차단됨"

# implement 의 완료 대조는 **엔진이 항목 수를 세는** 게이트다 (자기보고 아님)
bouncer todo add 'A 구현' 'B 구현' >/dev/null
bouncer todo done 1 >/dev/null
r=$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')
printf '%s' "$r" | grep -q '남은 항목 1/2' && ok "남은 항목 수를 센다" || no "항목 수 미집계" "${r:0:60}"
[ "$(stage)" = implement ] && ok "남은 항목이 있으면 못 넘어간다" || no "전이됨" "$(stage)"

bouncer todo done 2 >/dev/null
r=$(stop); [ "$(stage)" = verify ] && ok "목록을 다 체크하면 사용자 확인 없이 전이" || no "전이" "$(stage)"
printf '%s' "$r" | grep -q '검증 단계다' && ok "verify 지시는 전이 때 전달" || no "지시 누락" "${r:0:80}"

# 검증 보고는 지시만 한다 — 자기신고(bouncer done) 없이 넘어간다 (2026-10-22 감사: 230회 중 92% 의례).
r=$(stop)
[ "$(stage)" = finalize ] && ok "done 표시 없이 finalize로 전이" || no "전이" "$(stage)"
printf '%s' "$r" | grep -q "bouncer done" && no "done 을 요구함" "${r:0:80}" || ok "done 을 요구하지 않음"

# 목록을 안 세웠으면 완료 대조는 통과한다 — 스스로 세우고 바로 체크하는 의례였다(형식 통과 20건).
bouncer cancel >/dev/null 2>&1
bouncer start simple "두번째" >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] && ok "빈 할 일 목록은 통과" || no "빈 목록 차단" "$(stage)"
finish
