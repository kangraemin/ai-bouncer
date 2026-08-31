#!/usr/bin/env bash
# 구버전(전역 설치) ai-bouncer 정리.
#
#   ./migrate.sh                     무엇을 할지 보여주기만 한다 (기본)
#   ./migrate.sh --apply             전역 구버전을 제거한다
#   ./migrate.sh --apply --install   제거 후, 구버전을 쓰던 프로젝트에 신규를 설치한다
#   ./migrate.sh --scan <경로>        프로젝트를 찾을 위치 (기본 ~/programming, 반복 가능)
#
# 신규는 프로젝트별로만 설치한다. 전역에 남은 구버전은 hook이 계속 등록된 채
# 돌면서 자기 자신을 업데이트하려 들기 때문에 반드시 정리해야 한다.
#
# 이 스크립트는 ai-bouncer가 스스로 설치한 것만 건드린다.
# 사용자가 쓴 다른 hook, 다른 스킬, CLAUDE.md의 나머지 내용은 손대지 않는다.

set -uo pipefail
APPLY=0; INSTALL=0; SCAN_DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --install) INSTALL=1; shift ;;
    --scan)    SCAN_DIRS+=("${2:-}"); shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ ${#SCAN_DIRS[@]} -eq 0 ] && SCAN_DIRS=("$HOME/programming")
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

G="$HOME/.claude"
DIR="$G/ai-bouncer"
SETTINGS="$G/settings.json"
CMD_FILE="$G/CLAUDE.md"
command -v jq >/dev/null 2>&1 || { printf 'ai-bouncer: jq가 필요하다.\n' >&2; exit 1; }

say() { printf '%s\n' "$1"; }
act() { [ "$APPLY" = 1 ] && printf '  ✔ %s\n' "$1" || printf '  · %s\n' "$1"; }

[ "$APPLY" = 1 ] && say "구버전 전역 설치 정리 (실행)" || say "구버전 전역 설치 정리 — 미리보기 (실제로 지우려면 --apply)"
say ""

FOUND=0

# ── 1. 전역 settings.json의 ai-bouncer hook ──────────────────
if [ -f "$SETTINGS" ]; then
  N=$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[]
          | select(.command | contains("/ai-bouncer/"))] | length' "$SETTINGS" 2>/dev/null)
  if [ "${N:-0}" -gt 0 ]; then
    FOUND=1
    say "전역 settings.json에 등록된 ai-bouncer hook: ${N}개"
    jq -r '.hooks // {} | to_entries[] as $e | $e.value[] | .hooks[]
           | select(.command | contains("/ai-bouncer/"))
           | "    \($e.key)  \(.command)"' "$SETTINGS" 2>/dev/null
    if [ "$APPLY" = 1 ]; then
      cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
      python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hooks = cfg.get("hooks", {})
for event, arr in list(hooks.items()):
    for entry in list(arr):
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/ai-bouncer/" not in str(h.get("command", ""))]
        if not entry["hooks"]:
            arr.remove(entry)
    if not arr:
        del hooks[event]
if not hooks:
    cfg.pop("hooks", None)
json.dump(cfg, open(p, "w"), ensure_ascii=False, indent=2)
PY
    fi
    act "hook 등록 해제 (다른 도구의 hook은 유지, settings.json 백업 생성)"
    say ""
  fi
fi

# ── 2. 전역 ai-bouncer 디렉토리 ──────────────────────────────
if [ -d "$DIR" ]; then
  FOUND=1
  say "전역 설치 디렉토리: $DIR"
  find "$DIR" -type f 2>/dev/null | sed "s|$DIR/|    |" | head -20
  CNT=$(find "$DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$CNT" -gt 20 ] && say "    ... 총 ${CNT}개"
  if [ -f "$DIR/config.json" ]; then
    say ""
    say "  구 config.json 값 (신규는 workflow.yaml의 settings 섹션을 쓴다):"
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "$DIR/config.json" 2>/dev/null
  fi
  [ "$APPLY" = 1 ] && rm -rf "$DIR"
  act "디렉토리 제거"
  say ""
fi

# ── 3. 구버전 전역 스킬 ──────────────────────────────────────
for sk in dev-bounce bouncer-status update-bouncer; do
  d="$G/skills/$sk"
  [ -d "$d" ] || continue
  FOUND=1
  say "구버전 전역 스킬: $d"
  [ "$APPLY" = 1 ] && rm -rf "$d"
  act "제거"
done
[ "$FOUND" = 1 ] && say ""

# ── 4. 전역 CLAUDE.md의 구 규칙 블록 ─────────────────────────
if [ -f "$CMD_FILE" ] && grep -q 'ai-bouncer-rule start' "$CMD_FILE"; then
  FOUND=1
  say "전역 CLAUDE.md의 구 규칙 블록:"
  sed -n '/ai-bouncer-rule start/,/ai-bouncer-rule end/p' "$CMD_FILE" | sed 's/^/    /'
  if [ "$APPLY" = 1 ]; then
    cp "$CMD_FILE" "$CMD_FILE.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$CMD_FILE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*# --- ai-bouncer-rule start ---.*?# --- ai-bouncer-rule end ---\n*', '\n\n', s, flags=re.S)
open(p, 'w').write(s)
PY
  fi
  act "블록만 제거 (나머지 내용은 그대로, CLAUDE.md 백업 생성)"
  say ""
fi

# ── 5. 구버전 작업 문서 ──────────────────────────────────────
say "구버전 작업 문서(.ai-bouncer-tasks/)는 어느 것도 지우지 않는다."
say "신규 엔진은 이 형식을 읽지 못하지만, 기록으로 남겨둔다."
say ""

[ "$FOUND" = 0 ] && say "정리할 전역 구버전 설치는 없다."
say ""

# ── 6. 구버전을 쓰던 프로젝트에 신규 설치 ────────────────────
# 전역이 사라지면 그 프로젝트들은 bouncer 없이 남는다. 한 번에 옮긴다.
PROJECTS=()
for base in "${SCAN_DIRS[@]}"; do
  [ -d "$base" ] || continue
  while IFS= read -r d; do
    p="${d%/.ai-bouncer-tasks}"
    # 이미 신규가 설치된 곳은 건너뛴다
    [ -f "$p/.claude/ai-bouncer/workflow.yaml" ] && continue
    PROJECTS+=("$p")
  done < <(find "$base" -maxdepth 4 -name ".ai-bouncer-tasks" -type d 2>/dev/null | sort)
done

if [ ${#PROJECTS[@]} -gt 0 ]; then
  say "구버전을 쓰던 프로젝트 ${#PROJECTS[@]}개 (신규 미설치):"
  for p in "${PROJECTS[@]}"; do
    last="$(cd "$p" && git log -1 --format=%cd --date=short 2>/dev/null)"
    printf '    %-52s %s\n' "${p/#$HOME/~}" "${last:+마지막 커밋 $last}"
  done
  say ""
  if [ "$INSTALL" = 1 ] && [ "$APPLY" = 1 ]; then
    OKN=0; FAILN=0
    for p in "${PROJECTS[@]}"; do
      if ( cd "$p" && bash "$SRC/install.sh" --ci >/dev/null 2>&1 ); then
        printf '  ✔ %s\n' "${p/#$HOME/~}"; OKN=$((OKN+1))
      else
        printf '  ✘ %s (설치 실패 — 직접 확인 필요)\n' "${p/#$HOME/~}"; FAILN=$((FAILN+1))
      fi
    done
    say ""
    say "설치 완료 ${OKN}개 / 실패 ${FAILN}개"
    say "각 프로젝트에서 .gitignore·CLAUDE.md·.claude/ 가 바뀌었다. 커밋 여부는 직접 판단하라."
  else
    say "  (--apply --install 을 함께 주면 이 프로젝트들에 신규를 설치한다)"
  fi
  say ""
fi

if [ "$APPLY" = 1 ]; then
  [ "$INSTALL" = 1 ] || say "정리 완료. 프로젝트마다 install.sh를 실행하거나 --install 을 함께 써라."
elif [ "$FOUND" = 1 ] || [ ${#PROJECTS[@]} -gt 0 ]; then
  say "실제로 실행하려면: ./migrate.sh --apply --install"
else
  say "이관할 것이 없다."
fi
