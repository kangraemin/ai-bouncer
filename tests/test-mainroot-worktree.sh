#!/bin/bash
# main-root 해석: worktree 안에서도 config/REPO_NAME을 메인 레포 기준으로 잡는지 검증
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BC="$REPO/scripts/bouncer-config.sh"
PASS=0; FAIL=0
ok(){ echo "✅ $1"; PASS=$((PASS+1)); }; ng(){ echo "❌ $1"; FAIL=$((FAIL+1)); }
gitc(){ git -c user.email=t@t -c user.name=t "$@"; }

TMP=$(mktemp -d); export HOME="$TMP/home"; mkdir -p "$HOME"
P="$TMP/proj"; mkdir -p "$P/.claude/ai-bouncer"
( cd "$P" && git init -q && gitc -C "$P" commit --allow-empty -qm init )
echo '{"commit_strategy":"per-phase"}' > "$P/.claude/ai-bouncer/config.json"
# 전역 config는 다른 값(이게 잘못 읽히면 fallback 증거)
mkdir -p "$HOME/.claude/ai-bouncer"; echo '{"commit_strategy":"per-step"}' > "$HOME/.claude/ai-bouncer/config.json"

# TC-2: 비-worktree(메인)에서 프로젝트값
CS_MAIN=$(cd "$P" && bash "$BC" commit_strategy none)
[ "$CS_MAIN" = "per-phase" ] && ok "TC-2: 비-worktree 메인 config 값(per-phase)" || ng "TC-2: $CS_MAIN"

# TC-1: worktree에서도 메인 프로젝트값 (전역 per-step로 안 샘)
gitc -C "$P" worktree add -q "$TMP/wt" -b wtb 2>/dev/null
CS_WT=$(cd "$TMP/wt" && bash "$BC" commit_strategy none)
[ "$CS_WT" = "per-phase" ] && ok "TC-1: worktree서 메인 config 값(per-phase, fallback 아님)" || ng "TC-1: worktree서 $CS_WT (전역으로 샘)"

# TC-3: 문법
bash -n "$0" && ok "TC-3: 테스트 파일 문법 ok" || ng "TC-3"

gitc -C "$P" worktree remove --force "$TMP/wt" 2>/dev/null; rm -rf "$TMP"
echo ""; echo "결과: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
