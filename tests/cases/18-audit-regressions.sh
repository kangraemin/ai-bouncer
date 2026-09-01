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
        "$T/.claude/ai-bouncer/workflow.compiled.json" >/dev/null || { no "e2e step 추가"; echo
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
says '아직 0/' bouncer skip "verify/e2e" && ok "포기 전에는 skip 거부" || no "skip 거부" "$(bouncer skip 'verify/e2e' 2>&1|head -1)"

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

finish
