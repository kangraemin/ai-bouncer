#!/usr/bin/env bash
# 케이스 05 — CLI: scan, check, record/passed, 다중 세션 격리
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"

b1 scan | grep -q $'^STATE\tNONE$' && ok "scan: 작업 없음" || no "scan none"
b1 scan | grep -q $'^WORKFLOW\tmain\t기본$' && ok "scan: 모드 목록" || no "scan workflow"
bouncer check | grep -q '^OK' && ok "check: 유효" || no "check"
says "세션 ID" bouncer start main t --pick b=x && ok "세션 없이 start 거부" || no "세션 없음"
says "정의되지 않은 모드" b1 start nope t && ok "없는 모드 거부" || no "없는 모드"

b1 start main c1 --pick b=x >/dev/null
b1 scan | grep -q $'^STATE\tMINE\t.*\tmain\ta$' && ok "scan: 내 작업" || no "scan mine" "$(b1 scan)"
says "이미 진행 중인 작업" b1 start main c2 --pick b=x && ok "한 세션에 작업 둘 거부" || no "중복 작업"
b1 scan | grep -q '파일에서 읽은 지시' && ok "scan: 이어서 할 작업이면 현재 단계 지시를 준다" || no "scan 지시" "$(b1 scan)"

# 다른 세션은 따로 논다
SID=S2 b1 scan | grep -q $'^STATE\tNONE$' && ok "다른 세션 scan 은 NONE" || no "S2 scan"
SID=S2 b1 start main c3 --pick b=y >/dev/null && ok "다른 세션은 따로 시작" || no "S2 start"
[ "$(ls -d .ai-bouncer/tasks/*/.active | wc -l | tr -d ' ')" = 2 ] && ok "작업 둘이 따로 잠긴다" || no "잠금 둘"
says "활성 작업이 없다" bouncer cancel && ok "세션 없이 cancel 거부" || no "세션 없는 cancel"
SID=S2 b1 cancel >/dev/null
b1 cancel | grep -q '^CANCELLED' && ok "cancel" || no "cancel"
[ "$(state .current_stage)" = cancelled ] && ok "cancel 기록" || no "cancel 기록"

mkdir -p .ai-bouncer; b1 start main c4 --pick b=x >/dev/null; export BOUNCER_TASK_DIR="$(task_dir)"

# record / passed — 검사는 모델이 record 로 돌리고, run 은 passed 로 결과만 본다
bouncer passed t >/dev/null; [ $? = 2 ] && ok "passed: 결과 없으면 exit 2" || no "passed 없음"
bouncer record t 'echo hi; exit 3' >/dev/null; [ $? = 3 ] && ok "record: 명령의 종료코드를 돌려준다" || no "record rc"
[ "$(tail -1 .ai-bouncer/results/t)" = 'exit: 3' ] && grep -qx hi .ai-bouncer/results/t && ok "record: 출력과 exit 줄을 남긴다" || no "record 파일"
bouncer passed t | grep -q hi; [ "${PIPESTATUS[0]}" = 2 ] && ok "passed: 실패한 결과는 exit 2 + 끝부분" || no "passed 실패"
bouncer record t true >/dev/null && bouncer passed t && ok "passed: 통과한 최신 결과" || no "passed 통과"
sleep 1; echo again >> app.js
bouncer passed t >/dev/null; [ $? = 2 ] && ok "passed: 결과 뒤에 고친 파일 있으면 exit 2" || no "passed 낡음"
bouncer record t true >/dev/null; sleep 1; echo new > new.txt
bouncer passed t >/dev/null; [ $? = 2 ] && ok "passed: 결과 뒤에 생긴 새 파일도 본다" || no "passed untracked"
says "결과 이름" bouncer record ../x true && ok "record: 경로가 든 이름 거부" || no "record 이름"
printf 'a b\n' > 'sp ace.txt'
bouncer record q grep -c "a b" "sp ace.txt" >/dev/null && ok "record: 인자 여럿이면 따옴표 인자를 그대로 넘긴다" || no "record 인자" "$(cat .ai-bouncer/results/q)"
bouncer record q 'grep -q "a b" "sp ace.txt" && echo yes' | grep -qx yes && ok "record: 인자 하나면 셸 문자열로 돈다" || no "record 셸"
bouncer record q 'printf no-newline' >/dev/null; [ "$(tail -1 .ai-bouncer/results/q)" = 'exit: 0' ] && bouncer passed q >/dev/null \
  && ok "record: 개행 없이 끝나는 출력도 exit 줄은 따로" || no "record 개행" "$(cat .ai-bouncer/results/q)"
cp .gitignore .gi.keep; : > .gitignore   # .ai-bouncer/ 를 ignore 하지 않은 레포
sleep 1; bouncer record q true >/dev/null; sleep 1; bouncer record q2 true >/dev/null
bouncer passed q >/dev/null && ok "passed: 다른 결과 파일은 '바뀐 파일'로 치지 않는다 (ignore 안 한 레포)" || no "결과끼리 교착" "$(bouncer passed q)"
mv .gi.keep .gitignore
says "작업을 시작하기 전" bouncer passed q && no "옛 결과" || ok "passed: 이번 작업에서 만든 결과는 통과"
unset BOUNCER_TASK_DIR; b1 cancel >/dev/null
b1 start main c5 --pick b=x >/dev/null; export BOUNCER_TASK_DIR="$(task_dir)"
says "시작하기 전" bouncer passed q && ok "passed: 지난 작업의 결과는 재사용하지 않는다" || no "지난 결과 재사용" "$(bouncer passed q)"
unset BOUNCER_TASK_DIR; b1 cancel >/dev/null
says "두 번" b1 start main c6 --pick b=x --pick b=y && ok "start: 같은 단계 --pick 두 번은 거부" || no "중복 pick"

# 세션 중에 설정을 고치고 시작하면 start 가 다시 컴파일한다 (SessionStart 때 만든 결과는 옛것)
echo "고친 a 지시" > .claude/ai-bouncer/prompts/a.md
b1 start main c7 --pick b=x | grep -q '고친 a 지시' && ok "start: 바뀐 설정을 다시 컴파일해 쓴다" || no "start 재컴파일"
b1 cancel >/dev/null

# 첫 커밋 전 레포 — add 만 한 파일을 고쳐도 낡았다고 본다
N="$(mktemp -d)"; ( cd "$N" && git init -q . && echo v1 > a.js && git add a.js \
  && bouncer record t true >/dev/null && sleep 1 && echo v2 > a.js && bouncer passed t >/dev/null ); rc=$?
[ "$rc" = 2 ] && ok "passed: 첫 커밋 전 레포에서도 add 한 파일 수정을 본다" || no "커밋 전 레포" "rc=$rc"

cleanup; finish
