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

# 남의 hook이 이미 있는 상태를 만든다 — 제거 때 살아남아야 한다
mkdir -p .claude
cat > .claude/settings.json <<'J'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/other/tool.sh" } ] } ] } }
J

echo "── 설치 ──"
bash "$R/install.sh" --ci --branch dev >/dev/null 2>&1 || { no "설치 실행"; exit 1; }
ok "설치 실행"
for f in engine/bouncer.sh hooks/stop.sh hooks/pre-tool.sh workflow.yaml workflow.compiled.json config.json manifest.json installed.json; do
  [ -f ".claude/ai-bouncer/$f" ] || no "파일 배치" "$f 없음"
done
ok "파일 배치"
[ -f .claude/skills/dev-bounce/SKILL.md ] && ok "스킬 설치" || no "스킬 설치"
grep -qxF '.ai-bouncer/' .gitignore && ok ".gitignore에 런타임 상태 추가" || no ".gitignore"
[ "$(jq -r '.update_branch' .claude/ai-bouncer/config.json)" = dev ] && ok "--branch dev 반영" || no "--branch"
n=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 5 ] && ok "hook 5개 등록" || no "hook 등록" "$n개"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1' .claude/settings.json >/dev/null \
  && ok "남의 hook 보존" || no "남의 hook 보존"

echo "── 재설치(멱등성) ──"
echo '{"max_continue": 99}' > /tmp/_c.json
jq -s '.[0] * .[1]' .claude/ai-bouncer/config.json /tmp/_c.json > /tmp/_m.json && mv /tmp/_m.json .claude/ai-bouncer/config.json
printf '# 사용자 수정\n' >> .claude/ai-bouncer/workflow.yaml
bash "$R/install.sh" --ci >/dev/null 2>&1
n=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 5 ] && ok "hook 중복 안 생김" || no "hook 중복" "$n개"
[ "$(jq -r '.max_continue' .claude/ai-bouncer/config.json)" = 99 ] && ok "사용자 config 보존" || no "config 보존"
grep -q '사용자 수정' .claude/ai-bouncer/workflow.yaml && ok "workflow.yaml 보존" || no "workflow.yaml 보존"

echo "── 설치본으로 실제 동작 ──"
export CLAUDE_CODE_SESSION_ID=S1
bash .claude/ai-bouncer/engine/bouncer.sh start plan test >/dev/null 2>&1
[ "$(jq -r .current_stage .ai-bouncer/tasks/*/state.json)" = plan ] && ok "작업 시작" || no "작업 시작"
r=$(printf '{"session_id":"S1","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/app.js"}}' "$T" "$T" \
    | bash .claude/ai-bouncer/hooks/pre-tool.sh)
[ -n "$r" ] && ok "설치본 hook이 차단" || no "설치본 hook 차단"

echo "── 제거 ──"
bash "$R/uninstall.sh" --local >/dev/null 2>&1 || no "제거 실행"
n=$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' .claude/settings.json)
[ "$n" = 0 ] && ok "hook 전부 해제" || no "hook 해제" "$n개 남음"
jq -e '[.hooks.Stop[].hooks[] | select(.command == "/other/tool.sh")] | length == 1' .claude/settings.json >/dev/null \
  && ok "남의 hook 여전히 보존" || no "남의 hook 보존"
[ -f .claude/ai-bouncer/hooks/stop.sh ] && no "hook 파일 제거" || ok "hook 파일 제거"
[ -f .claude/ai-bouncer/workflow.yaml ] && ok "사용자 workflow.yaml 유지" || no "workflow.yaml 유지"
[ -d .ai-bouncer ] && ok "진행 중 작업 유지" || no "작업 유지"

echo "── --purge ──"
bash "$R/install.sh" --ci >/dev/null 2>&1
bash "$R/uninstall.sh" --local --purge >/dev/null 2>&1
[ -d .claude/ai-bouncer ] && no "purge" "디렉토리 남음" || ok "purge로 전부 삭제"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
