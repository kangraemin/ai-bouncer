#!/usr/bin/env bash
# 케이스 25 — push 금지 단계에서도 프로젝트와 무관한 다른 레포의 push 는 막지 않는다.
#
# library 기록처럼 다른 레포에 커밋·push 하는 것까지 매번 막혔다.
# 대상 레포가 확실히 프로젝트 밖일 때만 열고, 조금이라도 애매하면 막는다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [impl, done]}
stages:
  impl:
    steps: [{label: 구현, inject: "구현."}]
    forbid: {push: true, reason: 검증 전}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
O="$(mktemp -d)"; git -C "$O" init -q
trap 'cleanup; rm -rf "$FIXTURE_DIR" "$O"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan pr >/dev/null
blocked(){ pre Bash "$(jq -n --arg c "$1" '{command:$c}')" 2>&1 | grep -q '차단\|허용되지\|판정할 수'; }
allowed_ok(){ ! blocked "$1"; }
group "다른 레포 push 는 통과" allowed_ok <<X
git -C $O push
cd $O && git push
cd $O && git push origin main
X
group "프로젝트·애매한 대상은 계속 차단" blocked <<X
git push
git -C $T push
cd $O && cd - && git push
cd $O && cd $T && git push
GIT_DIR=$O/.git git push
git --git-dir=$O/.git push
git -C \$X push
(cd $O) && git push
X
finish
