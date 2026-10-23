#!/usr/bin/env bash
# 케이스 07 — 세션 시작: 재컴파일, 켤지 묻기, 단계 설정 없으면 묻기 / bouncer init (--defaults, --decline)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"
ss(){ hook session-start "{\"session_id\":\"${2:-S1}\",\"cwd\":\"$T\",\"source\":\"${1:-startup}\"}"; }

ss | grep -q 'main — 기본' && ok "모드 목록 안내" || no "모드 안내"
python3 - .claude/ai-bouncer/workflow.yaml <<'P'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('  pickc:', '  extra: {label: 추가모드, stages: [a]}\n  pickc:'))
P
ss | grep -q 'extra — 추가모드' && ok "yaml 이 바뀌면 다시 컴파일" || no "재컴파일"
echo '[a] 바뀐 지시' > .claude/ai-bouncer/prompts/a.md; ss >/dev/null
jq -r '.stages.a.prompt' .claude/ai-bouncer/workflow.compiled.json | grep -q '바뀐 지시' && ok "프롬프트 파일만 바꿔도 다시 컴파일" || no "프롬프트 재컴파일"
cp .claude/ai-bouncer/workflow.yaml /tmp/w.$$; echo 'workflows: [' > .claude/ai-bouncer/workflow.yaml
ss | grep -q '컴파일하지 못했다' && jq -e '.workflows.main' .claude/ai-bouncer/workflow.compiled.json >/dev/null \
  && ok "깨진 yaml → 경고하고 이전 설정 유지" || no "깨진 yaml"
cp /tmp/w.$$ .claude/ai-bouncer/workflow.yaml; rm -f /tmp/w.$$

b1 start main s1 --pick b=x >/dev/null
ss compact | grep -q '진행 중인 작업이 있다' && ss compact | grep -q 'a b c' && ok "진행 중 작업과 체인 안내" || no "작업 안내" "$(ss compact)"
b1 cancel >/dev/null

# ── 단계 설정이 없는 yaml → 새 세션에서 기본값 쓸지 묻는다 ──
printf '# 비어 있음\n' > .claude/ai-bouncer/workflow.yaml
ss | grep -q 'init --defaults' && ok "단계 설정 없으면 startup 때 묻는다" || no "단계 설정 질문"
ss resume | grep -q 'init --defaults' && no "resume 때도 물음" || ok "resume 때는 묻지 않는다"
bouncer init --defaults --no-claude-md >/dev/null 2>&1
grep -q '^workflows:' .claude/ai-bouncer/workflow.yaml && grep -q 'choosable: ask' .claude/ai-bouncer/workflow.yaml \
  && ok "init --defaults → 기본값을 써 넣는다" || no "defaults" "$(cat .claude/ai-bouncer/workflow.yaml)"
[ -f .claude/ai-bouncer/prompts/plan.md ] && ok "기본 프롬프트 md 도 복사" || no "prompt 복사"
[ -f .claude/ai-bouncer/workflow.yaml.bak ] && ok "덮기 전 원본 .bak" || no ".bak"
bouncer check >/dev/null && ok "써 넣은 기본값이 유효" || no "기본값 check"
ss | grep -q 'init --defaults' && no "채운 뒤에도 물음" || ok "채운 뒤엔 묻지 않는다"
says "이미 단계 설정이 있다" bouncer init --defaults --no-claude-md && ok "설정 있으면 --defaults 거부" || no "덮어쓰기 거부"

# ── 설정 없는 레포 ──
N="$(mktemp -d)"; git -C "$N" init -q
o="$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$N" | bash "$R/hooks/session-start.sh")"
printf '%s' "$o" | grep -q 'bouncer init' && ok "설정 없는 레포 → 켤지 묻는다" || no "켤지 질문"
(cd "$N" && bash "$R/engine/bouncer.sh" init --decline >/dev/null 2>&1)
o="$(printf '{"session_id":"S1","cwd":"%s","source":"startup"}' "$N" | bash "$R/hooks/session-start.sh")"
[ -z "$o" ] && ok "--decline 뒤엔 묻지 않는다" || no "decline" "$o"
M="$(mktemp -d)"; git -C "$M" init -q
(cd "$M" && bash "$R/engine/bouncer.sh" init --no-claude-md >/dev/null 2>&1)
grep -q '^workflows:' "$M/.claude/ai-bouncer/workflow.yaml" && ok "bouncer init 은 기본값을 채운 설정을 만든다" || no "init 기본값"
(cd "$M" && bash "$R/engine/bouncer.sh" check >/dev/null) && ok "만든 설정이 유효" || no "init check"
rm -rf "$N" "$M"

cleanup; finish
