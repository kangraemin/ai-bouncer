#!/usr/bin/env bash
# ai-bouncer 제거.
#   ./uninstall.sh            이 프로젝트에서 제거
#   ./uninstall.sh --purge    워크플로우·프롬프트·진행 중 작업까지 전부 삭제
#
# 기본은 사용자 자산(workflow.yaml, prompts/, 진행 중 작업)을 남긴다.

set -uo pipefail
PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --global|--local)
      printf 'ai-bouncer: %s 는 더 이상 지원하지 않는다. 제거는 프로젝트별로만 한다.\n' "$1" >&2
      exit 1 ;;
    --purge)  PURGE=1; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq가 필요하다."

ROOT="$PWD/.claude"
DIR="$ROOT/ai-bouncer"; SETTINGS="$ROOT/settings.json"
[ -d "$DIR" ] || die "설치된 ai-bouncer가 없다: $DIR"
printf 'ai-bouncer 제거 ← %s\n' "$DIR"

# ── 1. hook 등록 해제 (우리 것만) ────────────────────────────
if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
except Exception:
    sys.exit(0)
hooks = cfg.get("hooks", {})
removed = 0
for event, arr in list(hooks.items()):
    for entry in list(arr):
        before = len(entry.get("hooks", []))
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/ai-bouncer/" not in str(h.get("command", ""))]
        removed += before - len(entry["hooks"])
        if not entry["hooks"]:
            arr.remove(entry)
    if not arr:
        del hooks[event]
if not hooks:
    cfg.pop("hooks", None)
json.dump(cfg, open(p, "w"), ensure_ascii=False, indent=2)
print(f"  hook {removed}개 등록 해제 (다른 도구의 hook은 유지)")
PY
fi

# ── 1-b. CLAUDE.md 규칙 블록 제거 (마커 사이만) ──────────────
CMD_FILE="$PWD/CLAUDE.md"
if [ -f "$CMD_FILE" ] && grep -q '<!-- ai-bouncer:start -->' "$CMD_FILE"; then
  python3 - "$CMD_FILE" <<'PYM'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*<!-- ai-bouncer:start -->.*?<!-- ai-bouncer:end -->\n*', '\n', s, flags=re.S)
open(p, 'w').write(s.strip() + '\n' if s.strip() else '')
PYM
  printf '  CLAUDE.md 규칙 블록 제거 (나머지 내용은 그대로)\n'
fi

# ── 1-c. install이 .gitignore에 넣은 줄 되돌리기 ─────────────
GI="$PWD/.gitignore"
if [ -f "$GI" ] && grep -qxF '.ai-bouncer/' "$GI"; then
  python3 - "$GI" <<'PYG'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*# ai-bouncer 런타임 상태\n\.ai-bouncer/\n', '\n', s)
s = re.sub(r'(?m)^\.ai-bouncer/$\n?', '', s)
open(p, 'w').write(s)
PYG
  printf '  .gitignore에서 .ai-bouncer/ 제거\n'
fi

# ── 2. manifest 기반 파일 제거 ───────────────────────────────
# 목록에 있는 것만 지운다. 사용자가 나중에 넣은 파일은 건드리지 않는다.
if [ -f "$DIR/manifest.json" ]; then
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */CLAUDE.md) continue ;; esac   # 사용자 파일 — 블록만 위에서 제거했다
    [ "$PURGE" = 0 ] && case "$f" in */workflow.yaml|*/prompts/*) continue ;; esac
    rm -f "$f" && n=$((n+1))
  done < <(jq -r '.files[]?' "$DIR/manifest.json")
  printf '  파일 %d개 제거\n' "$n"
fi
rm -f "$DIR/workflow.compiled.json" "$DIR/installed.json" "$DIR/manifest.json" \
      "$DIR/.update-check" "$DIR/.gitignore" "$DIR/bin/bouncer"
rmdir "$DIR"/bin "$DIR"/hooks "$DIR"/scripts "$DIR"/engine/lib "$DIR"/engine 2>/dev/null
rmdir "$ROOT/skills/dev-bounce" 2>/dev/null

if [ "$PURGE" = 1 ]; then
  rm -rf "$DIR" "$PWD/.ai-bouncer"
  printf '  워크플로우·프롬프트·진행 중 작업까지 삭제 (--purge)\n'
else
  rmdir "$DIR" 2>/dev/null && printf '  디렉토리 제거\n' \
    || printf '  사용자 자산 유지: %s (workflow.yaml, prompts/)\n' "$DIR"
  [ -d "$PWD/.ai-bouncer" ] && printf '  진행 중 작업 유지: %s/.ai-bouncer\n' "$PWD"
fi

printf '\n제거 완료.\n'
