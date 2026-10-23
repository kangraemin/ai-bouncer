#!/usr/bin/env bash
# ai-bouncer 제거.
#   ./uninstall.sh            이 레포에서 끈다 (CLAUDE.md 블록·.gitignore 줄·옛 로컬 설치본 정리, workflow.yaml 은 남김)
#   ./uninstall.sh --purge    workflow.yaml·프롬프트·진행 중 작업까지 전부 삭제
#   ./uninstall.sh --global   전역 엔진·훅·스킬·bouncer 실행 파일 제거 (레포 설정은 그대로)
#
# 기본은 사용자 자산(workflow.yaml, prompts/, 진행 중 작업)을 남긴다.

set -uo pipefail
PURGE=0; GLOBAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)  PURGE=1; shift ;;
    --global) GLOBAL=1; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || die "jq가 필요하다."
command -v python3 >/dev/null 2>&1 || die "python3가 필요하다. 없으면 hook 등록 해제와 CLAUDE.md 정리를 할 수 없다."
# PATH에 있어도 실행이 깨져 있으면 정리가 조용히 실패한다. 실제로 돌려본다.
python3 -c 'import json,re,sys' >/dev/null 2>&1 \
  || die "python3가 정상 동작하지 않는다. 제거를 중단한다 — 반쯤 제거된 상태로 남는 것이 더 나쁘다."

# settings.json 에서 ai-bouncer hook 만 걷어낸다 (남의 hook·env 는 둔다).
unhook() {
  [ -f "$1" ] || return 0
  python3 - "$1" "${2:-}" <<'PY' || die "hook 등록 해제 실패 — $1 을 확인하라."
import json, sys
p, d = sys.argv[1], sys.argv[2]
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
                          if "/.claude/ai-bouncer/" not in str(h.get("command", ""))
                          and not (d and str(h.get("command", "")).startswith(d + "/"))]
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
}

if [ "$GLOBAL" = 1 ]; then
  CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; G="$CLAUDE_HOME/ai-bouncer"
  printf 'ai-bouncer 전역 제거 ← %s\n' "$G"
  unhook "$CLAUDE_HOME/settings.json" "$G"
  rm -rf "$G" "$CLAUDE_HOME/skills/dev-bounce"
  BINLINK="$HOME/.local/bin/bouncer"
  { [ -f "$BINLINK" ] || [ -L "$BINLINK" ]; } && rm -f "$BINLINK"
  printf '  엔진·훅·스킬·bouncer 실행 파일 제거\n  레포 설정(.claude/ai-bouncer/workflow.yaml)은 그대로다.\n\n제거 완료.\n'
  exit 0
fi

# bouncer init 이 git 루트에 두므로 제거도 거기서 해야 한다.
# $PWD 만 보면 모노레포 하위에서 "설치된 ai-bouncer가 없다"는 거짓 진단이 나온다.
PROJECT="$PWD"
if [ ! -d "$PROJECT/.claude/ai-bouncer" ]; then
  _top="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_top" ] && [ -d "$_top/.claude/ai-bouncer" ] && PROJECT="$_top"
fi
cd "$PROJECT" || die "프로젝트 디렉토리로 이동할 수 없다: $PROJECT"
ROOT="$PROJECT/.claude"; DIR="$ROOT/ai-bouncer"; SETTINGS="$ROOT/settings.json"
[ -d "$DIR" ] || die "이 레포에 ai-bouncer 설정이 없다: $DIR"
printf 'ai-bouncer 제거 ← %s\n' "$DIR"

# ── 1. 옛 로컬 설치본의 hook 등록 해제 ───────────────────────
unhook "$SETTINGS"

# ── 2. CLAUDE.md 규칙 블록 제거 (마커 사이만) ────────────────
CMD_FILE="$PWD/CLAUDE.md"
if [ -f "$CMD_FILE" ] && grep -q '<!-- ai-bouncer:start -->' "$CMD_FILE"; then
  python3 - "$CMD_FILE" <<'PYM' || die "CLAUDE.md 정리 실패."
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*<!-- ai-bouncer:start -->.*?<!-- ai-bouncer:end -->\n*', '\n', s, flags=re.S)
open(p, 'w').write(s.strip() + '\n' if s.strip() else '')
PYM
  printf '  CLAUDE.md 규칙 블록 제거 (나머지 내용은 그대로)\n'
fi

# ── 3. 우리가 .gitignore 에 넣은 줄 되돌리기 ─────────────────
# 우리가 넣은 줄만 되돌린다. 사용자가 원래 갖고 있던 줄을 지우면 파일 손상이다.
GI="$PWD/.gitignore"
GI_MINE="$(cat "$DIR/init.json" "$DIR/manifest.json" 2>/dev/null | jq -r '.gitignore_added // false' 2>/dev/null | grep -m1 true)"
if [ "$GI_MINE" = "true" ] && [ -f "$GI" ] && grep -qxF '.ai-bouncer/' "$GI"; then
  python3 - "$GI" <<'PYG' || die ".gitignore 정리 실패."
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*# ai-bouncer 런타임 상태\n\.ai-bouncer/\n', '\n', s)
s = re.sub(r'(?m)^\.ai-bouncer/$\n?', '', s)
open(p, 'w').write(s)
PYG
  printf '  .gitignore에서 .ai-bouncer/ 제거\n'
  # 무시 규칙을 지우면 남아 있는 런타임 디렉토리가 미추적으로 드러난다. 비었으면 같이 치운다.
  if [ -d "$PWD/.ai-bouncer" ] && [ -z "$(ls -A "$PWD/.ai-bouncer" 2>/dev/null)" ]; then
    rmdir "$PWD/.ai-bouncer" 2>/dev/null
  elif [ -d "$PWD/.ai-bouncer" ] && [ "$PURGE" != 1 ]; then
    printf '  ⚠️ %s/.ai-bouncer 가 남아 있다 (진행 중 작업 기록).\n' "$PWD"
    printf '     git이 이제 이걸 미추적으로 본다 — 지우려면: rm -rf .ai-bouncer\n'
  fi
fi

# ── 4. 엔진이 만든 파일 + 옛 로컬 설치본 제거 ────────────────
rm -rf "$DIR/engine" "$DIR/hooks" "$DIR/bin" "$DIR/scripts" "$ROOT/skills/dev-bounce"
rm -f "$DIR/workflow.compiled.json" "$DIR/installed.json" "$DIR/manifest.json" "$DIR/init.json" \
      "$DIR/.update-check" "$DIR/.gitignore"
[ -e "$DIR/hooks" ] && die "파일을 지우지 못했다 (권한 문제로 보인다). 남은 것: $DIR"

if [ "$PURGE" = 1 ]; then
  rm -rf "$DIR" "$PWD/.ai-bouncer"
  printf '  워크플로우·프롬프트·진행 중 작업까지 삭제 (--purge)\n'
else
  rmdir "$DIR" 2>/dev/null && printf '  디렉토리 제거\n' \
    || printf '  사용자 자산 유지: %s (workflow.yaml, prompts/) — 이게 남아 있으면 전역 훅이 계속 켜 둔다.\n     완전히 끄려면 --purge\n' "$DIR"
  [ -d "$PWD/.ai-bouncer" ] && printf '  진행 중 작업 유지: %s/.ai-bouncer\n' "$PWD"
fi

# 우리가 만들어놓고 내용이 비게 된 파일은 남기지 않는다.
for f in "$PWD/CLAUDE.md" "$PWD/.gitignore"; do
  [ -f "$f" ] && [ -z "$(tr -d '[:space:]' < "$f")" ] && rm -f "$f"
done
[ -f "$SETTINGS" ] && [ "$(jq -c . "$SETTINGS" 2>/dev/null)" = "{}" ] && rm -f "$SETTINGS"
rmdir "$ROOT/skills" "$ROOT" 2>/dev/null

printf '\n제거 완료. (전역 엔진은 다른 레포가 쓴다 — 지우려면 --global)\n'
