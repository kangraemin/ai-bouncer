#!/usr/bin/env bash
# 케이스 07 — 세션 시작: 재컴파일, 처음 한 번만 켤지 묻기 / bouncer init (--defaults, --setup, --decline) / bouncer setup
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
ss compact | grep -q '진행 중인 작업이 있다' && ! ss compact | grep -q '체인' && ok "진행 중 작업 안내 (단계 순서는 숨김)" || no "작업 안내" "$(ss compact)"
b1 cancel >/dev/null

# ── 단계 설정이 없는 yaml → 묻지 않고 엔진 기본값으로 돈다 ──
printf '# 비어 있음\n' > .claude/ai-bouncer/workflow.yaml
o="$(ss)"; printf '%s' "$o" | grep -q 'plan — ' && ok "단계 설정 없으면 기본값으로 돈다" || no "기본값" "$o"
printf '%s' "$o" | grep -q 'init --defaults\|bouncer setup' && no "켠 뒤에 다시 물음" "$o" || ok "켠 뒤엔 다시 묻지 않는다"
bouncer init --defaults --no-claude-md >/dev/null 2>&1
grep -q '^workflows:' .claude/ai-bouncer/workflow.yaml && grep -q 'choosable: ask' .claude/ai-bouncer/workflow.yaml \
  && ok "init --defaults → 기본값을 써 넣는다" || no "defaults" "$(cat .claude/ai-bouncer/workflow.yaml)"
[ -f .claude/ai-bouncer/prompts/plan.md ] && ok "기본 프롬프트 md 도 복사" || no "prompt 복사"
[ -f .claude/ai-bouncer/workflow.yaml.bak ] && ok "덮기 전 원본 .bak" || no ".bak"
bouncer check >/dev/null && ok "써 넣은 기본값이 유효" || no "기본값 check"
says "이미 단계 설정이 있다" bouncer init --defaults --no-claude-md && ok "설정 있으면 --defaults 거부" || no "덮어쓰기 거부"

# ── 설정 없는 레포: 처음 한 번 켤지 묻는다 ──
N="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$N" init -q
nss(){ printf '{"session_id":"S1","cwd":"%s","source":"%s"}' "$1" "${2:-startup}" | bash "$R/hooks/session-start.sh"; }
o="$(nss "$N")"
printf '%s' "$o" | grep -q 'bouncer setup' && printf '%s' "$o" | grep -q 'init --defaults' && printf '%s' "$o" | grep -q 'init --decline' \
  && ok "설정 없는 레포 → 대화로 정하기 / 기본값 / 안 켬을 묻는다" || no "켤지 질문" "$o"
(cd "$N" && bouncer init --decline >/dev/null 2>&1)
[ -z "$(nss "$N")" ] && ok "--decline 뒤엔 묻지 않는다" || no "decline"

M="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$M" init -q
o="$(cd "$M" && bouncer init --no-claude-md 2>&1)"
! grep -Eq '^(workflows|stages):' "$M/.claude/ai-bouncer/workflow.yaml" && ok "bouncer init 은 기본값을 바로 채우지 않는다" || no "init 이 채움"
printf '%s' "$o" | grep -q 'bouncer setup' && ok "init 뒤 bouncer setup 을 안내" || no "setup 안내" "$o"
(cd "$M" && bouncer check >/dev/null) && ok "빈 설정도 유효 (엔진 기본값)" || no "빈 설정 check"
[ -z "$(nss "$M" | grep 'bouncer setup\|init --defaults')" ] && ok "켠 레포는 다시 묻지 않는다" || no "재질문"
D2="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$D2" init -q
(cd "$D2" && bouncer init --defaults --no-claude-md >/dev/null 2>&1)
grep -q '^workflows:' "$D2/.claude/ai-bouncer/workflow.yaml" && ok "새 레포 init --defaults → 기본값으로 켠다" || no "새 레포 defaults"

# ── init --setup: 다음 새 세션에서 한 번만 setup 안내 ──
P="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$P" init -q
(cd "$P" && bouncer init --setup --no-claude-md >/dev/null 2>&1)
nss "$P" resume | grep -q 'bouncer setup' && no "resume 에서 예약을 씀" || ok "resume 때는 안내하지 않는다"
nss "$P" | grep -q 'bouncer setup' && ok "--setup → 다음 새 세션에서 setup 안내" || no "setup 예약 안내"
nss "$P" | grep -q 'bouncer setup' && no "두 번 안내" || ok "안내는 한 번뿐"

# ── bouncer setup ──
printf '{"scripts":{"test":"jest","lint":"eslint ."}}' > "$P/package.json"; : > "$P/pnpm-lock.yaml"
(cd "$P" && bouncer init --setup --no-claude-md >/dev/null 2>&1)
o="$(cd "$P" && bouncer setup)"
printf '%s' "$o" | grep -q 'pnpm test' && printf '%s' "$o" | grep -q 'pnpm lint' && ok "setup 이 레포의 검사 명령을 찾는다" || no "명령 탐지" "$o"
printf '%s' "$o" | grep -q 'AskUserQuestion' && printf '%s' "$o" | grep -q 'Recommended' && ok "setup 이 묻는 순서와 추천을 안내" || no "setup 안내"
nss "$P" | grep -q 'bouncer setup' && no "setup 뒤에도 예약 남음" || ok "setup 을 돌리면 예약이 지워진다"
says "먼저 bouncer init" bash -c "cd '$N' && bash '$R/engine/bouncer.sh' setup" && ok "설정 없는 레포에서 setup → init 먼저" || no "setup 설정 없음"
printf 'workflows:\n  s: {stages: [implement]}\n' > "$P/.claude/ai-bouncer/workflow.yaml"
(cd "$P" && bouncer setup) | grep -q '이미 단계 설정이 있다' && ok "설정이 있으면 바꿀 부분만 묻게 한다" || no "기존 설정 안내"
rm -rf "$N" "$M" "$D2" "$P"

cleanup; finish
