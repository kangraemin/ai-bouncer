#!/usr/bin/env bash
# 케이스 17 — PreToolUse 판정기가 남긴 세 가지 차단의 우회 시도.
#
#   1. Edit/Write/MultiEdit/NotebookEdit 로 엔진 파일(상태·.claude/ai-bouncer·compiled.json·settings.json) 수정
#   2. 병렬 worktree 작업 중 worktree 밖(메인 레포) 쓰기
#   3. forbid.push 단계의 `git push` (다른 레포 push·--dry-run 은 오탐이므로 통과해야 한다)
#
# 여기 있는 명령들은 독립 감사에서 실제로 뚫렸던 것이다. 정규식 블랙리스트로는 못 막아서
# 명령을 토큰화해 세그먼트 단위로 판정한다. 새 우회를 발견하면 해당 목록에 한 줄 추가한다.
# 지운 것(읽기 전용 단계·forbid.edit_files·forbid.bash·셸의 엔진 파일 해석)은 더 검사하지 않는다.
#
# 통과하면 범주당 한 줄만 출력한다. 실패한 항목만 개별로 나온다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# install.sh 에 기대지 않는다 — lib.sh 의 setup 으로 최소 설치를 만들고 hook 은 $R 에서 직접 부른다.
FIXTURE="$(mktemp -d)"
cat > "$FIXTURE/push.yaml" <<'Y'
version: 1
workflows:
  impl:
    label: 테스트용
    stages: [implement, done]
stages:
  implement:
    steps:
      - label: 구현
        inject: "구현해라."
    forbid:
      push: true
      reason: 검증 전에는 push할 수 없다.
  done:
    steps:
      - label: 완료
        inject: "끝."
Y
setup "$FIXTURE/push.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE"' EXIT
echo y > b.js; mkdir -p src docs; echo s > src/a.js; echo d > docs/p.md
git add -A; git commit -qm files
export CLAUDE_CODE_SESSION_ID=S1

B(){ printf '{"session_id":"S1","cwd":"%s","tool_name":"Bash","tool_input":{"command":%s}}' \
     "$T" "$(printf '%s' "$1" | jq -Rs .)" | bash "$R/hooks/pre-tool.sh"; }
must_block(){ [ -n "$(B "$1")" ]; }
must_pass(){  [ -z "$(B "$1")" ]; }
# Edit 계열 도구: 항목은 "도구 경로"
E(){ printf '{"session_id":"S1","cwd":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' \
     "$T" "${1%% *}" "${1#* }" | bash "$R/hooks/pre-tool.sh"; }
e_block(){ [ -n "$(E "$1")" ]; }
e_pass(){  [ -z "$(E "$1")" ]; }

# worktree 예외를 심볼릭 링크로 타는 시도를 재현하려면 실제 링크가 있어야 한다
mkdir -p .ai-bouncer/worktrees/w/.claude/ai-bouncer .ai-bouncer/tasks
ln -sf ../tasks .ai-bouncer/worktrees/esc

bouncer start impl probe >/dev/null 2>&1          # implement = push 금지 단계
[ "$(stage)" = implement ] || abort_setup "작업 시작" "stage=$(stage)"

printf '\n[엔진 파일 Edit/Write 차단]\n'
# 루프 안에서 실패를 알린 뒤 무조건 ok 를 찍으면 실패가 "통과 1건"으로 집계된다.
# group 헬퍼가 항목마다 판정을 모은다.
group "Edit/Write/MultiEdit/NotebookEdit 로 엔진 파일 수정" e_block <<CASES
Edit $T/.ai-bouncer/tasks/x/state.json
Write $T/.ai-bouncer/tasks/x/state.json
MultiEdit $T/.ai-bouncer/tasks/x/state.json
NotebookEdit $T/.ai-bouncer/tasks/x/state.json
Write $T/.ai-bouncer/tasks/x/.active
Edit $T/.claude/ai-bouncer/workflow.yaml
Write $T/.claude/ai-bouncer/workflow.compiled.json
Edit $T/.claude/settings.json
Write $T/.claude/ai-bouncer/hooks/pre-tool.sh
CASES

group "경로 정규화·심볼릭 링크 우회" e_block <<CASES
Write $T/.claude//ai-bouncer/state.json
Write $T/.claude/./ai-bouncer/workflow.yaml
Write $T/docs/../.claude/ai-bouncer/workflow.yaml
Edit $T/.ai-bouncer/worktrees/../tasks/x/state.json
Write $T/.ai-bouncer/worktrees/esc/state.json
Write $T/.ai-bouncer/worktrees/w/.claude/ai-bouncer/workflow.yaml
CASES

group "엔진 파일이 아닌 Edit 는 통과" e_pass <<CASES
Edit $T/app.js
Write $T/src/new.js
Write $T/docs/plan.md
MultiEdit $T/b.js
Edit $T/.claude/ai-bouncer-notes/x.md
CASES

printf '\n[push 금지 단계 — push 만 막는다]\n'
# 개행도 명령 구분자다. 예전엔 세그먼트 분리에서 빠져 `ls` 하나만 판정되고
# 뒤에 붙은 것은 통째로 통과했다.
NL_BAD=0
for c in "echo hi
git push origin main" "ls
git push" "true
git push --force"; do
  [ -n "$(B "$c")" ] || { NL_BAD=1; printf '     ↳ %s\n' "$(printf '%s' "$c" | tr '\n' '⏎')"; }
done
[ "$NL_BAD" = 0 ] && ok "개행으로 push 잇기 (3건)" || no "개행으로 push 잇기" "위 항목 통과됨"

# `<<` 는 히어독만이 아니다. 산술 좌시프트·히어스트링을 히어독으로 오인하면
# 종료어를 못 찾아 **명령 끝까지** 본문으로 삼키고, 뒤 줄의 push 가 검사에서 사라진다.
SH_BAD=0
for c in "echo \$((1<<2))
git push" "echo \$[1<<4]
git push" "v=\$((1<<2))
git push" "let y=1<<3
git push" "grep x <<<word
git push"; do
  [ -n "$(B "$c")" ] || { SH_BAD=1; printf '     ↳ %s\n' "$(printf '%s' "$c" | tr '\n' '⏎')"; }
done
[ "$SH_BAD" = 0 ] && ok "시프트·히어스트링으로 뒤 줄 push 숨기기 (5건)" \
                  || no "시프트·히어스트링으로 뒤 줄 push 숨기기" "위 항목 통과됨"

# 종료어가 인용돼 있지 않으면 bash 는 히어독 **본문**에서 치환을 실행한다.
HB="cat <<EOF
\$(git push origin main)
EOF"
[ -n "$(B "$HB")" ] && ok "히어독 본문의 push 치환" || no "히어독 본문 치환" "통과됨"
HQ="cat <<'EOF'
\$(git push origin main)
EOF"
[ -z "$(B "$HQ")" ] && ok "인용된 종료어의 본문은 통과" || no "인용 히어독 과차단"

# 히어독 종료어는 백슬래시로 인용할 수 있다. bash 는 백슬래시를 지운 것을
# 종료어로 쓰는데, 그걸 모르면 종료어가 어긋나 뒤 명령이 본문으로 삼켜진다.
HD="cat <<\\EOF
cat <<END
EOF
git push
END"
[ -n "$(B "$HD")" ] && ok "히어독 종료어 백슬래시 뒤의 push" || no "히어독 종료어 백슬래시" "통과됨"

group "허용 명령 뒤에 push 붙이기" must_block <<'CASES'
bouncer status; git push
bouncer status && git push origin main
.claude/ai-bouncer/engine/bouncer.sh status; git push
CASES

# 이름·서브커맨드를 변수·치환·별칭으로 숨기는 형태(`git $x`, `git $(echo push)`, alias.*)는 판정하지 않는다.
# 실사용 차단 47건 중 숨긴 push 는 0건이었다(2026-10-22 감사). 평문 `git push` 형태만 본다.
group "push 위장" must_block <<'CASES'
command -p git push origin main
FOO=/tmp git push
GIT_DIR=/tmp/x git push
nice -n 5 git push
timeout 5 git push
sh -c "git push origin main"
env git push
command git push
nohup git push
git send-pack /tmp/r main
git svn dcommit
echo main | xargs git push origin
git push
"git" push
git -C . push
git -c core.x=y push
git   push --all
GIT_DIR=.git git push
git-push origin main
true "$(git push origin main)"
echo $(git push origin main)
echo "`git push`"
cat <(git push)
{ git push; }
( git push )
if true; then git push; fi
git add -A && git commit -m x && git push
CASES

group "push 오탐은 없다 (다른 레포·dry-run·읽기)" must_pass <<'CASES'
git -C /tmp/otherrepo push
git push --dry-run
git push -n origin main
git status
git log --oneline
git diff HEAD
git add -A && git commit -m x
git add .claude/settings.json .claude/ai-bouncer
git commit -m "$(cat msg.txt)"
git commit -m "release $(date +%F)"
git branch --no-push
git config user.name
bouncer status
bouncer done implement/x
npm test
npm run build && npm test
make
node -e "console.log([].push(1))"
python3 -c "print(1)"
grep push a.js
echo "git is not push"
awk '/push/ {print}' a.js
sed -i "" s/a/b/ a.js
rm -rf dist
mkdir -p build
cat .claude/ai-bouncer/workflow.yaml
CASES

printf '\n[병렬 worktree — 밖은 막고 안은 연다]\n'
bouncer cancel >/dev/null 2>&1
bouncer start impl para --parallel >/dev/null 2>&1
WT="$(jq -r '.worktree.path' "$(task_dir)/state.json" 2>/dev/null)"
[ -d "$WT" ] || abort_setup "worktree 생성" "$WT"
echo z > "$WT/in.js"

# 메인 레포를 건드리는 셸 쓰기
group "worktree 작업 중 메인 레포 셸 쓰기" must_block <<CASES
echo x > $T/app.js
echo x >> $T/app.js
tee $T/app.js
rm $T/app.js
rm -rf $T/src
cp b.js $T/app.js
mv $WT/in.js $T/app.js
cd $T && rm app.js
cd $T && echo x > app.js
echo x > $T/docs/../app.js
sed -i "" s/a/b/ $T/app.js
touch $T/new.js
CASES

# worktree 안은 그대로 쓸 수 있어야 한다 (과차단 방지)
group "worktree 안 쓰기와 읽기는 통과" must_pass <<CASES
echo x > $WT/src/new.js
cd $WT && echo x > src/new.js
cd $WT && rm in.js
cat $T/app.js
ls $T
cp $T/app.js $WT/copy.js
git -C $WT commit --allow-empty -m w
npm test
CASES

# Edit 계열도 같다
group "worktree 작업 중 메인 레포 Edit" e_block <<CASES
Edit $T/app.js
Write $T/new.js
MultiEdit $T/src/a.js
Write $T/docs/../app.js
CASES
group "worktree 안 Edit 는 통과" e_pass <<CASES
Edit $WT/in.js
Write $WT/src/new.js
Write /tmp/outside-project.txt
CASES
# worktree 안 엔진 파일은 여전히 막힌다
e_block "Write $WT/.claude/ai-bouncer/workflow.yaml" \
  && ok "worktree 안의 엔진 설정도 Edit 차단" || no "worktree 안 엔진 설정 허용됨"
bouncer cancel >/dev/null 2>&1

finish
