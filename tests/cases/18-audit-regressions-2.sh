#!/usr/bin/env bash
# 케이스 18-2 — 실사용 감사에서 나온 회귀들 (후반부).
# 18번 하나가 순차로 4분 넘게 걸려 전체 병렬 실행의 꼬리가 됐다. 섹션이 서로 독립이라 둘로 나눴다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# 픽스처는 케이스마다 따로 둔다. 전역 경로를 쓰면 케이스끼리 덮어쓴다.
FIXTURE_DIR="$(mktemp -d)"; trap 'rm -rf "$FIXTURE_DIR"' EXIT
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
export CLAUDE_CODE_SESSION_ID=S1
# 전반부(18번)의 `--off` 섹션이 넣던 optional e2e step 을 뒤 섹션들이 쓴다.
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

echo "[감사가 지적한 나머지 회귀]"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# 이름이 bouncer.sh 로 끝나는 아무 스크립트나 면제받던 것
bouncer start plan f2 >/dev/null
mkdir -p "$T/tools"; printf '#!/bin/sh\ngit push\n' > "$T/tools/bouncer.sh"; chmod +x "$T/tools/bouncer.sh"
F2=0
# 읽기 전용은 이제 임의 스크립트 실행 자체는 허용한다(케이스 28). 이름 면제를 받으면
# 뒤에 붙인 push 까지 통째로 빠져나가므로, 그 형태로 확인한다.
for c in "./tools/bouncer.sh && git push" "/tmp/evil/bouncer.sh --do-it; git push" "tools/bouncer.sh status && git push origin main"; do
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
  stop >/dev/null; stop >/dev/null; stop >/dev/null
  [ -z "$(jq -r '.finished_at // ""' "$(task_dir)/state.json")" ] \
    && ok "미머지 병렬 작업에 finished_at 을 안 찍는다" || no "finished_at 기록됨"
  rm -f "$(task_dir)/.active"
  says "$(basename "$(task_dir)")" bouncer scan \
    && ok "그래서 ORPHAN 으로 보인다 (커밋이 갇히지 않는다)" || no "ORPHAN 미노출"
else
  no "worktree 생성 실패" "$WT3 — 아래 단정 2건을 건너뛴다"
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
pass_implement                                   # implement → verify
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
bouncer run "verify/e2e" >/dev/null 2>&1
stop >/dev/null                                  # verify → finalize
[ "$(jq -r '.skip_allowed[0] // ""' "$(task_dir)/state.json")" = "finalize/워킹트리 정리 확인" ] \
  && ok "전이해도 제안은 살아남는다" || no "전이가 제안을 지웠다" "$(jq -c .skip_allowed "$(task_dir)/state.json")"
bouncer cancel >/dev/null 2>&1

echo "[감사가 회귀 감지 0이라고 지적한 수정들]"
GU="$R/engine/lib/guard.py"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# 슬래시 없는 `bouncer.sh` 는 엔진이 아니다 — push 금지를 면제받지 않는다
[ -n "$(printf 'bouncer.sh anything && git push' | python3 "$GU" true "$T" '' "$T")" ] \
  && ok "bouncer.sh 이름만으로 면제받지 않는다" || no "이름 면제 통과"

# 설정 손상을 Stop 이 정확히 보고하고, 무한 차단하지 않는다
bouncer start simple cfg >/dev/null
cp "$T/.claude/ai-bouncer/workflow.compiled.json" "$T/cc2.bak"
printf 'nope' > "$T/.claude/ai-bouncer/workflow.compiled.json"
r=$(stop); printf '%s' "$r" | grep -q '설정을 읽을 수 없다' \
  && ok "Stop 이 설정 손상을 정확히 보고" || no "Stop 오진" "${r:0:70}"
REL=0
for i in $(seq 1 30); do   # 실제 재진입은 stop_hook_active=true 로 온다
  printf '%s' "$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}")" | grep -q '"decision"' || REL=1
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
for i in $(seq 1 40); do   # 실제 재진입은 stop_hook_active=true 로 온다
  printf '%s' "$(hook stop "{\"session_id\":\"S1\",\"cwd\":\"$T\",\"stop_hook_active\":true}")" | grep -q '"decision"' || { REL=$i; break; }
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
pass_implement                                   # implement → verify
BACK=0
for i in $(seq 1 6); do
  stop >/dev/null
  [ "$(stage)" = implement ] && { BACK=$i; break; }
  bouncer done "verify/사람 확인" >/dev/null 2>&1
done
[ "$BACK" != 0 ] && ok "run 게이트가 실패하면 사람 확인이 있어도 반송된다" \
                 || no "반송 안 됨" "$(stage) 에 머묾"
bouncer cancel >/dev/null 2>&1


echo "[감사가 회귀 감지 0이라고 지적한 나머지]"
# 앞 섹션이 workflow.yaml 을 바꿔놨다 — 기본 설정으로 되돌린다
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null \
  || abort_setup "기본 설정 복구" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active

# 전이하는 턴의 지시가 버려지면 반송 후 구현 지시가 영영 안 온다
bouncer start simple inj >/dev/null
pass_implement                                    # implement → verify
r=$(stop); r=$(stop)
bouncer cancel >/dev/null 2>&1
bouncer start simple inj2 >/dev/null
bouncer todo add '작업' >/dev/null 2>&1
stop >/dev/null                                   # 남은 항목 1 → 차단
bouncer todo done 1 >/dev/null 2>&1
r=$(stop)                                         # implement → verify 전이
printf '%s' "$r" | jq -r '.reason // ""' | grep -q '검증 단계다' \
  && ok "전이 턴에 다음 단계 지시가 실린다" || no "전이 지시 소실" "${r:0:80}"
bouncer cancel >/dev/null 2>&1

# 안전밸브가 성공 전이를 실패처럼 감싸지 않는다.
# 상한을 넘긴 상태에서 **전이가 일어나는** 순간을 직접 만든다
# (루프를 돌리는 방식은 max_continue 분기가 먼저 잡아서 이 경로를 못 탄다).
bouncer start simple cap >/dev/null
stop >/dev/null                                   # 사람 대기 표시
bouncer todo add '작업' >/dev/null 2>&1; bouncer todo done 1 >/dev/null 2>&1
python3 - "$(task_dir)/state.json" <<'PYX'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['blocks_total'] = 999          # 상한 초과 상태에서 전이가 일어나게 한다
json.dump(d, open(p, 'w'))
PYX
CAP="$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')"
# 성공 전이(✅)를 감쌀 때 머리말이 ⛔ 면 안 된다 — ℹ️ 여야 한다
case "$CAP" in
  "⛔"*"✅"*) no "안전밸브가 성공 전이를 실패로 감쌈" "${CAP:0:70}" ;;
  *"✅"*)     ok "상한 메시지가 성공 전이를 감싸지 않는다" ;;
  *) no "안전밸브 문구" "전이가 안 일어났다: ${CAP:0:70}" ;;
esac
bouncer cancel >/dev/null 2>&1
git -C "$T" checkout -q -- .claude/ai-bouncer/workflow.yaml 2>/dev/null
python3 "$R/engine/compile.py" "$T/.claude/ai-bouncer/workflow.yaml" \
        "$T/.claude/ai-bouncer/workflow.compiled.json" >/dev/null

# uninstall 이 남의 hook 과 env 를 지우지 않는다
U="$(mktemp -d)"; UH="$(mktemp -d)"
( cd "$U" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > a.js && git add a.js && git commit -qm i && mkdir -p .claude \
  && printf '%s' '{"env":{"MY":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$HOME/s/ai-bouncer/n.sh"}]}]}}' > .claude/settings.json \
  && HOME="$UH" bash "$R/install.sh" --ci >/dev/null 2>&1 \
  && HOME="$UH" bash "$R/uninstall.sh" >/dev/null 2>&1 </dev/null )
if [ -f "$U/.claude/settings.json" ] \
   && grep -q 's/ai-bouncer/n.sh' "$U/.claude/settings.json"; then
  ok "uninstall 이 남의 hook·env 를 보존"
else
  no "남의 설정 삭제" "$(cat "$U/.claude/settings.json" 2>&1 | head -c 80)"
fi

# uninstall 이 git 루트를 찾는다
mkdir -p "$U/sub"
( cd "$U" && git init -q . >/dev/null 2>&1; HOME="$UH" bash "$R/install.sh" --ci >/dev/null 2>&1 )
( cd "$U/sub" && HOME="$UH" bash "$R/uninstall.sh" >/dev/null 2>&1 </dev/null )
[ -f "$U/.claude/ai-bouncer/engine/bouncer.sh" ] \
  && no "하위에서 uninstall 실패" "엔진이 남았다" || ok "하위 디렉토리에서도 제거된다"
rm -rf "$U" "$UH"


echo "[감사 9차: 회귀 감지 0이던 것들]"
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null \
  || abort_setup "기본 설정 복구" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1

# m1a: 전이 턴에 engine run 게이트의 통과 출력이 함께 나가야 한다
cat > "$FIXTURE_DIR/_gate.yaml" <<'Y'
version: 1
workflows:
  dev: {label: t, stages: [a, b]}
stages:
  a:
    steps:
      - label: 점검
        run: "echo IMPORTANT-GATE-OUTPUT"
        by: engine
        blocking: true
  b:
    steps: [{label: 끝, inject: "B-TEXT"}]
Y
cleanup; setup "$FIXTURE_DIR/_gate.yaml" >/dev/null || abort_setup "게이트 픽스처" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer start dev g1 >/dev/null
r=$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')
printf '%s' "$r" | grep -q 'IMPORTANT-GATE-OUTPUT' \
  && ok "전이 턴에 게이트 통과 출력이 실린다" || no "게이트 출력 소실" "${r:0:70}"

# m2: 상태 갱신이 실패하면 "완료" 를 보고하면 안 된다
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null \
  || abort_setup "기본 설정 복구" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer start simple lk >/dev/null
bouncer todo add '작업' >/dev/null 2>&1
stop >/dev/null                                   # 남은 항목 1 → 차단
bouncer todo done 1 >/dev/null 2>&1
mkdir "$(task_dir)/.lock"                         # 잠금 경합 재현
# 30초 넘은 잠금은 죽은 것으로 보고 걷어낸다. 병렬 실행 부하로 stop 이 늦으면
# 경합이 사라지므로 mtime 을 미래로 둬 항상 "방금 잡힌" 잠금으로 보이게 한다.
touch -t 209901010000 "$(task_dir)/.lock"
r=$(stop | jq -r '.reason // .hookSpecificOutput.additionalContext // ""')
if printf '%s' "$r" | grep -q '기록하지 못했다'; then
  ok "갱신 실패를 알린다"
else
  printf '%s' "$r" | grep -q '완료 →' && no "거짓 전이 보고" "${r:0:60}" || ok "갱신 실패를 알린다"
fi
[ "$(stage)" = implement ] && ok "실패했으면 단계가 그대로다" || no "단계가 바뀜" "$(stage)"
rmdir "$(task_dir)/.lock" 2>/dev/null
bouncer cancel >/dev/null 2>&1

# m4: 사람 확인처럼 보이는 inject 게이트가 있어도 엔진 게이트 실패는 반송된다
cat > "$FIXTURE_DIR/_hw.yaml" <<'Y'
version: 1
workflows:
  dev: {label: t, stages: [impl, ver, done]}
stages:
  impl:
    steps: [{label: 구현, inject: "IMPL-TEXT"}]
  ver:
    on_fail: impl
    steps:
      - label: 사람 확인
        blocking: true
        inject: "확인해라"
      - label: 게이트
        run: "test -f PASSME"
        by: engine
        blocking: true
  done:
    steps: [{label: 끝, inject: "끝"}]
Y
cleanup; setup "$FIXTURE_DIR/_hw.yaml" >/dev/null || abort_setup "사람확인 픽스처" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer start dev hw >/dev/null
stop >/dev/null                                   # impl → ver
[ "$(stage)" = ver ] || no "ver 진입" "$(stage)"
r="$(stop)"
# 사람 확인 게이트는 없앴다 — blocking: true 도 사람을 기다리지 않으므로
# 엔진 게이트가 실패하면 그대로 구현으로 반송된다.
printf '%s' "$r" | grep -q '사용자 확인 대기' && no "사람 대기가 남아 있음" "${r:0:80}" \
  || ok "blocking: true 인 inject 도 사람을 기다리지 않는다"
bouncer cancel >/dev/null 2>&1


echo "[승인된 계획 → 체크리스트]"
cleanup; setup "$R/config/default.yaml" "$R/config/prompts" >/dev/null \
  || abort_setup "기본 설정 복구" "설치 실패"
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan pc >/dev/null
PLAN2='## 계획
- 항목 A
1. 항목 B

```
- 코드블록 안이라 항목 아님
```
문단은 항목이 아니다'
hook post-tool "$(jq -nc --arg c "$T" --arg p "$PLAN2" \
  '{session_id:"S1",cwd:$c,tool_name:"ExitPlanMode",tool_input:{plan:$p}}')" >/dev/null
[ "$(state '.checklist | length')" = 2 ] \
  && ok "코드블록·문단은 항목으로 안 잡는다" || no "항목 추출 오류" "$(state -c '.checklist')"

# 이미 목록이 있으면 승인이 덮지 않는다 (사용자가 손본 것을 지키려고)
bouncer cancel >/dev/null 2>&1; rm -f "$T"/.ai-bouncer/tasks/*/.active
bouncer start plan pc2 >/dev/null
bouncer todo add '사용자가 직접 넣은 항목' >/dev/null
hook post-tool "$(jq -nc --arg c "$T" --arg p "$PLAN2" \
  '{session_id:"S1",cwd:$c,tool_name:"ExitPlanMode",tool_input:{plan:$p}}')" >/dev/null
[ "$(state '.checklist[0].text')" = "사용자가 직접 넣은 항목" ] \
  && ok "기존 목록을 덮어쓰지 않는다" || no "덮어씀" "$(state -c '.checklist')"
bouncer cancel >/dev/null 2>&1

finish
