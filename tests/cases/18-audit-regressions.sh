#!/usr/bin/env bash
# 케이스 18 — 실사용 감사에서 나온 회귀들.
# 전부 "조용히 잘못된 결과를 내던" 것들이라, 하나라도 풀리면 게이트가 무의미해진다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1

echo "[진행 중 워크플로우가 config에서 사라지면]"
# 예전엔 next가 빈 값 → "종단 도달"로 오해 → finalize(커밋·클린 트리)를 통째로 건너뛰고
# 작업이 "완료" 처리됐다. push까지 열렸다.
bouncer start simple rename >/dev/null
stop >/dev/null; stop >/dev/null                       # implement → verify
python3 - "$T/.claude/ai-bouncer/workflow.yaml" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, 'w').write(s.replace('\n  simple:\n', '\n  simplified:\n'))
PY
python3 "$R/engine/compile.py" "$T/.claude/ai-bouncer/workflow.yaml" \
        "$T/.claude/ai-bouncer/workflow.compiled.json" >/dev/null
user_turn >/dev/null; bouncer done "verify/검증 보고" >/dev/null
r=$(stop)
printf '%s' "$r" | grep -q '체인을 찾을 수 없다' && ok "체인 소실을 알린다" || no "체인 소실" "$(printf '%s' "$r" | head -c 120)"
[ "$(stage)" = verify ] && ok "완료로 처리하지 않는다" || no "종단 오판" "$(stage)"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && ok "잠금 유지" || no "잠금 해제됨"
bouncer cancel >/dev/null

echo
echo "[--off 로 끈 항목]"
git -C "$T" checkout -q -- .claude/ai-bouncer/workflow.yaml 2>/dev/null
python3 - "$T/.claude/ai-bouncer/workflow.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("""    forbid:
      push: true
      reason: 검증이 끝나기 전에는 push할 수 없다.""",
"""      - label: e2e
        run: "echo E2E-RAN"
        by: engine
        blocking: true
        optional: true
    forbid:
      push: true
      reason: 검증이 끝나기 전에는 push할 수 없다.""")
open(p, 'w').write(s)
PY
python3 "$R/engine/compile.py" "$T/.claude/ai-bouncer/workflow.yaml" \
        "$T/.claude/ai-bouncer/workflow.compiled.json" >/dev/null \
  || { no "e2e step 추가" "컴파일 실패"; echo
echo "[핵심 차단이 실제로 걸리는가]"
# 감사에서 이 기능들을 전부 no-op으로 바꿔도 테스트가 전건 통과했다.
# 무력화하면 반드시 여기서 빨간불이 나야 한다.
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# (a) 엔진 디렉토리 삭제 — 제약 없는 done 단계에서도 막혀야 한다
bouncer start simple guard1 >/dev/null
for c in "rm -rf .ai-bouncer" "git clean -fdx" "rm -rf .ai*" "rm -rf .claude" \
         "find . -name state.json -delete"; do
  r=$(pre Bash "$(jq -nc --arg c "$c" '{command:$c}')")
  [ -n "$r" ] || { no "엔진 보호" "$c 통과됨"; G1=1; }
done
[ "${G1:-0}" = 0 ] && ok "엔진 디렉토리를 지우는 명령 차단 (5건)"

# (b) 스테이지가 yaml에서 사라지면 Stop과 PreToolUse 둘 다 막아야 한다
cp "$T/.claude/ai-bouncer/workflow.compiled.json" "$T/compiled.bak"
jq 'del(.stages.implement)' "$T/compiled.bak" > "$T/.claude/ai-bouncer/workflow.compiled.json"
r=$(stop); printf '%s' "$r" | grep -q "workflow.yaml에 없다" \
  && ok "스테이지 소실 — Stop이 차단" || no "Stop 무반응" "${r:0:80}"
r=$(pre Bash '{"command":"echo hi"}'); printf '%s' "$r" | grep -q "workflow.yaml에 없다" \
  && ok "스테이지 소실 — PreToolUse가 차단" || no "PreToolUse 무반응" "${r:0:80}"
r=$(pre Bash '{"command":"bouncer cancel"}')
[ -z "$r" ] && ok "그 상황에서도 bouncer cancel 은 통과" || no "탈출구까지 막힘" "${r:0:60}"
cp "$T/compiled.bak" "$T/.claude/ai-bouncer/workflow.compiled.json"
bouncer cancel >/dev/null 2>&1

# (c) worktree 밖 쓰기 차단 + 그 안 상대경로 허용
bouncer start simple guard2 --parallel >/dev/null 2>&1
WT2="$(jq -r '.worktree.path' "$(task_dir)/state.json")"
if [ -d "$WT2" ]; then
  r=$(pre Bash "$(jq -nc --arg c "echo x > $T/app.js" '{command:$c}')")
  [ -n "$r" ] && ok "worktree 작업 중 메인 레포 셸 쓰기 차단" || no "메인 쓰기 통과"
  r=$(pre Bash "$(jq -nc --arg c "cd $WT2 && echo x > src/new.js" '{command:$c}')")
  [ -z "$r" ] && ok "cd 뒤 worktree 안 상대경로는 허용" || no "worktree 안 차단됨" "${r:0:70}"
  # (d) 미머지 worktree면 종단에서 잠금을 유지해야 finalize가 가능하다
  git -C "$WT2" commit -q --allow-empty -m w
  stop >/dev/null                        # implement → verify
  stop >/dev/null                        # 사람 대기 표시
  bouncer run "verify/e2e" >/dev/null 2>&1
  user_turn >/dev/null
  bouncer done "verify/검증 보고" >/dev/null 2>&1
  stop >/dev/null                        # verify → finalize
  stop >/dev/null                        # finalize (worktree는 커밋 완료라 통과)
  r=$(stop)                              # done — 여기서 머지를 요구해야 한다
  printf '%s' "$r" | grep -q 'worktree finalize' && ok "미머지 worktree면 종단에서 머지를 요구" \
    || no "머지 요구 없음" "stage=$(stage) ${r:0:70}"
  ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 \
    && ok "그때 잠금을 유지한다 (finalize가 작업을 찾을 수 있다)" || no "잠금 해제됨"
  says 'MERGED' bouncer worktree finalize && ok "finalize가 실제로 머지" \
    || no "finalize 실패" "$(bouncer worktree finalize 2>&1 | head -2)"
else
  no "worktree 생성" "$WT2"
fi
bouncer cancel >/dev/null 2>&1

echo
echo "[resume 이 한 세션 한 작업을 지킨다]"
bouncer start simple dup1 >/dev/null
D2="$(basename "$(task_dir)")"
CLAUDE_CODE_SESSION_ID=S8 bash "$R/engine/bouncer.sh" release --force >/dev/null 2>&1
bouncer start simple dup2 >/dev/null
says '이미 진행 중인 작업' bouncer resume "$D2" \
  && ok "진행 중인데 다른 작업을 이어받지 못한다" || no "중복 점유 허용됨"
says 'ORPHAN' bouncer scan && ok "잠금 없는 미완 작업을 scan이 보여준다" || no "ORPHAN 미표시"
bouncer cancel >/dev/null 2>&1

finish; exit; }
bouncer start simple off1 --off "verify/e2e" >/dev/null
LATEST="$(ls -dt "$T"/.ai-bouncer/tasks/*/ | head -1)"
[ "$(jq -r '.choices["verify/e2e"]' "$LATEST/state.json")" = false ] \
  && ok "state에 false로 기록" || no "choices" "$(jq -c .choices "$LATEST/state.json")"
stop >/dev/null; stop >/dev/null                       # → verify
says '이번 작업에서 끔' bouncer status && ok "status가 꺼짐으로 표시" || no "status 표시" "$(bouncer status | tail -3)"
says '끈 항목이다' bouncer run "verify/e2e" && ok "run이 거부" || no "run 거부" "$(bouncer run 'verify/e2e' 2>&1 | head -2)"
r=$(stop); printf '%s' "$r" | grep -q 'E2E-RAN' && no "Stop이 실행함" "끈 항목인데 돌았다" || ok "Stop도 실행하지 않음"

echo
echo "[--off 에 없는 id를 주면]"
bouncer cancel >/dev/null
says '선택 항목이 아니다' bouncer start simple off2 --off "verify/e2eee" && ok "오타를 거부" || no "오타 통과"

echo
echo "[엔진이 포기한 뒤에만 skip]"
bouncer start simple skip1 >/dev/null
stop >/dev/null; stop >/dev/null
says '엔진이 포기한 단계가 아니다' bouncer skip "verify/e2e" \
  && ok "포기 전에는 skip 거부" || no "skip 거부" "$(bouncer skip 'verify/e2e' 2>&1|head -1)"
says 'step이 이 워크플로우' bouncer skip "verify/없는거" \
  && ok "없는 id는 거부" || no "없는 id 통과"

echo
echo "[죽은 세션의 잠금 회수]"
REL="$(CLAUDE_CODE_SESSION_ID=S2 bash "$R/engine/bouncer.sh" release 2>&1)"
printf '%s' "$REL" | grep -q '세션 S1' \
  && ok "누가 잡고 있는지 보여준다" || no "release 목록" "$(printf '%s' "$REL"|head -2)"
CLAUDE_CODE_SESSION_ID=S2 bash "$R/engine/bouncer.sh" release >/dev/null 2>&1
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && ok "--force 없이는 안 푼다" || no "그냥 풀렸다"
CLAUDE_CODE_SESSION_ID=S2 bash "$R/engine/bouncer.sh" release --force >/dev/null 2>&1
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "--force로 회수" "여전히 남음" || ok "--force로 회수"
ls "$T"/.ai-bouncer/tasks/*/state.json >/dev/null 2>&1 && ok "작업 기록은 보존" || no "기록 소실"
CLAUDE_CODE_SESSION_ID=S2 bash "$R/engine/bouncer.sh" start simple after >/dev/null 2>&1 \
  && ok "회수 후 새 작업 시작 가능" || no "여전히 잠김"

echo
echo "[bouncer workflows]"
bouncer workflows | grep -q 'simple' && ok "모드 목록 출력" || no "workflows" "$(bouncer workflows 2>&1|head -2)"

echo
echo "[하위 디렉토리 SessionEnd]"
mkdir -p "$T/packages/web"
hook session-end "{\"session_id\":\"S2\",\"cwd\":\"$T/packages/web\"}"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "하위에서 잠금 해제" "남아있음" || ok "하위 디렉토리에서도 해제"

echo
echo "[병렬 작업(worktree) split-brain]"
# 예전엔 worktree를 만들어도 세션은 메인 레포에 남아 편집했고,
# 게이트는 손대지 않은 worktree(=클린 트리)를 보고 전부 통과했다.
CLAUDE_CODE_SESSION_ID=S3 bash "$R/engine/bouncer.sh" cancel >/dev/null 2>&1
git -C "$T" add -A >/dev/null 2>&1; git -C "$T" commit -qm cfg >/dev/null 2>&1
export CLAUDE_CODE_SESSION_ID=S3
OUT="$(bouncer start simple para --parallel 2>&1)"
printf '%s' "$OUT" | grep -q 'cd ' && ok "worktree로 이동하라고 안내" || no "이동 안내 없음"
WT="$(ls -dt "$T"/.ai-bouncer/tasks/*/ | head -1)"; WT="$(jq -r '.worktree.path' "$WT/state.json")"
[ -d "$WT" ] && ok "worktree 생성" || no "worktree 없음" "$WT"

# worktree 안에서는 hook이 관여해야 한다 (예전엔 통째로 무관여였다)
r=$(printf '{"session_id":"S3","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$WT"     | bash "$R/hooks/pre-tool.sh")
[ -n "$r" ] && ok "worktree 안에서도 push 차단" || no "worktree 안 무관여" "통과됨"
says '체인:' env BOUNCER_PROJECT="$WT" bash "$R/engine/bouncer.sh" status   && ok "worktree 안에서 status가 같은 작업을 본다" || no "status 무관여"

# 메인 레포 편집은 막아야 한다 — 여기서 고치면 검증이 다른 트리를 본다
r=$(pre Edit "{\"file_path\":\"$T/app.js\"}" S3)
printf '%s' "$r" | grep -q 'worktree' && ok "메인 레포 편집 차단" || no "메인 편집 허용됨" "${r:0:80}"
r=$(printf '{"session_id":"S3","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/app.js"}}' "$WT" "$WT"     | bash "$R/hooks/pre-tool.sh")
[ -z "$r" ] && ok "worktree 안 편집은 허용" || no "worktree 편집 차단됨" "${r:0:80}"

# worktree가 사라지면 조용히 프로젝트로 폴백하지 않고 알려야 한다
rm -rf "$WT"
r=$(stop S3)
printf '%s' "$r" | grep -q '작업 트리가 사라졌다' && ok "worktree 소실을 알린다" || no "소실 감지" "${r:0:100}"
bouncer cancel >/dev/null 2>&1

echo
echo "[손상된 state.json]"
bouncer start simple broken >/dev/null 2>&1
BT="$(ls -dt "$T"/.ai-bouncer/tasks/*/ | head -1)"
cp "$BT/state.json" "$BT/state.bak"
echo '{ broken' > "$BT/state.json"
if bouncer status >/dev/null 2>&1; then no "손상 state 보고" "rc=0으로 조용히 성공"; else ok "손상 state는 실패로 알린다"; fi
says '손상' bouncer status && ok "무엇이 문제인지 말한다" || no "손상 안내 없음"
mv "$BT/state.bak" "$BT/state.json"; bouncer cancel >/dev/null 2>&1

echo
echo "[종단 스테이지에 통과 조건]"
cat > "$T/term.yaml" <<'Y'
version: 1
workflows:
  s: {label: t, stages: [implement, done]}
stages:
  implement:
    steps: [{label: 구현, inject: "x"}]
  done:
    steps: [{label: 완료, inject: "끝", blocking: true}]
Y
if python3 "$R/engine/compile.py" "$T/term.yaml" >/dev/null 2>&1; then
  no "종단 blocking 거부" "통과됨 — 작업이 영원히 안 끝난다"
else
  ok "종단 스테이지의 통과 조건을 거부"
fi

echo
echo "[skip이 실제로 통과시키는 경로]"
# 거부만 검증하면 "영원히 거부"도 통과한다. 엔진이 포기한 뒤 실제로 넘어가야 한다.
export CLAUDE_CODE_SESSION_ID=S1     # 앞 섹션이 S3로 바꿔둔다 — stop()은 S1을 쓴다
bouncer cancel >/dev/null 2>&1
rm -f "$T"/.ai-bouncer/tasks/*/.active
bouncer start simple gate >/dev/null
echo dirty >> app.js                       # finalize 클린 트리 게이트를 못 넘게
stop >/dev/null                            # implement → verify
[ "$(stage)" = verify ] || no "verify 진입" "$(stage)"
stop >/dev/null                            # 사람 대기 표시 (blocking: true)
bouncer run "verify/e2e" >/dev/null 2>&1
user_turn >/dev/null                       # 사람이 실제로 답한 상황
bouncer done "verify/검증 보고" >/dev/null 2>&1
stop >/dev/null                            # verify → finalize
[ "$(stage)" = finalize ] || no "finalize 진입" "$(stage)"
GAVE=0
for i in $(seq 1 14); do
  r=$(stop)
  printf '%s' "$r" | grep -q 'bouncer skip' && { GAVE=1; break; }
done
[ "$GAVE" = 1 ] && ok "엔진이 포기하며 skip을 제안한다" || no "포기 제안 없음" "14회 안에 안 나옴"
says 'SKIPPED' bouncer skip "finalize/워킹트리 정리 확인" \
  && ok "제안 뒤에는 skip이 통한다" || no "skip 거부됨" "$(bouncer skip 'finalize/워킹트리 정리 확인' 2>&1|head -2)"
says '건너뜀' bouncer status && ok "status가 건너뜀으로 표시" || no "status 미표시" "$(bouncer status|tail -3)"
stop >/dev/null
[ "$(stage)" = done ] && ok "skip 후 실제로 전이한다" || no "전이 안 됨" "$(stage)"
bouncer cancel >/dev/null 2>&1

echo
echo "[release 후 resume]"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1
bouncer start simple res >/dev/null
RT="$(basename "$(ls -dt "$T"/.ai-bouncer/tasks/*/ | head -1)")"
CLAUDE_CODE_SESSION_ID=S9 bash "$R/engine/bouncer.sh" release --force >/dev/null 2>&1
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && no "회수 실패" "잠금 남음" || ok "잠금 회수"
says 'RESUMED' env CLAUDE_CODE_SESSION_ID=S9 bash "$R/engine/bouncer.sh" resume "$RT" \
  && ok "다른 세션이 이어받는다" || no "resume 실패" "$(CLAUDE_CODE_SESSION_ID=S9 bash "$R/engine/bouncer.sh" resume "$RT" 2>&1|head -2)"
says '체인:' env CLAUDE_CODE_SESSION_ID=S9 bash "$R/engine/bouncer.sh" status \
  && ok "이어받은 세션이 작업을 본다" || no "status 안 보임"
says '알 수 없는 인자' bouncer release --forcex && ok "release 오타 거부" || no "오타 통과"
CLAUDE_CODE_SESSION_ID=S9 bash "$R/engine/bouncer.sh" cancel >/dev/null 2>&1

echo
echo "[두 게이트가 같은 답을 낸다]"
# Edit 판정과 Bash 판정이 각각 구현돼 있어 `*`의 의미와 `!` 우선순위가 정반대였다
GU="$R/engine/lib/guard.py"
for pat in '["src/*"]' '["!src/**","src/a.js"]' '["**","!docs/**"]'; do
  for f in src/deep/c.js src/a.js docs/d.md app.js; do
    e=$(python3 "$GU" --check-path "$pat" "$T" "$T/$f")
    b=$(printf '%s' "rm $T/$f" | python3 "$GU" "$pat" false '[]' "$T")
    if { [ -n "$e" ] && [ -z "$b" ]; } || { [ -z "$e" ] && [ -n "$b" ]; }; then
      no "게이트 불일치" "$pat / $f — Edit=${e:+차단}${e:-통과} Bash=${b:+차단}${b:-통과}"; MISMATCH=1
    fi
  done
done
[ "${MISMATCH:-0}" = 0 ] && ok "Edit 게이트와 Bash 게이트 판정 일치 (12조합)"

echo
echo "[핵심 차단이 실제로 걸리는가]"
# 감사에서 이 기능들을 전부 no-op으로 바꿔도 테스트가 전건 통과했다.
# 무력화하면 반드시 여기서 빨간불이 나야 한다.
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# (a) 엔진 디렉토리 삭제 — 제약 없는 done 단계에서도 막혀야 한다
bouncer start simple guard1 >/dev/null
for c in "rm -rf .ai-bouncer" "git clean -fdx" "rm -rf .ai*" "rm -rf .claude" \
         "find . -name state.json -delete"; do
  r=$(pre Bash "$(jq -nc --arg c "$c" '{command:$c}')")
  [ -n "$r" ] || { no "엔진 보호" "$c 통과됨"; G1=1; }
done
[ "${G1:-0}" = 0 ] && ok "엔진 디렉토리를 지우는 명령 차단 (5건)"

# (b) 스테이지가 yaml에서 사라지면 Stop과 PreToolUse 둘 다 막아야 한다
cp "$T/.claude/ai-bouncer/workflow.compiled.json" "$T/compiled.bak"
jq 'del(.stages.implement)' "$T/compiled.bak" > "$T/.claude/ai-bouncer/workflow.compiled.json"
r=$(stop); printf '%s' "$r" | grep -q "workflow.yaml에 없다" \
  && ok "스테이지 소실 — Stop이 차단" || no "Stop 무반응" "${r:0:80}"
r=$(pre Bash '{"command":"echo hi"}'); printf '%s' "$r" | grep -q "workflow.yaml에 없다" \
  && ok "스테이지 소실 — PreToolUse가 차단" || no "PreToolUse 무반응" "${r:0:80}"
r=$(pre Bash '{"command":"bouncer cancel"}')
[ -z "$r" ] && ok "그 상황에서도 bouncer cancel 은 통과" || no "탈출구까지 막힘" "${r:0:60}"
cp "$T/compiled.bak" "$T/.claude/ai-bouncer/workflow.compiled.json"
bouncer cancel >/dev/null 2>&1

# (c) worktree 밖 쓰기 차단 + 그 안 상대경로 허용
bouncer start simple guard2 --parallel >/dev/null 2>&1
WT2="$(jq -r '.worktree.path' "$(task_dir)/state.json")"
if [ -d "$WT2" ]; then
  r=$(pre Bash "$(jq -nc --arg c "echo x > $T/app.js" '{command:$c}')")
  [ -n "$r" ] && ok "worktree 작업 중 메인 레포 셸 쓰기 차단" || no "메인 쓰기 통과"
  r=$(pre Bash "$(jq -nc --arg c "cd $WT2 && echo x > src/new.js" '{command:$c}')")
  [ -z "$r" ] && ok "cd 뒤 worktree 안 상대경로는 허용" || no "worktree 안 차단됨" "${r:0:70}"
  # (d) 미머지 worktree면 종단에서 잠금을 유지해야 finalize가 가능하다
  git -C "$WT2" commit -q --allow-empty -m w
  stop >/dev/null                        # implement → verify
  stop >/dev/null                        # 사람 대기 표시
  bouncer run "verify/e2e" >/dev/null 2>&1
  user_turn >/dev/null
  bouncer done "verify/검증 보고" >/dev/null 2>&1
  stop >/dev/null                        # verify → finalize
  stop >/dev/null                        # finalize (worktree는 커밋 완료라 통과)
  r=$(stop)                              # done — 여기서 머지를 요구해야 한다
  printf '%s' "$r" | grep -q 'worktree finalize' && ok "미머지 worktree면 종단에서 머지를 요구" \
    || no "머지 요구 없음" "stage=$(stage) ${r:0:70}"
  ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 \
    && ok "그때 잠금을 유지한다 (finalize가 작업을 찾을 수 있다)" || no "잠금 해제됨"
  says 'MERGED' bouncer worktree finalize && ok "finalize가 실제로 머지" \
    || no "finalize 실패" "$(bouncer worktree finalize 2>&1 | head -2)"
else
  no "worktree 생성" "$WT2"
fi
bouncer cancel >/dev/null 2>&1

echo
echo "[resume 이 한 세션 한 작업을 지킨다]"
bouncer start simple dup1 >/dev/null
D2="$(basename "$(task_dir)")"
CLAUDE_CODE_SESSION_ID=S8 bash "$R/engine/bouncer.sh" release --force >/dev/null 2>&1
bouncer start simple dup2 >/dev/null
says '이미 진행 중인 작업' bouncer resume "$D2" \
  && ok "진행 중인데 다른 작업을 이어받지 못한다" || no "중복 점유 허용됨"
says 'ORPHAN' bouncer scan && ok "잠금 없는 미완 작업을 scan이 보여준다" || no "ORPHAN 미표시"
bouncer cancel >/dev/null 2>&1

finish
