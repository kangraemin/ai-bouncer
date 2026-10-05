#!/usr/bin/env bash
# 이 컴퓨터에 깔린 ai-bouncer 전부를 갱신한다.
#   대상 = 설치 목록(~/.local/state/ai-bouncer/installs) ∪ 홈 아래에서 찾은 설치본 ∪ 현재 프로젝트
#   각 프로젝트에서 install.sh 를 돌린다 (설정은 보존). 하나가 실패해도 나머지는 계속한다.
#   더 이상 설치본이 없는 경로는 목록에서 뺀다.
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

LIST="$(mktemp)"; trap 'rm -f "$LIST" "$LIST.out"' EXIT
{
  [ -f "$REG" ] && cat "$REG"
  # 목록이 생기기 전에 깔린 설치본도 찾는다. 라이브러리·의존성 폴더는 건너뛴다.
  find "$SCAN_ROOT" -maxdepth 6 \( -name node_modules -o -name Library -o -name .Trash -o -name .git \) -prune \
       -o -type f -path '*/.claude/ai-bouncer/installed.json' -print 2>/dev/null \
    | sed 's|/\.claude/ai-bouncer/installed\.json$||'
  here="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$here" ] && [ -d "$here/.claude/ai-bouncer" ] && printf '%s\n' "$here"
} | while IFS= read -r d; do
  # 같은 폴더가 심볼릭 링크로 다른 경로(/var ↔ /private/var 등)로 잡히면 두 번 돈다.
  [ -n "$d" ] || continue
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
done | awk 'NF && !seen[$0]++' > "$LIST"

N=0; while IFS= read -r d; do [ -d "$d/.claude/ai-bouncer" ] && N=$((N+1)); done < "$LIST"
[ "$N" -gt 0 ] || { printf 'ai-bouncer: 이 컴퓨터에서 설치본을 찾지 못했다. 설치하려면: get.sh 를 인자 없이 실행\n'; exit 0; }
printf 'ai-bouncer: 설치본 %s곳을 갱신한다\n\n' "$N"

ok=0; fail=0; dirty=0; : > "$LIST.out"
while IFS= read -r d; do
  if [ ! -d "$d/.claude/ai-bouncer" ]; then
    printf '  - %s (설치본 없음 — 목록에서 뺌)\n' "$d"; continue
  fi
  if out="$(cd "$d" && bash "$SRC/install.sh" --ci --branch "$BRANCH" 2>&1)"; then
    ok=$((ok+1)); printf '  ✅ %s\n' "$d"; printf '%s\n' "$d" >> "$LIST.out"
    printf '%s' "$out" | grep -q '커밋되지 않았다' && { dirty=$((dirty+1)); printf '     ⚠️ 설치 파일 미커밋 — 다음 작업 finalize 전에 커밋 필요\n'; }
  else
    fail=$((fail+1)); printf '  ❌ %s — %s\n' "$d" "$(printf '%s' "$out" | tail -1)"
    printf '%s\n' "$d" >> "$LIST.out"   # 실패는 목록에 남긴다 (다음에 다시 시도)
  fi
done < "$LIST"

mkdir -p "$REG_DIR" 2>/dev/null && cp "$LIST.out" "$REG" 2>/dev/null
printf '\n완료: 성공 %s / 실패 %s (미커밋 %s곳)\n' "$ok" "$fail" "$dirty"
[ "$fail" -eq 0 ]
