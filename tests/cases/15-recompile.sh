#!/usr/bin/env bash
# 케이스 15 — yaml/프롬프트가 바뀌면 재컴파일되고, 깨지면 이전 설정을 유지한다
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap cleanup EXIT
SS(){ printf '{"session_id":"S1","cwd":"%s"}' "$T" | bash "$R/hooks/session-start.sh"; }
C=.claude/ai-bouncer/workflow.compiled.json

H0=$(jq -r .source_sha256 $C)
SS >/dev/null; [ "$(jq -r .source_sha256 $C)" = "$H0" ] && ok "변경 없으면 재컴파일 안 함" || no "불필요 재컴파일"

# yaml 변경
python3 - <<'P'
p='.claude/ai-bouncer/workflow.yaml'; s=open(p).read()
open(p,'w').write(s.replace('label: 계획 없이 바로 구현','label: 계획 없이 바로 구현 (수정됨)'))
P
SS >/dev/null
[ "$(jq -r '.workflows.simple.label' $C)" = "계획 없이 바로 구현 (수정됨)" ] && ok "yaml 변경을 반영" || no "yaml 반영"

# 프롬프트 파일만 변경 — 해시에 포함돼야 한다
printf '\n추가된 지시.\n' >> .claude/ai-bouncer/prompts/plan.md
SS >/dev/null
jq -r '.stages.plan.steps[0].text' $C | grep -q '추가된 지시' && ok "프롬프트만 고쳐도 반영" || no "프롬프트 반영"

# 깨진 yaml — 이전 설정을 유지해야 한다
GOOD=$(jq -r '.workflows.simple.label' $C)
printf 'blocking: 이상한값\n' >> .claude/ai-bouncer/workflow.yaml   # 알 수 없는 최상위 키
out=$(SS)
printf '%s' "$out" | grep -q '이전 설정으로 계속' && ok "컴파일 실패를 알림" || no "실패 알림"
[ "$(jq -r '.workflows.simple.label' $C)" = "$GOOD" ] && ok "실패해도 기존 compiled.json 보존" || no "보존"
jq -e . $C >/dev/null 2>&1 && ok "compiled.json이 깨지지 않음" || no "json 무결성"
finish
