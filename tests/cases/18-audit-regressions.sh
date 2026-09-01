#!/usr/bin/env bash
# 케이스 18 — 실사용 감사에서 나온 회귀들.
# 전부 "조용히 잘못된 결과를 내던" 것들이라, 하나라도 풀리면 게이트가 무의미해진다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 픽스처는 케이스마다 따로 둔다. 전역 경로를 쓰면 케이스끼리 덮어쓴다.
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
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
  || abort_setup "e2e step 추가" "컴파일 실패"
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
says '제안한 조건이 아니다' bouncer skip "verify/e2e" \
  && ok "제안 전에는 skip 거부" || no "skip 거부" "$(bouncer skip 'verify/e2e' 2>&1|head -1)"
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
# 제안은 그대로 복사해서 실행할 수 있어야 한다. id 에 공백이 있어 쪼개지던 버그.
SUG="$(printf '%s' "$r" | jq -r '.reason // .hookSpecificOutput.additionalContext // ""' \
       | grep -o "bouncer skip '[^']*'" | head -1)"
[ -n "$SUG" ] && ok "제안에 실행 가능한 step id 가 실린다" || no "제안 형식" "id 없음"
if [ -n "$SUG" ]; then
  eval "bouncer ${SUG#bouncer }" >/dev/null 2>&1 \
    && ok "제안한 명령이 그대로 실행된다" || no "제안 실행 실패" "$SUG"
fi
# 표시는 한 번 쓰면 소모된다. 안 그러면 그 스테이지가 영구히 열린 채 남는다.
says '제안한 조건이 아니다' bouncer skip "finalize/워킹트리 정리 확인" \
  && ok "같은 제안을 두 번 쓸 수 없다" || no "제안이 소모되지 않음"
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

echo
echo "[감사가 지적한 나머지 회귀]"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# 이름이 bouncer.sh 로 끝나는 아무 스크립트나 면제받던 것
bouncer start plan f2 >/dev/null
mkdir -p "$T/tools"; printf '#!/bin/sh\ngit push\n' > "$T/tools/bouncer.sh"; chmod +x "$T/tools/bouncer.sh"
F2=0
for c in "./tools/bouncer.sh" "/tmp/evil/bouncer.sh --do-it" "tools/bouncer.sh status"; do
  [ -n "$(pre Bash "$(jq -nc --arg c "$c" '{command:$c}')")" ] || F2=1
done
[ "$F2" = 0 ] && ok "bouncer.sh 이름만 흉내낸 스크립트는 면제 안 됨 (3건)" || no "이름 흉내 통과"
[ -z "$(pre Bash '{"command":"bouncer status"}')" ] && ok "진짜 bouncer 는 여전히 통과" || no "정상 호출 차단됨"

# 세션 ID 없이 남의 작업을 바꾸지 못한다
says '이 세션 것이 아니다' env -u CLAUDE_CODE_SESSION_ID bash "$R/engine/bouncer.sh" cancel \
  && ok "세션 ID 없으면 남의 작업을 취소하지 못한다" || no "남의 작업 취소됨"
ls "$T"/.ai-bouncer/tasks/*/.active >/dev/null 2>&1 && ok "잠금이 그대로다" || no "잠금 사라짐"
says '현재 단계' env -u CLAUDE_CODE_SESSION_ID bash "$R/engine/bouncer.sh" status \
  && ok "조회는 세션 ID 없이도 된다" || no "status 안 됨"

# state.json 손상 시 Stop 도 알린다 (예전엔 조용히 무관여)
cp "$(task_dir)/state.json" "$T/st.bak"
printf '{ nope' > "$(task_dir)/state.json"
r=$(stop); printf '%s' "$r" | grep -q '손상' && ok "손상 state를 Stop이 알린다" || no "Stop 침묵" "${r:0:60}"
# 잠금을 놓아야 resume 목록에 오를 자격이 생긴다.
# 예전 단정은 .active 를 쥔 채로 확인해서 손상 필터를 지워도 항상 통과했다.
BROKEN_ID="$(basename "$(task_dir)")"
rm -f "$(task_dir)/.active"
bouncer resume 2>&1 | grep -q "$BROKEN_ID" \
  && no "손상 작업 노출" "$BROKEN_ID 가 목록에 있다" || ok "손상된 작업은 이어받기 목록에서 제외"
says '상태 파일이 손상' bouncer resume "$BROKEN_ID" \
  && ok "id로 지정해도 손상된 작업은 거부" || no "손상 작업을 물어버림"
cp "$T/st.bak" "$(task_dir)/state.json"; bouncer cancel >/dev/null 2>&1
rm -f "$T"/.ai-bouncer/tasks/*/.active

# compiled.json 손상 시 scan / start 가 오진하지 않는다
cp "$T/.claude/ai-bouncer/workflow.compiled.json" "$T/cc.bak"
printf 'nope' > "$T/.claude/ai-bouncer/workflow.compiled.json"
says '컴파일 결과가 손상' bouncer scan && ok "scan이 손상을 알린다" || no "scan 오진" "$(bouncer scan 2>&1|head -2)"
says '컴파일 결과가 손상' bouncer start simple x && ok "start가 손상을 알린다" || no "start 오진" "$(bouncer start simple x 2>&1|head -1)"
cp "$T/cc.bak" "$T/.claude/ai-bouncer/workflow.compiled.json"

echo
echo "[감사가 테스트 없다고 지적한 것들]"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active


# 미머지 병렬 작업에 finished_at 을 찍으면 ORPHAN 목록에서 사라진다
bouncer start simple fin --parallel >/dev/null 2>&1
WT3="$(jq -r '.worktree.path' "$(task_dir)/state.json")"
if [ -d "$WT3" ]; then
  git -C "$WT3" commit -q --allow-empty -m w
  stop >/dev/null; stop >/dev/null
  bouncer run "verify/e2e" >/dev/null 2>&1
  user_turn >/dev/null; bouncer done "verify/검증 보고" >/dev/null 2>&1
  stop >/dev/null; stop >/dev/null; stop >/dev/null
  [ -z "$(jq -r '.finished_at // ""' "$(task_dir)/state.json")" ] \
    && ok "미머지 병렬 작업에 finished_at 을 안 찍는다" || no "finished_at 기록됨"
  rm -f "$(task_dir)/.active"
  says "$(basename "$(task_dir)")" bouncer scan \
    && ok "그래서 ORPHAN 으로 보인다 (커밋이 갇히지 않는다)" || no "ORPHAN 미노출"
fi
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# status 가 step id 를 보여줘야 skip 제안을 따라갈 수 있다
bouncer start simple sid >/dev/null
says 'id: implement/구현' bouncer status && ok "status가 step id를 보여준다" || no "id 미출력" "$(bouncer status|tail -3)"

# cd 가 리터럴이 아니면 상대경로 쓰기를 막는다
GU="$R/engine/lib/guard.py"
CD_BAD=0
for c in "cd /tmp && cd - && rm -f app.js" "cd \$PWD && rm -f app.js" \
         "cd \"\$(pwd)\" && rm -f app.js" "(cd /tmp); rm -f app.js"; do
  [ -n "$(printf '%s' "$c" | python3 "$GU" '["**","!docs/**"]' false '[]' "$T" '' "$T")" ] || CD_BAD=1
done
[ "$CD_BAD" = 0 ] && ok "비리터럴 cd 뒤 상대경로 쓰기 차단 (4건)" || no "비리터럴 cd 통과"
[ -z "$(printf 'cd docs && rm -f x.md' | python3 "$GU" '["**","!docs/**"]' false '[]' "$T" '' "$T")" ] \
  && ok "리터럴 cd 는 정상 통과" || no "정상 cd 차단됨"
bouncer cancel >/dev/null 2>&1


echo
echo "[제안 토큰은 전이해도 살아남고, 제안한 것만 열린다]"
# 스테이지 단위로 열면 (a) 제안 안 한 게이트까지 열리고 (b) 하나 쓰면 나머지가
# 닫히며 (c) 다음 전이가 표시를 지워 "시킨 대로 했더니 닫힌다"가 된다.
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active
bouncer start simple tok >/dev/null
stop >/dev/null                                  # implement → verify
python3 - "$(task_dir)/state.json" <<'PYX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['skip_allowed'] = ['verify/검증 보고']          # 엔진이 제안한 상황
json.dump(d, open(p, 'w'))
PYX
says '제안한 조건이 아니다' bouncer skip "verify/e2e" \
  && ok "제안 목록에 없는 게이트는 거부" || no "제안 안 한 것도 열림"
says 'SKIPPED' bouncer skip "verify/검증 보고" \
  && ok "제안한 것은 통과" || no "제안한 것이 거부됨"
[ "$(jq -r '.skip_allowed | length' "$(task_dir)/state.json")" = 0 ] \
  && ok "쓰면 제안이 소모된다" || no "제안 잔류" "$(jq -c .skip_allowed "$(task_dir)/state.json")"

# 전이해도 남은 제안은 살아 있어야 한다 (엔진이 시킨 대로 하면 Stop 이 한 번 더 뜬다)
python3 - "$(task_dir)/state.json" <<'PYX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['skip_allowed'] = ['finalize/워킹트리 정리 확인']
json.dump(d, open(p, 'w'))
PYX
user_turn >/dev/null; bouncer done "verify/검증 보고" >/dev/null 2>&1
bouncer run "verify/e2e" >/dev/null 2>&1
stop >/dev/null                                  # verify → finalize
[ "$(jq -r '.skip_allowed[0] // ""' "$(task_dir)/state.json")" = "finalize/워킹트리 정리 확인" ] \
  && ok "전이해도 제안은 살아남는다" || no "전이가 제안을 지웠다" "$(jq -c .skip_allowed "$(task_dir)/state.json")"
bouncer cancel >/dev/null 2>&1

echo "[감사가 회귀 감지 0이라고 지적한 수정들]"
GU="$R/engine/lib/guard.py"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# worktree 안에서도 edit_files 스코프가 살아야 한다 (--parallel 에서만 사라졌다)
WTP="$T/.wt"; mkdir -p "$WTP/src" "$WTP/docs"
SC='["**","!src/**"]'
[ -n "$(printf 'rm -f docs/x.md' | python3 "$GU" "$SC" false '[]' "$T" "$WTP" "$WTP")" ] \
  && ok "worktree 안 스코프 밖은 차단" || no "worktree 스코프 소실" "통과됨"
[ -z "$(printf 'rm -f src/a.js' | python3 "$GU" "$SC" false '[]' "$T" "$WTP" "$WTP")" ] \
  && ok "worktree 안 예외 경로는 허용" || no "worktree 예외 차단됨"
[ -n "$(python3 "$GU" --check-path "$SC" "$T" "$WTP/docs/x.md" "$WTP" "$WTP")" ] \
  && ok "Edit 도 worktree 안 스코프를 본다" || no "Edit 스코프 소실"

# 슬래시 없는 `bouncer.sh` 는 엔진이 아니다
[ -n "$(printf 'bouncer.sh anything' | python3 "$GU" true false '[]' "$T" '' "$T")" ] \
  && ok "bouncer.sh 이름만으로 면제받지 않는다" || no "이름 면제 통과"

# EDIT→PUSH 패스 사이 cd 추적 누수 (쓰기보다 뒤에 오는 cd 가 앞을 막았다)
[ -z "$(printf 'touch src/a.js && cd -' | python3 "$GU" "$SC" true '[]' "$T" "$WTP" "$WTP")" ] \
  && ok "쓰기 뒤에 오는 cd 는 앞을 막지 않는다" || no "패스 간 cd 누수"

# 설정 손상을 Stop 이 정확히 보고하고, 무한 차단하지 않는다
bouncer start simple cfg >/dev/null
cp "$T/.claude/ai-bouncer/workflow.compiled.json" "$T/cc2.bak"
printf 'nope' > "$T/.claude/ai-bouncer/workflow.compiled.json"
r=$(stop); printf '%s' "$r" | grep -q '설정을 읽을 수 없다' \
  && ok "Stop 이 설정 손상을 정확히 보고" || no "Stop 오진" "${r:0:70}"
REL=0
for i in $(seq 1 30); do
  printf '%s' "$(stop)" | grep -q '"decision"' || REL=1
done
[ "$REL" = 1 ] && ok "무한 차단하지 않고 세션을 돌려준다" || no "12회 연속 차단" "안전밸브 미작동"
cp "$T/cc2.bak" "$T/.claude/ai-bouncer/workflow.compiled.json"
bouncer cancel >/dev/null 2>&1

# 인자 없는 resume 은 세션 ID 없이도 되는 조회다
env -u CLAUDE_CODE_SESSION_ID bash "$R/engine/bouncer.sh" resume >/dev/null 2>&1 \
  && ok "세션 ID 없이도 resume 목록 조회" \
  || no "조회가 막힘" "$(env -u CLAUDE_CODE_SESSION_ID bash "$R/engine/bouncer.sh" resume 2>&1|head -1)"


echo
echo "[state.json 이 깨져도 안전밸브가 작동한다]"
# 카운터를 state.json 에만 두면, 상태가 깨진 바로 그 경우에 안전밸브가
# 원리상 작동하지 않는다 (40회 연속 차단이 재현됐다).
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active
bouncer start simple sv >/dev/null
printf 'garbage' > "$(task_dir)/state.json"
REL=0
for i in $(seq 1 40); do
  printf '%s' "$(stop)" | grep -q '"decision"' || { REL=$i; break; }
done
[ "$REL" != 0 ] && ok "손상 상태에서도 ${REL}회째 세션을 돌려준다" \
                || no "무한 차단" "40회 전부 막혔다"
rm -f "$T"/.ai-bouncer/tasks/*/.active

echo
echo "[사람 확인과 함께 있는 스테이지도 on_fail 이 발동한다]"
# HUMAN_WAIT 하나로 막으면 기본 default.yaml 의 verify(사람 확인 + run 게이트)는
# on_fail 이 절대 발동하지 않는다. README 는 그 반송을 기본 기능으로 그린다.
cat > "$FIXTURE_DIR/_hf.yaml" <<'Y'
version: 1
workflows:
  dev: {label: t, stages: [implement, verify, done]}
stages:
  implement:
    steps: [{label: 구현, inject: "구현해라"}]
  verify:
    on_fail: implement
    steps:
      - label: 사람 확인
        blocking: true
        inject: "검증 결과를 보고해라"
      - label: 게이트
        run: "test -f PASSME"
        by: engine
        blocking: true
  done:
    steps: [{label: 완료, inject: "끝"}]
Y
cleanup; setup "$FIXTURE_DIR/_hf.yaml" >/dev/null || abort_setup "on_fail 픽스처" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer start dev hf >/dev/null
stop >/dev/null                                  # implement → verify
BACK=0
for i in $(seq 1 6); do
  stop >/dev/null
  [ "$(stage)" = implement ] && { BACK=$i; break; }
  user_turn >/dev/null; bouncer done "verify/사람 확인" >/dev/null 2>&1
done
[ "$BACK" != 0 ] && ok "run 게이트가 실패하면 사람 확인이 있어도 반송된다" \
                 || no "반송 안 됨" "$(stage) 에 머묾"
bouncer cancel >/dev/null 2>&1

finish
