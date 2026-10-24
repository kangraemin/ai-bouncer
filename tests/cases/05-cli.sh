#!/usr/bin/env bash
# 케이스 05 — CLI: scan, status, workflows, check, fresh, record/passed, 다중 세션 격리
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"

b1 scan | grep -q $'^STATE\tNONE$' && ok "scan: 작업 없음" || no "scan none"
b1 scan | grep -q $'^WORKFLOW\tmain\t기본$' && ok "scan: 모드 목록" || no "scan workflow"
bouncer workflows | grep -q 'a → b → c' && ok "workflows: 단계 순서" || no "workflows"
bouncer check | grep -q '^OK' && ok "check: 유효" || no "check"
says "세션 ID" bouncer start main t --pick b=x && ok "세션 없이 start 거부" || no "세션 없음"
says "정의되지 않은 모드" b1 start nope t && ok "없는 모드 거부" || no "없는 모드"

b1 start main c1 --pick b=x >/dev/null
b1 scan | grep -q $'^STATE\tMINE\t.*\tmain\ta$' && ok "scan: 내 작업" || no "scan mine" "$(b1 scan)"
says "이미 진행 중인 작업" b1 start main c2 --pick b=x && ok "한 세션에 작업 둘 거부" || no "중복 작업"
b1 status | grep -q '파일에서 읽은 지시' && b1 status | grep -q 'test -f a.done' && ok "status: 지시와 검사" || no "status" "$(b1 status)"

# 다른 세션은 따로 논다
SID=S2 b1 scan | grep -q $'^STATE\tNONE$' && ok "다른 세션 scan 은 NONE" || no "S2 scan"
SID=S2 b1 start main c3 --pick b=y >/dev/null && ok "다른 세션은 따로 시작" || no "S2 start"
[ "$(ls -d .ai-bouncer/tasks/*/.active | wc -l | tr -d ' ')" = 2 ] && ok "작업 둘이 따로 잠긴다" || no "잠금 둘"
says "활성 작업이 없다" bouncer cancel && ok "세션 없이 cancel 거부(바꾸는 명령)" || no "세션 없는 cancel"
SID=S2 b1 cancel >/dev/null
bouncer status 2>/dev/null | grep -q 'c1' && ok "세션 없이 status 는 하나뿐인 작업을 보여준다" || no "세션 없는 status"
b1 cancel | grep -q '^CANCELLED' && ok "cancel" || no "cancel"
[ "$(state .current_stage)" = cancelled ] && ok "cancel 기록" || no "cancel 기록"

# fresh — run 에서 리포트가 지금 코드 기준인지 본다
mkdir -p .ai-bouncer; b1 start main c4 --pick b=x >/dev/null; export BOUNCER_TASK_DIR="$(task_dir)"
bouncer fresh .ai-bouncer/rep >/dev/null; [ $? = 2 ] && ok "fresh: 리포트 없으면 exit 2" || no "fresh 없음"
echo ok > .ai-bouncer/rep; bouncer fresh .ai-bouncer/rep && ok "fresh: 바뀐 파일 없으면 통과" || no "fresh 통과"
sleep 1; echo changed >> app.js
bouncer fresh .ai-bouncer/rep >/dev/null; [ $? = 2 ] && ok "fresh: 리포트 뒤에 고친 파일 있으면 exit 2" || no "fresh 낡음"
sleep 1; echo ok > .ai-bouncer/rep; bouncer fresh .ai-bouncer/rep && ok "fresh: 다시 돌리면 통과" || no "fresh 재통과"
sleep 1; echo new > new.txt
bouncer fresh .ai-bouncer/rep >/dev/null; [ $? = 2 ] && ok "fresh: 새 파일도 본다" || no "fresh untracked"

# record / passed — 검사는 모델이 record 로 돌리고, run 은 passed 로 결과만 본다
bouncer passed t >/dev/null; [ $? = 2 ] && ok "passed: 결과 없으면 exit 2" || no "passed 없음"
bouncer record t 'echo hi; exit 3' >/dev/null; [ $? = 3 ] && ok "record: 명령의 종료코드를 돌려준다" || no "record rc"
[ "$(tail -1 .ai-bouncer/results/t)" = 'exit: 3' ] && grep -qx hi .ai-bouncer/results/t && ok "record: 출력과 exit 줄을 남긴다" || no "record 파일"
bouncer passed t | grep -q hi; [ "${PIPESTATUS[0]}" = 2 ] && ok "passed: 실패한 결과는 exit 2 + 끝부분" || no "passed 실패"
bouncer record t true >/dev/null && bouncer passed t && ok "passed: 통과한 최신 결과" || no "passed 통과"
sleep 1; echo again >> app.js
bouncer passed t >/dev/null; [ $? = 2 ] && ok "passed: 결과 뒤에 고친 파일 있으면 exit 2" || no "passed 낡음"
says "결과 이름" bouncer record ../x true && ok "record: 경로가 든 이름 거부" || no "record 이름"
unset BOUNCER_TASK_DIR; b1 cancel >/dev/null

cleanup; finish
