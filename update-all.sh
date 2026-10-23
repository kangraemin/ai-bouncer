#!/usr/bin/env bash
# 이 컴퓨터의 ai-bouncer 를 갱신한다.
#   1) 전역 엔진·훅·스킬을 새로 깐다 (install.sh --no-init)
#   2) ai-bouncer 를 켠 레포마다 bouncer init 을 돈다 — 설정은 보존하고, 옛 로컬 설치본(레포 안 엔진·훅)을 걷어낸다
#   대상 레포 = 목록(~/.local/state/ai-bouncer/installs) ∪ 홈 아래에서 찾은 설정 ∪ 현재 레포.
#   하나가 실패해도 나머지는 계속한다. 설정이 없어진 레포는 목록에서 뺀다.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH=main; SCAN_ROOT="${BOUNCER_SCAN_ROOT:-$HOME}"
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-main}"; shift 2 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done
REG_DIR="${BOUNCER_REGISTRY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ai-bouncer}"
REG="$REG_DIR/installs"
G="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ai-bouncer"

out="$(bash "$SRC/install.sh" --ci --no-init --branch "$BRANCH" 2>&1)" \
  || { printf 'ai-bouncer: 전역 설치 실패\n%s\n' "$out" >&2; exit 1; }
printf 'ai-bouncer: 전역 엔진 갱신 → %s\n' "$G"

LIST="$(mktemp)"; trap 'rm -f "$LIST" "$LIST.out"' EXIT
{
  [ -f "$REG" ] && cat "$REG"
  # 목록이 생기기 전에 켠 레포도 찾는다. 라이브러리·의존성 폴더는 건너뛴다.
  find "$SCAN_ROOT" -maxdepth 6 \( -name node_modules -o -name Library -o -name .Trash -o -name .git \) -prune \
       -o -type f -path '*/.claude/ai-bouncer/workflow.yaml' -print 2>/dev/null \
    | sed 's|/\.claude/ai-bouncer/workflow\.yaml$||'
  here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$here" ] && [ -f "$here/.claude/ai-bouncer/workflow.yaml" ] && printf '%s\n' "$here"
} | while IFS= read -r d; do
  # 같은 폴더가 심볼릭 링크로 다른 경로(/var ↔ /private/var 등)로 잡히면 두 번 돈다.
  [ -n "$d" ] || continue
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
done | awk 'NF && !seen[$0]++' > "$LIST"

N=0; while IFS= read -r d; do [ -f "$d/.claude/ai-bouncer/workflow.yaml" ] && N=$((N+1)); done < "$LIST"
printf 'ai-bouncer: 켠 레포 %s곳의 설정을 정리한다\n\n' "$N"

ok=0; fail=0; dirty=0; : > "$LIST.out"
while IFS= read -r d; do
  if [ ! -f "$d/.claude/ai-bouncer/workflow.yaml" ]; then
    printf '  - %s (설정 없음 — 목록에서 뺌)\n' "$d"; continue
  fi
  if o="$(cd "$d" && bash "$G/engine/init.sh" --no-claude-md 2>&1)"; then
    ok=$((ok+1)); printf '  ✅ %s\n' "$d"
    printf '%s' "$o" | grep -q '커밋하라' && { dirty=$((dirty+1)); printf '     ⚠️ 설정이 바뀌었다 — 그 레포에서 커밋하라\n'; }
  else
    fail=$((fail+1)); printf '  ❌ %s — %s\n' "$d" "$(printf '%s' "$o" | tail -1)"
  fi
  printf '%s\n' "$d" >> "$LIST.out"   # 실패도 목록에 남긴다 (다음에 다시 시도)
done < "$LIST"

mkdir -p "$REG_DIR" 2>/dev/null && cp "$LIST.out" "$REG" 2>/dev/null
printf '\n완료: 성공 %s / 실패 %s (미커밋 %s곳)\n' "$ok" "$fail" "$dirty"
[ "$fail" -eq 0 ]
