#!/usr/bin/env bash
# 케이스 02 — Stop 의 안전장치: 연속 차단 상한, 도구 없는 재진입, 손상 상태·설정, 사라진 단계
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"

[ -z "$(stop)" ] && ok "작업 없으면 관여 안 함" || no "작업 없음"

# ── 연속 차단 상한 (BOUNCER_MAX_CONTINUE=3) ──
b1 start main g1 --pick b=x >/dev/null
for i in 1 2 3; do O="$(stop)"; printf '%s' "$i" > "$(task_dir)/.tool_seq"; done
blocked "$O" && ok "상한 전에는 계속 막는다" || no "상한 전" "$O"
O="$(stop)"; printf '%s' "$O" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null && reason "$O" | grep -q 'AskUserQuestion' \
  && ok "상한에 닿으면 막지 않고 사용자에게 넘긴다" || no "상한" "$O"
[ "$(state .continue_streak)" = 0 ] && ok "넘긴 뒤 횟수 초기화" || no "streak" "$(state .continue_streak)"
[ "$(stage)" = a ] && ok "넘겨도 단계는 그대로" || no "단계 유지"

# ── 도구 없는 재진입: 같은 사유면 놓아준다 ──
printf '50' > "$(task_dir)/.tool_seq"; O1="$(stop)"; O2="$(stop S1 true)"
blocked "$O1" && [ -z "$O2" ] && ok "도구 없이 같은 사유로 재진입하면 놓아준다" || no "재진입" "$O2"
printf '99' > "$(task_dir)/.tool_seq"
blocked "$(stop S1 true)" && ok "그 사이 도구를 썼으면 다시 막는다" || no "도구 사용 후"
b1 cancel >/dev/null
[ -z "$(stop)" ] && ok "cancel 뒤엔 관여 안 함" || no "cancel"

# ── 손상된 state ──
b1 start main g2 --pick b=x >/dev/null
cp "$(task_dir)/state.json" /tmp/st.$$; echo '{broken' > "$(task_dir)/state.json"
O="$(stop)"; blocked "$O" && reason "$O" | grep -q '상태 파일이 손상' && ok "state 손상 → 막는다" || no "state 손상" "$O"
cp /tmp/st.$$ "$(task_dir)/state.json"; rm -f /tmp/st.$$

# ── 손상된 설정 ──
cp .claude/ai-bouncer/workflow.compiled.json /tmp/cp.$$; echo 'x' > .claude/ai-bouncer/workflow.compiled.json
O="$(stop)"; blocked "$O" && reason "$O" | grep -q '설정을 읽을 수 없다' && ok "설정 손상 → 막는다" || no "설정 손상" "$O"
cp /tmp/cp.$$ .claude/ai-bouncer/workflow.compiled.json; rm -f /tmp/cp.$$

# ── 작업 도중 단계가 사라짐 ──
jq '.current_stage = "gone"' "$(task_dir)/state.json" > /tmp/s.$$ && mv /tmp/s.$$ "$(task_dir)/state.json"
O="$(stop)"; reason "$O" | grep -q "'gone' 가 workflow.yaml에 없다" && ok "사라진 단계 → 막고 안내" || no "사라진 단계" "$O"
b1 cancel >/dev/null

# ── chain 없는 옛 작업은 모드 체인으로 채운다 ──
b1 start main g3 --pick b=x >/dev/null
jq 'del(.chain)' "$(task_dir)/state.json" > /tmp/s.$$ && mv /tmp/s.$$ "$(task_dir)/state.json"
stop >/dev/null; [ "$(state '.chain|join(" ")')" = "a b c" ] && ok "chain 없는 작업은 모드 체인으로 채운다" || no "chain 채우기" "$(state .chain)"
b1 cancel >/dev/null

# ── 다른 세션의 작업에는 관여하지 않는다 ──
b1 start main g4 --pick b=x >/dev/null
[ -z "$(stop S2)" ] && ok "남의 세션 Stop 은 관여 안 함" || no "남의 세션"
b1 cancel >/dev/null

cleanup; finish
