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

# implement 에 완료 대조 게이트가 있다 — Stop 만으로는 못 넘어간다
r=$(stop)
[ "$(stage)" = implement ] && ok "Stop 만으로는 구현이 끝나지 않는다" || no "게이트 없음" "$(stage)"
printf '%s' "$r" | jq -r '.reason // .hookSpecificOutput.additionalContext // ""' \
  | grep -q '구현 완료 대조' && ok "미충족 사유에 대조 단계가 뜬다" || no "사유 불명확" "${r:0:70}"
user_turn >/dev/null
bouncer done "implement/구현 완료 대조" >/dev/null 2>&1
stop >/dev/null; [ "$(stage)" = verify ] && ok "대조 보고 후 verify로 전이" || no "전이" "$(stage)"

# 실제 순서: 엔진이 보고를 요구하며 멈춤 허용 → 사용자 턴 → 모델이 done → 다음 Stop에서 전이
stop >/dev/null
[ "$(state .allowed_stop)" = true ] && ok "사람 답변 대기로 멈춤 허용" || no "멈춤 허용"
user_turn
bouncer done "verify/검증 보고" >/dev/null
stop >/dev/null; [ "$(stage)" = finalize ] && ok "사용자 턴 후 finalize로 전이" || no "전이" "$(stage)"

# 사용자 턴 없이 done만 친 경우는 통과하면 안 된다
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null || exit 1
bouncer start simple "우회 시도" >/dev/null
# implement 에 완료 대조 게이트가 생겼다 — Stop 만으로는 못 넘어간다
stop >/dev/null                                  # 사람 대기 표시
user_turn >/dev/null
bouncer done "implement/구현 완료 대조" >/dev/null 2>&1
stop >/dev/null   # implement -> verify
bouncer done "verify/검증 보고" >/dev/null
stop >/dev/null
[ "$(stage)" = verify ] && ok "사용자 턴 없이 done만으론 통과 못 함" || no "자기신고 우회 차단" "$(stage)"
finish
