#!/usr/bin/env bash
# 설치 → 동작 → 제거 e2e (엔진·훅은 전역, 레포엔 설정만)
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 실제 홈을 건드리지 않는다 (install 이 $HOME/.claude 와 $HOME/.local/bin 에 쓴다)
unset CLAUDE_CONFIG_DIR XDG_STATE_HOME
if [ -z "${BOUNCER_TEST_HOME:-}" ]; then
  BOUNCER_TEST_HOME="$(mktemp -d)"; export BOUNCER_TEST_HOME HOME="$BOUNCER_TEST_HOME"
fi
G="$HOME/.claude/ai-bouncer"; GS="$HOME/.claude/settings.json"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
nhooks(){ jq '[.hooks // {} | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' "$1" 2>/dev/null || echo 0; }

cd "$T"; git init -q .; git config user.email t@t; git config user.name t
echo hi > app.js; git add app.js; git commit -qm init
printf '# 내 프로젝트\n\n기존 내용은 보존돼야 한다.\n' > CLAUDE.md

# 옛 로컬 설치본 재현 — 레포 안 엔진·훅, 프로젝트 settings 훅, 로컬 스킬, 아주 옛 잔재
mkdir -p .claude/ai-bouncer/hooks .claude/ai-bouncer/engine .claude/skills/dev-bounce
printf '# --- ai-bouncer-rule start ---\n구 규칙\n# --- ai-bouncer-rule end ---\n' > .claude/CLAUDE.md
printf '{}\n' > .claude/ai-bouncer/hooks/hooks.json
printf 'echo old\n' > .claude/ai-bouncer/hooks/stop.sh
printf 'echo old\n' > .claude/ai-bouncer/engine/bouncer.sh
printf '{"files":[],"gitignore_added":true}\n' > .claude/ai-bouncer/manifest.json
printf 'old\n' > .claude/skills/dev-bounce/SKILL.md
printf 'version: 1\n' > .claude/ai-bouncer/workflow.yaml
cat > .claude/settings.json <<'J'
{ "env": {"MY": "1"}, "hooks": {
  "Stop": [
    { "hooks": [ { "type": "command", "command": "/other/tool.sh" } ] },
    { "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/ai-bouncer/hooks/stop.sh" } ] }
  ],
  "SubagentStart": [ { "hooks": [ { "type": "command", "command": "/old/.claude/ai-bouncer/hooks/subagent-track.sh" } ] } ]
} }
J
git add -A; git commit -qm legacy

# 전역 settings 에 남의 hook + 아주 옛 전역 ai-bouncer hook
mkdir -p "$HOME/.claude"
cat > "$GS" <<'J'
{ "hooks": {
  "Stop": [
    { "hooks": [ { "type": "command", "command": "/other/global.sh" } ] },
    { "hooks": [ { "type": "command", "command": "/x/.claude/ai-bouncer/hooks/completion-gate.sh" } ] }
  ] } }
J

echo "── 설치 ──"
bash "$R/install.sh" --ci --branch dev >/dev/null 2>&1 || { no "설치 실행"; exit 1; }
ok "설치 실행"
BAD=0
for f in engine/bouncer.sh engine/init.sh engine/default.yaml hooks/stop.sh hooks/pre-tool.sh installed.json; do
  [ -f "$G/$f" ] || { BAD=1; printf '     ↳ %s 없음\n' "$f"; }
done
[ "$BAD" = 0 ] && ok "전역 엔진 배치" || no "전역 엔진 배치" "위 파일이 없다"
miss=""; for f in $(cd "$R" && find engine hooks -type f \( -name '*.sh' -o -name '*.py' \) -not -path '*__pycache__*'); do
  [ -f "$G/$f" ] || miss="$miss $f"
done
[ -z "$miss" ] && ok "엔진·훅 소스 파일이 빠짐없이 설치된다" || no "설치 누락" "$miss"
[ -f "$HOME/.claude/skills/dev-bounce/SKILL.md" ] && ok "전역 스킬 설치" || no "전역 스킬 설치"
[ "$(jq -r .branch "$G/installed.json")" = dev ] && ok "--branch dev 기록" || no "--branch"
[ "$(nhooks "$GS")" = 5 ] && ok "전역 hook 5개 등록" || no "전역 hook 등록" "$(nhooks "$GS")개"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/global.sh")] | length == 1' "$GS" >/dev/null \
  && ok "전역 settings 남의 hook 보존" || no "전역 남의 hook"
DANGLING=0
while IFS= read -r c; do case "$c" in *ai-bouncer*) [ -f "$c" ] || DANGLING=$((DANGLING+1)) ;; esac
done < <(jq -r '.hooks//{}|to_entries[]|.value[]|.hooks[]|.command' "$GS")
[ "$DANGLING" = 0 ] && ok "전역 hook 은 실제 파일을 가리킨다 (옛 전역 hook 제거)" || no "dangling hook" "${DANGLING}개"
grep -q "$G/engine/bouncer.sh" "$HOME/.local/bin/bouncer" && ok "bouncer 실행 파일이 전역 엔진을 부른다" || no "셔임"

echo "── 이 레포 켜기 (옛 로컬 설치본 정리) ──"
A=.claude/ai-bouncer
[ -f $A/workflow.compiled.json ] && ok "컴파일본 생성" || no "컴파일본 없음"
[ -e $A/engine ] && no "로컬 엔진 정리" "남음" || ok "옛 로컬 엔진 제거"
[ -e $A/manifest.json ] && no "manifest 정리" "남음" || ok "옛 manifest 제거"
[ -e .claude/skills/dev-bounce ] && no "로컬 스킬 정리" "남음" || ok "옛 로컬 스킬 제거 (전역 스킬과 겹침)"
[ "$(nhooks .claude/settings.json)" = 0 ] && ok "프로젝트 settings 의 ai-bouncer hook 제거" || no "프로젝트 hook" "$(nhooks .claude/settings.json)개"
jq -e '.env.MY == "1" and ([.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1)' .claude/settings.json >/dev/null \
  && ok "프로젝트 settings 남의 hook·env 보존" || no "프로젝트 남의 설정"
grep -q 'BOUNCER_FORWARDED=1' $A/hooks/stop.sh && grep -q "$G/hooks/stop.sh" $A/hooks/stop.sh \
  && ok "열려 있는 세션용: 옛 hook 자리는 전역 hook 으로 넘긴다" || no "포워더" "$(head -3 $A/hooks/stop.sh 2>&1)"
[ -z "$(git ls-files $A/hooks)" ] && ok "포워더는 커밋 대상이 아니다" || no "포워더 추적됨" "$(git ls-files $A/hooks)"
grep -qxF 'hooks/' $A/.gitignore && ok "설정 디렉토리 .gitignore 에 hooks/" || no "hooks/ 무시 누락"
grep -qxF '.ai-bouncer/' .gitignore && ok ".gitignore에 런타임 상태 추가" || no ".gitignore"
[ "$(jq -r .gitignore_added $A/init.json)" = true ] && ok "우리가 넣은 .gitignore 줄 기록" || no "gitignore_added"
grep -q 'ai-bouncer:start' CLAUDE.md && ok "CLAUDE.md에 블록 추가" || no "블록 추가"
grep -q '기존 내용' CLAUDE.md && ok "기존 내용 보존" || no "기존 내용 보존"
[ -f .claude/CLAUDE.md ] && no "구 .claude/CLAUDE.md 정리" "남음" || ok "구 .claude/CLAUDE.md 정리"
grep -qx "$(pwd -P)" "$HOME/.local/state/ai-bouncer/installs" \
  && ok "켠 레포 목록에 기록" || no "목록 기록"
git add -A; git commit -qm migrated
[ -z "$(git status --porcelain)" ] && ok "커밋 후 워킹트리 깨끗 (런타임 파일 무시)" || no "더러움" "$(git status --porcelain | head -3)"

echo "── 이중 실행 방지 ──"
# 전역 설치 뒤, init 전에 시작한 세션은 프로젝트 hook 과 전역 hook 을 둘 다 부른다 — 전역은 빠진다.
D="$(mktemp -d)"; ( cd "$D" && git init -q . && mkdir -p .claude/ai-bouncer/hooks && printf 'version: 1\n' > .claude/ai-bouncer/workflow.yaml \
  && printf 'exit 0\n' > .claude/ai-bouncer/hooks/stop.sh \
  && printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/ai-bouncer/hooks/stop.sh"}]}]}}' > .claude/settings.json )
. "$G/engine/lib/common.sh"
bouncer_defer_to_local "$D" "$G/hooks/stop.sh" && ok "옛 로컬 hook 이 등록돼 있으면 전역 hook 은 맡긴다" || no "이중 실행"
BOUNCER_FORWARDED=1 bouncer_defer_to_local "$D" "$G/hooks/stop.sh" && no "포워딩된 호출까지 빠짐" || ok "로컬이 넘겨준 호출은 처리한다"
rm "$D/.claude/settings.json"
bouncer_defer_to_local "$D" "$G/hooks/stop.sh" && no "등록 없는데 빠짐" || ok "등록이 없으면 전역 hook 이 처리한다"
rm -rf "$D"

echo "── 재설치(멱등성) ──"
python3 "$R/tests/set-settings.py" $A/workflow.yaml max_continue=99
printf '# 사용자 수정\n' >> $A/workflow.yaml
bash "$R/install.sh" --ci >/dev/null 2>&1
[ "$(nhooks "$GS")" = 5 ] && ok "hook 중복 안 생김" || no "hook 중복" "$(nhooks "$GS")개"
[ -z "$(find "$G" $A -name '__pycache__' -o -name '*.pyc' | head -1)" ] \
  && ok "바이트코드를 남기지 않는다" || no "바이트코드 잔존" "$(find "$G" $A -name '*.pyc' | head -2)"
[ "$(jq -r '.settings.max_continue' $A/workflow.compiled.json)" = 99 ] && ok "사용자 설정 보존" || no "설정 보존"
grep -q '사용자 수정' $A/workflow.yaml && ok "workflow.yaml 보존" || no "workflow.yaml 보존"
[ "$(grep -c 'ai-bouncer:start' CLAUDE.md)" = 1 ] && ok "CLAUDE.md 블록 중복 안 생김" || no "블록 중복"
[ -z "$(ls -d "$HOME/.claude/ai-bouncer".* 2>/dev/null)" ] && ok "교체용 임시 디렉토리를 남기지 않는다" || no "임시 디렉토리" "$(ls -d "$HOME/.claude/ai-bouncer".*)"

echo "── 전역 설치본으로 실제 동작 ──"
export CLAUDE_CODE_SESSION_ID=S1
"$HOME/.local/bin/bouncer" start plan test >/dev/null 2>&1
[ "$(jq -r .current_stage .ai-bouncer/tasks/*/state.json)" = plan ] && ok "작업 시작" || no "작업 시작"
r=$(printf '{"session_id":"S1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$T" \
    | bash "$G/hooks/pre-tool.sh")
[ -n "$r" ] && ok "전역 hook 이 차단" || no "전역 hook 차단"
r=$(printf '{"session_id":"S1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s/engine/bouncer.sh status"}}' "$T" "$G" \
    | bash "$G/hooks/pre-tool.sh")
[ -z "$r" ] && ok "전역 엔진 경로로 부르는 bouncer 는 통과" || no "전역 엔진 호출 차단" "${r:0:80}"
r=$(printf '{"session_id":"S1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$T" \
    | bash $A/hooks/pre-tool.sh)
[ -n "$r" ] && ok "옛 hook 자리로 불러도 전역 hook 이 차단" || no "포워더 차단"
"$HOME/.local/bin/bouncer" cancel >/dev/null 2>&1

echo "── 설정 없는 레포: 세션 시작 때 켤지 묻는다 ──"
N="$(cd "$(mktemp -d)" && pwd -P)"; ( cd "$N" && git init -q . )
ss(){ printf '{"session_id":"S9","cwd":"%s","source":"%s"}' "$N" "$1" | bash "$G/hooks/session-start.sh"; }
ss startup | grep -q 'bouncer init' && ok "새 세션 시작 때 묻는다" || no "질문 없음"
[ -z "$(ss resume)$(ss compact)$(ss clear)" ] && ok "resume·compact·clear 때는 묻지 않는다" || no "반복 질문"
r=$(printf '{"session_id":"S9","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' "$N" | bash "$G/hooks/pre-tool.sh")
[ -z "$r" ] && ok "설정 없는 레포에선 hook 이 아무것도 안 한다" || no "설정 없는데 차단" "${r:0:80}"
( cd "$N" && "$HOME/.local/bin/bouncer" scan ) | grep -q 'bouncer init' && ok "scan 이 설정 없음을 알린다" || no "scan 안내 없음"
( cd "$N" && "$HOME/.local/bin/bouncer" init --decline >/dev/null 2>&1 )
[ -z "$(ss startup)" ] && ok "거절하면 다시 묻지 않는다" || no "거절 후 또 물음"
[ -e "$N/.claude" ] && no "거절인데 파일 생김" || ok "거절은 레포에 아무것도 만들지 않는다"
( cd "$N" && "$HOME/.local/bin/bouncer" init >/dev/null 2>&1 )
[ -f "$N/.claude/ai-bouncer/workflow.yaml" ] && [ -f "$N/.claude/ai-bouncer/workflow.compiled.json" ] \
  && ok "bouncer init 으로 켠다" || no "init"
grep -qx "$N" "$HOME/.local/state/ai-bouncer/declined" && no "켠 뒤에도 거절 목록에 남음" || ok "켜면 거절 목록에서 뺀다"
printf '{"session_id":"S9","cwd":"%s","source":"startup"}' "$N" | bash "$G/hooks/session-start.sh" | grep -q '/dev-bounce' \
  && ok "켠 레포에선 평소 안내" || no "켠 뒤 안내"
rm -rf "$N"

echo "── 제거 ──"
bash "$R/uninstall.sh" >/dev/null 2>&1 || no "제거 실행"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1' .claude/settings.json >/dev/null \
  && ok "남의 hook 여전히 보존" || no "남의 hook 보존"
[ -e $A/hooks ] && no "포워더 제거" "남음" || ok "포워더 제거"
[ -f $A/workflow.yaml ] && ok "사용자 workflow.yaml 유지" || no "workflow.yaml 유지"
[ -d .ai-bouncer ] && ok "진행 중 작업 유지" || no "작업 유지"
grep -q 'ai-bouncer:start' CLAUDE.md && no "CLAUDE.md 블록 제거" "남음" || ok "CLAUDE.md 블록 제거"
grep -q '기존 내용' CLAUDE.md && ok "CLAUDE.md 나머지 보존" || no "나머지 보존"
[ -f "$G/engine/bouncer.sh" ] && ok "레포 제거는 전역 엔진을 건드리지 않는다" || no "전역 엔진 사라짐"

echo "── --no-claude-md ──"
rm -f CLAUDE.md
bash "$R/install.sh" --ci --no-claude-md >/dev/null 2>&1
[ -f CLAUDE.md ] && no "--no-claude-md" "파일 생성됨" || ok "--no-claude-md면 안 건드림"

echo "── --purge ──"
bash "$R/uninstall.sh" --purge >/dev/null 2>&1
[ -d .claude/ai-bouncer ] && no "purge" "디렉토리 남음" || ok "purge로 전부 삭제"

echo "── --global ──"
bash "$R/uninstall.sh" --global >/dev/null 2>&1
[ -e "$G" ] || [ -e "$HOME/.claude/skills/dev-bounce" ] || [ -e "$HOME/.local/bin/bouncer" ] \
  && no "전역 제거" "남음" || ok "전역 엔진·스킬·실행 파일 제거"
[ "$(nhooks "$GS")" = 0 ] && ok "전역 hook 해제" || no "전역 hook 남음" "$(nhooks "$GS")"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/global.sh")] | length == 1' "$GS" >/dev/null \
  && ok "전역 남의 hook 보존" || no "전역 남의 hook"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
