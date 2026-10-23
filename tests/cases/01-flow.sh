#!/usr/bin/env bash
# 케이스 01 — 모드·단계·run·고르기(ask/auto/all) 흐름
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"

# ── 시작: 고르는 단계는 답이 있어야 한다 ──
says "고를 단계에 답이 없다: b" b1 start main t && ok "ask 단계 답 없으면 시작 거부" || no "ask 거부"
says "고를 단계에 답이 없다: b" b1 start auto t && ok "auto 단계도 답 없으면 시작 거부" || no "auto 거부"
says "항목은 없다" b1 start main t --pick b=zz && ok "없는 항목 거부" || no "없는 항목"
says "고르는 단계가 아니다" b1 start main t --pick b=x --pick a=a && ok "고르는 단계 아닌 것 거부" || no "비고르기 단계"
[ -z "$(task_dir)" ] && ok "거부된 시작은 작업을 남기지 않는다" || no "잔여 작업"
b1 scan | grep -q $'^CHOICE\tmain\tb\tx\task\t엑스$' && ok "scan CHOICE 에 방식 ask" || no "scan ask" "$(b1 scan)"
b1 scan | grep -q $'^CHOICE\tauto\tb\tx\tauto\t' && ok "모드 덮어쓰기 → auto" || no "scan auto"
b1 scan | grep -q $'^CHOICE\twhole\t' && no "all 모드는 CHOICE 없어야" || ok "all 모드는 묻지 않는다"

# ── 진행: 고른 항목만 ──
OUT="$(b1 start main t --pick b=x)"
printf '%s' "$OUT" | grep -q '파일에서 읽은 지시' && ok "start 가 첫 단계 지시(prompt_file)를 준다" || no "첫 지시" "$OUT"
[ "$(state '.choices.b|join(",")')" = x ] && ok "고른 결과를 state 에 적는다" || no "choices"
O="$(stop)"; blocked "$O" && reason "$O" | grep -q 'test -f a.done' && ok "run 실패 → 막고 명령을 보여준다" || no "run 실패" "$O"
reason "$O" | grep -q "exit 1" && ok "실패 종료코드 표시" || no "exit 표시"
touch a.done; O="$(stop)"
[ "$(stage)" = b ] && reason "$O" | grep -q '엑스 지시' && ! reason "$O" | grep -q '와이 지시' && ok "통과 → 다음 단계 + 고른 항목 지시만" || no "전이" "$O"
O="$(stop)"; reason "$O" | grep -q 'x.done' && ok "고른 항목의 run 만 돈다" || no "항목 run" "$O"
touch x.done; stop >/dev/null; [ "$(stage)" = c ] && ok "안 고른 y 는 검사 안 함" || no "y 검사됨" "$(stage)"
O="$(stop)"; reason "$O" | grep -q '모든 단계를 마쳤다' && ok "마지막 단계 통과 → 종료" || no "종료" "$O"
[ "$(cat env.out 2>/dev/null)" = "c|$(basename "$(task_dir)")" ] && ok "run 에 BOUNCER_STAGE·BOUNCER_TASK_DIR" || no "env" "$(cat env.out 2>/dev/null)"
[ ! -f "$(task_dir)/.active" ] && [ -n "$(state .finished_at)" ] && ok "끝나면 잠금 해제·완료 기록" || no "완료 기록"
[ -z "$(stop)" ] && ok "끝난 뒤엔 관여 안 함" || no "끝난 뒤 관여"

# ── all 모드: 묻지 않고 전부 ──
rm -f a.done x.done y.done
b1 start whole t2 >/dev/null && ok "all 모드는 --pick 없이 시작" || no "all 시작"
touch a.done; O="$(stop)"; reason "$O" | grep -q '엑스 지시' && reason "$O" | grep -q '와이 지시' && ok "all → 항목 전부 주입" || no "all 주입" "$O"
touch x.done; O="$(stop)"; reason "$O" | grep -q 'y.done' && ok "all → 항목 run 전부" || no "all run" "$O"
b1 cancel >/dev/null

# ── auto 모드: AI 가 고른 것만 ──
b1 start auto t5 --pick b=y >/dev/null; [ "$(state '.choices.b|join(",")')" = y ] && ok "auto 도 고른 결과를 적는다" || no "auto choices"
b1 cancel >/dev/null

# ── 단계 자체 고르기 (items 없는 ask 단계) ──
b1 scan | grep -q $'^CHOICE\tpickc\td\td\task\t이 단계를 한다$' && ok "items 없으면 단계 자체가 선택지" || no "단계 선택지"
b1 start pickc t3 --pick d= >/dev/null; [ "$(state '.chain|join(" ")')" = "a c" ] && ok "안 고른 단계는 체인에서 빠진다" || no "체인" "$(state .chain)"
b1 cancel >/dev/null
b1 start pickc t4 --pick d=d >/dev/null; [ "$(state '.chain|join(" ")')" = "a c d" ] && ok "고르면 체인에 남는다" || no "체인2"
b1 cancel >/dev/null

# ── run 종료코드별 안내 ──
cat > .claude/ai-bouncer/workflow.yaml <<'Y'
workflows:
  r2:   {stages: [s2]}
  r127: {stages: [s127]}
  r124: {stages: [s124]}
stages:
  s2:   {run: "echo 아직멀었다; exit 2"}
  s127: {run: "no-such-cmd-xyz"}
  s124: {run: "sleep 5"}
Y
compile || no "compile"
b1 start r2 e2 >/dev/null; O="$(stop)"; b1 cancel >/dev/null
reason "$O" | grep -q '아직 통과하지 못했다 (exit 2)' && reason "$O" | grep -q '아직멀었다' && ok "exit 2 = 아직 + 출력" || no "exit2" "$O"
b1 start r127 e127 >/dev/null; O="$(stop)"; b1 cancel >/dev/null
reason "$O" | grep -q '명령을 찾을 수 없다' && ok "exit 127 = 명령 없음" || no "127" "$O"
b1 start r124 e124 >/dev/null; O="$(BOUNCER_RUN_BUDGET=1 stop)"; b1 cancel >/dev/null
reason "$O" | grep -q '시간 초과' && ok "시간 초과 = 124" || no "124" "$O"

cleanup; finish
