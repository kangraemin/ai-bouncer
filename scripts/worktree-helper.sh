#!/bin/bash
# worktree-helper.sh — ai-bouncer 병렬 dev-bounce용 git worktree 수명주기
# 서브커맨드:
#   create <repo_root> <task_name>
#     → base 브랜치 기록 + 브랜치명 결정 + ~/.ai-bouncer/worktrees/<repo>/<branch> 에 worktree add
#     → stdout: WT=<path> / BRANCH=<b> / BASE=<base>  (각 줄)
#   branch-name <repo_root> <task_name>
#     → 레포 기존 브랜치에 feature/·feat/ prefix 있으면 그거+task, 없으면 aibouncer/<task>
#   finalize <repo_root> <wt_path> <branch> <base> <task_dir> <track_docs>   (Step 2)
#
# 모든 git은 -C로 대상 명시. worktree는 레포 working tree 밖(~/.ai-bouncer) → Metro/빌드툴 안전.

set -u
CMD="${1:-}"

_branch_name() {
  local repo="$1" task="$2" prefix
  prefix=$(git -C "$repo" branch --format='%(refname:short)' 2>/dev/null \
            | grep -oE '^(feature|feat|feat-feature)/' | head -1)
  if [ -n "$prefix" ]; then
    echo "${prefix}${task}"
  else
    echo "aibouncer/${task}"
  fi
}

case "$CMD" in
  branch-name)
    _branch_name "$2" "$3"
    ;;

  create)
    repo="$2"; task="$3"
    [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERR: not a git repo: $repo" >&2; exit 1; }
    base=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null)
    [ -z "$base" ] && base=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
    repo_name=$(basename "$repo")
    br=$(_branch_name "$repo" "$task")
    # 브랜치 충돌 시 suffix
    if git -C "$repo" show-ref --verify --quiet "refs/heads/${br}"; then
      i=2
      while git -C "$repo" show-ref --verify --quiet "refs/heads/${br}-${i}"; do i=$((i+1)); done
      br="${br}-${i}"
    fi
    wt="$HOME/.ai-bouncer/worktrees/${repo_name}/${br}"
    mkdir -p "$(dirname "$wt")"
    if ! git -C "$repo" worktree add -b "$br" "$wt" "$base" >/dev/null 2>&1; then
      echo "ERR: worktree add 실패 (repo=$repo br=$br base=$base)" >&2; exit 1
    fi
    echo "WT=$wt"
    echo "BRANCH=$br"
    echo "BASE=$base"
    ;;

  finalize)
    repo="$2"; wt="$3"; br="$4"; base="$5"; task_dir="${6:-}"; track_docs="${7:-false}"
    # 1) worktree에서 base로 rebase — 충돌 시 abort + 비-0 종료(worktree 보존)
    if ! git -C "$wt" rebase "$base" >/dev/null 2>&1; then
      git -C "$wt" rebase --abort >/dev/null 2>&1
      echo "ERR: rebase 충돌 — worktree 보존, 수동 해결 필요 (wt=$wt br=$br base=$base)" >&2
      exit 3
    fi
    # 2) 메인에서 FF-only 머지 (머지커밋 없음)
    if ! git -C "$repo" merge --ff-only "$br" >/dev/null 2>&1; then
      echo "ERR: FF 머지 실패 (base가 앞서감?) — worktree 보존" >&2
      exit 4
    fi
    # 3) track off면 task 문서 메인으로 cp (.active·.cg-stop-count-* 제외)
    if [ "$track_docs" != "true" ] && [ -n "$task_dir" ]; then
      rel="${task_dir#"$wt"/}"            # worktree 절대경로면 rel로 변환
      src="$wt/$rel"; dst="$repo/$rel"
      if [ -d "$src" ]; then
        mkdir -p "$dst"
        ( cd "$src" && find . -type f ! -name '.active' ! -name '.cg-stop-count-*' -print0 \
            | while IFS= read -r -d '' f; do mkdir -p "$dst/$(dirname "$f")"; cp "$f" "$dst/$f"; done )
      fi
    fi
    # 4) worktree·브랜치 정리
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
    git -C "$repo" branch -D "$br" >/dev/null 2>&1
    echo "FINALIZED branch=$br → base=$base"
    ;;

  *)
    echo "usage: worktree-helper.sh {create|finalize|branch-name} ..." >&2; exit 64
    ;;
esac
