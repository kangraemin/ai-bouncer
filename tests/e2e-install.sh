#!/usr/bin/env bash
# 설치 → 동작 → 제거 e2e
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

cd "$T"; git init -q .; git config user.email t@t; git config user.name t
echo hi > app.js; git add app.js; git commit -qm init
printf '# 내 프로젝트\n\n기존 내용은 보존돼야 한다.\n' > CLAUDE.md

# 남의 hook + 구버전 ai-bouncer hook이 이미 있는 상태를 만든다.
# 남의 hook은 살아남아야 하고, 구 hook은 (신규가 안 쓰는 이벤트에 있어도) 전부 사라져야 한다.
mkdir -p .claude
cat > .claude/settings.json <<'J'
{ "hooks": {
  "Stop": [
    { "hooks": [ { "type": "command", "command": "/other/tool.sh" } ] },
    { "hooks": [ { "type": "command", "command": "/old/.claude/ai-bouncer/hooks/completion-gate.sh" } ] }
  ],
  "SubagentStart": [ { "hooks": [ { "type": "command", "command": "/old/.claude/ai-bouncer/hooks/subagent-track.sh" } ] } ],
  "SubagentStop":  [ { "hooks": [ { "type": "command", "command": "/old/.claude/ai-bouncer/hooks/subagent-cleanup.sh" } ] } ]
} }
J

echo "── 설치 ──"
bash "$R/install.sh" --ci --branch dev >/dev/null 2>&1 || { no "설치 실행"; exit 1; }
ok "설치 실행"
for f in engine/bouncer.sh hooks/stop.sh hooks/pre-tool.sh workflow.yaml workflow.compiled.json manifest.json installed.json; do
  [ -f ".claude/ai-bouncer/$f" ] || no "파일 배치" "$f 없음"
done
ok "파일 배치"
[ -f .claude/skills/dev-bounce/SKILL.md ] && ok "스킬 설치" || no "스킬 설치"
grep -qxF '.ai-bouncer/' .gitignore && ok ".gitignore에 런타임 상태 추가" || no ".gitignore"
[ "$(jq -r '.settings.update_branch' .claude/ai-bouncer/workflow.compiled.json)" = dev ] && ok "--branch dev 반영" || no "--branch"
[ -f .claude/ai-bouncer/config.json ] && no "별도 config 파일 없음" "생성됨" || ok "별도 config 파일 없음 (설정은 yaml에)"
n=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 5 ] && ok "hook 5개 등록" || no "hook 등록" "${n}개"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1' .claude/settings.json >/dev/null \
  && ok "남의 hook 보존" || no "남의 hook 보존"

# 구버전은 신규가 쓰지 않는 이벤트(SubagentStart/Stop)에도 hook을 등록했다.
# 그 등록이 남으면 이미 지워진 스크립트를 계속 호출하게 된다.
jq -e '(.hooks.SubagentStart // []) == [] and (.hooks.SubagentStop // []) == []' .claude/settings.json >/dev/null \
  && ok "신규가 안 쓰는 이벤트의 구 hook도 제거" || no "구 hook 잔재" "SubagentStart/Stop 남음"
DANGLING=0
while IFS= read -r c; do
  case "$c" in *ai-bouncer*)
    r="${c//\$\{CLAUDE_PROJECT_DIR\}/$T}"     # placeholder를 실제 경로로 풀어서 확인
    [ -f "$r" ] || DANGLING=$((DANGLING+1)) ;;
  esac
done < <(jq -r '.hooks//{}|to_entries[]|.value[]|.hooks[]|.command' .claude/settings.json)
[ "$DANGLING" = 0 ] && ok "없는 파일을 가리키는 등록 없음" || no "dangling hook" "${DANGLING}개"

echo "── CLAUDE.md 규칙 블록 ──"
grep -q 'ai-bouncer:start' CLAUDE.md 2>/dev/null && ok "CLAUDE.md에 블록 추가" || no "블록 추가"
grep -q '기존 내용' CLAUDE.md && ok "기존 내용 보존" || no "기존 내용 보존"

echo "── 재설치(멱등성) ──"
python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=99
printf '# 사용자 수정\n' >> .claude/ai-bouncer/workflow.yaml
bash "$R/install.sh" --ci >/dev/null 2>&1
n=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 5 ] && ok "hook 중복 안 생김" || no "hook 중복" "$n개"
python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml .claude/ai-bouncer/workflow.compiled.json >/dev/null 2>&1
[ "$(jq -r '.settings.max_continue' .claude/ai-bouncer/workflow.compiled.json)" = 99 ] && ok "사용자 설정 보존" || no "설정 보존"
grep -q '사용자 수정' .claude/ai-bouncer/workflow.yaml && ok "workflow.yaml 보존" || no "workflow.yaml 보존"
[ "$(grep -c 'ai-bouncer:start' CLAUDE.md)" = 1 ] && ok "CLAUDE.md 블록 중복 안 생김" || no "블록 중복"

echo "── 설치본으로 실제 동작 ──"
export CLAUDE_CODE_SESSION_ID=S1
bash .claude/ai-bouncer/engine/bouncer.sh start plan test >/dev/null 2>&1
[ "$(jq -r .current_stage .ai-bouncer/tasks/*/state.json)" = plan ] && ok "작업 시작" || no "작업 시작"
r=$(printf '{"session_id":"S1","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/app.js"}}' "$T" "$T" \
    | bash .claude/ai-bouncer/hooks/pre-tool.sh)
[ -n "$r" ] && ok "설치본 hook이 차단" || no "설치본 hook 차단"
grep -q 'CLAUDE_PROJECT_DIR' .claude/settings.json && ok "hook 경로가 이식 가능 (절대경로 아님)" || no "이식성" "절대경로 박힘"

echo "── 제거 ──"
bash "$R/uninstall.sh" >/dev/null 2>&1 || no "제거 실행"
n=$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 0 ] && ok "hook 전부 해제" || no "hook 해제" "$n개 남음"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1' .claude/settings.json >/dev/null \
  && ok "남의 hook 여전히 보존" || no "남의 hook 보존"
[ -f .claude/ai-bouncer/hooks/stop.sh ] && no "hook 파일 제거" || ok "hook 파일 제거"
[ -f .claude/ai-bouncer/workflow.yaml ] && ok "사용자 workflow.yaml 유지" || no "workflow.yaml 유지"
[ -d .ai-bouncer ] && ok "진행 중 작업 유지" || no "작업 유지"
grep -q 'ai-bouncer:start' CLAUDE.md && no "CLAUDE.md 블록 제거" "남음" || ok "CLAUDE.md 블록 제거"
grep -q '기존 내용' CLAUDE.md && ok "CLAUDE.md 나머지 보존" || no "나머지 보존"

echo "── --no-claude-md ──"
rm -f CLAUDE.md
bash "$R/install.sh" --ci --no-claude-md >/dev/null 2>&1
[ -f CLAUDE.md ] && no "--no-claude-md" "파일 생성됨" || ok "--no-claude-md면 안 건드림"
bash "$R/uninstall.sh" >/dev/null 2>&1

echo "── --purge ──"
bash "$R/install.sh" --ci >/dev/null 2>&1
bash "$R/uninstall.sh" --purge >/dev/null 2>&1
[ -d .claude/ai-bouncer ] && no "purge" "디렉토리 남음" || ok "purge로 전부 삭제"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
