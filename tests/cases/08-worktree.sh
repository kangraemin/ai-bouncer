#!/usr/bin/env bash
# 케이스 8 — 병렬 작업: 별도 브랜치+worktree, base 브랜치를 생성 시점에 기록, 끝나면 FF 머지
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/config/default.yaml" "$R/config/prompts" || exit 1
trap 'git -C "$T" worktree prune 2>/dev/null; cleanup' EXIT
export CLAUDE_CODE_SESSION_ID=S1
BASE=$(git -C "$T" symbolic-ref --short HEAD)

bouncer start plan "병렬 작업" --parallel >/dev/null 2>&1 || no "병렬 시작"
WT=$(state .worktree.path); BR=$(state .worktree.branch)
[ -d "$WT" ] && ok "레포 밖에 worktree 생성 ($WT)" || no "worktree 생성"
case "$WT" in "$T"/*) no "레포 밖 배치" "레포 안에 생성됨" ;; *) ok "레포 밖 배치" ;; esac
[ "$(state .worktree.base_branch)" = "$BASE" ] && ok "base 브랜치를 생성 시점에 기록" || no "base 기록" "$(state .worktree.base_branch)"
[ -n "$(state .worktree.base_sha)" ] && ok "base sha도 함께 기록" || no "base_sha"
[ "$(state .work_root)" = "$WT" ] && ok "work_root가 worktree로 전환" || no "work_root"

# 커밋 안 하면 finalize 거부
echo change >> "$WT/app.js"
says '커밋되지 않은' bouncer worktree finalize && ok "미커밋이면 머지 거부" || no "미커밋 거부"

git -C "$WT" add app.js && git -C "$WT" commit -qm "feat: 병렬 변경"
bouncer worktree finalize >/dev/null 2>&1 && ok "FF 머지 성공" || no "FF 머지"
LOG="$(git -C "$T" log --oneline)"   # grep -q 로 바로 파이프하면 SIGPIPE + pipefail로 오탐
printf '%s' "$LOG" | grep -q '병렬 변경' && ok "base 브랜치에 반영됨" || no "머지 반영"
[ -d "$WT" ] && no "worktree 정리" "남아있음" || ok "worktree 정리"
git -C "$T" show-ref --verify --quiet "refs/heads/$BR" && no "브랜치 정리" "남아있음" || ok "브랜치 정리"
finish
