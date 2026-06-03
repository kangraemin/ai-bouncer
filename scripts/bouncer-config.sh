#!/bin/bash
# bouncer-config.sh: config.json에서 키 값 읽기
# Usage: bouncer-config.sh <key> [default]
# 로컬(.claude/ai-bouncer/config.json) 우선 → 전역(~/.claude/ai-bouncer/config.json) fallback

KEY="${1:-}"
DEFAULT="${2:-}"

# 메인 레포 기준 (worktree에서도 메인 .claude/config을 읽도록 git-common-dir 사용)
REPO_ROOT=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
REPO_ROOT="${REPO_ROOT%/.git}"
[ -z "$REPO_ROOT" ] && REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
LOCAL_CFG="$REPO_ROOT/.claude/ai-bouncer/config.json"
GLOBAL_CFG="$HOME/.claude/ai-bouncer/config.json"

CFG=""
[ -f "$LOCAL_CFG" ] && CFG="$LOCAL_CFG"
[ -z "$CFG" ] && [ -f "$GLOBAL_CFG" ] && CFG="$GLOBAL_CFG"

if [ -z "$CFG" ]; then
  echo "$DEFAULT"
  exit 0
fi

python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get(sys.argv[2], sys.argv[3]))
" "$CFG" "$KEY" "$DEFAULT"
