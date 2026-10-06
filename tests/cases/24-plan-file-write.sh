#!/usr/bin/env bash
# 케이스 24 — 읽기 전용 plan 단계에서도 Claude Code 의 plan 파일(~/.claude/plans/*.md)은 쓸 수 있다.
#
# plan 단계는 `edit_files: true` 라 계획 파일까지 막혀서 plan 모드 자체가 진행되지 않았다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [plan, done]}
stages:
  plan:
    steps: [{label: 승인, blocking: plan_approved, inject: "계획."}]
    forbid: {edit_files: true, push: true, reason: 계획 전}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
bouncer start plan pf >/dev/null
mkdir -p "$HOME/.claude/plans/sub"
blocked(){ pre Write "{\"file_path\":\"$1\",\"content\":\"x\"}" 2>&1 | grep -q '차단'; }
allowed_ok(){ ! blocked "$1"; }
group "plan 파일은 쓸 수 있다" allowed_ok <<X
$HOME/.claude/plans/x.md
X
group "그 밖은 계속 막힌다" blocked <<X
$HOME/.claude/plans/sub/x.md
$HOME/.claude/plans/x.sh
$HOME/.claude/plans/../x.md
/tmp/x.md
$T/app.js
X
ln -s "$T/app.js" "$HOME/.claude/plans/link.md"
blocked "$HOME/.claude/plans/link.md" && ok "plans 안의 링크로 프로젝트 파일을 우회할 수 없다" || no "링크 우회" ""
finish
