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
r=$(stop)
[ "$(stage)" = implement ] && ok "Stop 만으로는 구현이 끝나지 않는다" || no "게이트 없음" "$(stage)"
printf '%s' "$r" | jq -r '.reason // .hookSpecificOutput.additionalContext // ""' \
  | grep -q '할 일 목록이 비어 있다' && ok "목록이 비면 그렇게 알린다" || no "사유 불명확" "${r:0:70}"

bouncer todo add 'A 구현' 'B 구현' >/dev/null
bouncer todo done 1 >/dev/null
r=$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')
printf '%s' "$r" | grep -q '남은 항목 1/2' && ok "남은 항목 수를 센다" || no "항목 수 미집계" "${r:0:60}"
[ "$(stage)" = implement ] && ok "남은 항목이 있으면 못 넘어간다" || no "전이됨" "$(stage)"

bouncer todo done 2 >/dev/null
stop >/dev/null; [ "$(stage)" = verify ] && ok "목록을 다 체크하면 사용자 확인 없이 전이" || no "전이" "$(stage)"

# verify 검증 보고: 사람을 기다리지 않는다. done 전엔 계속 진행시키고, done 하면 전이
r=$(stop)
[ "$(stage)" = verify ] && ok "done 전에는 verify 유지" || no "done 없이 전이" "$(stage)"
printf '%s' "$r" | jq -r '.reason // ""' | grep -q "bouncer done 'verify/검증 보고'" \
  && ok "done 전엔 계속 진행시키며 done 명령을 안내" || no "안내 없음" "${r:0:80}"
printf '%s' "$r" | grep -q '사용자 확인 대기' && no "사람 대기로 표시됨" "${r:0:80}" || ok "사람 대기로 표시하지 않음"
bouncer done "verify/검증 보고" >/dev/null
stop >/dev/null; [ "$(stage)" = finalize ] && ok "사용자 턴 없이 done 후 finalize로 전이" || no "전이" "$(stage)"
finish
