#!/usr/bin/env bash
# ai-bouncer 설치 — 엔진·훅·스킬을 이 컴퓨터에 한 벌 깐다 (~/.claude/ai-bouncer).
#   ./install.sh                전역 설치 + 지금 레포가 git 레포면 거기도 켠다 (bouncer init)
#   ./install.sh --no-init      전역 설치만
#   ./install.sh --ci           비대화 모드 (사실 물어보는 게 없다)
#   ./install.sh --branch dev   업데이트 기준 브랜치 기록
#   ./install.sh --no-claude-md bouncer init 이 CLAUDE.md 에 규칙 블록을 넣지 않음
#
# 레포에는 설정(.claude/ai-bouncer/workflow.yaml)만 둔다. 설정이 없는 레포에선 훅이 아무것도 안 하고,
# 새 세션을 시작할 때 켤지 한 번 묻는다.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CI=0; BRANCH=main; INIT=1; INIT_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-claude-md) INIT_ARGS+=(--no-claude-md); shift ;;
    --no-init)      INIT=0; shift ;;
    --global)       INIT=0; shift ;;
    --ci)           CI=1; shift ;;
    --branch)
      [ $# -ge 2 ] || { printf 'ai-bouncer: --branch 에 값이 필요합니다.\n' >&2; exit 1; }
      BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || die "jq가 필요하다. brew install jq"
command -v python3 >/dev/null 2>&1 || die "python3가 필요하다."

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
G="$CLAUDE_HOME/ai-bouncer"
SETTINGS="$CLAUDE_HOME/settings.json"
printf 'ai-bouncer 설치 → %s\n' "$G"

# ── 1. 파일 배치 ─────────────────────────────────────────────
# 통째로 갈아끼운다 — 지난 버전에만 있던 파일이 남아 돌면 안 된다.
NEW="$G.new.$$"; rm -rf "$NEW"
mkdir -p "$NEW/engine/lib" "$NEW/engine/prompts" "$NEW/hooks" || die "디렉토리 생성 실패"
# engine/lib 는 통째로 옮긴다 — 목록을 손으로 적었다가 새 파일이 빠져 설치본에서 조용히 안 돈 적이 있다.
for f in engine/compile.py engine/migrate-workflow.py engine/bouncer.sh engine/init.sh \
         $(cd "$SRC" && ls engine/lib/*.sh engine/lib/*.py) \
         hooks/session-start.sh hooks/pre-tool.sh hooks/stop.sh hooks/session-end.sh; do
  install -m 755 "$SRC/$f" "$NEW/$f" || { rm -rf "$NEW"; die "복사 실패: $f"; }
done
# 기본값은 엔진 소유 — 업데이트 때마다 덮어쓴다. 레포 workflow.yaml 은 이 위에 덧붙이는 override 만 담는다.
install -m 644 "$SRC/config/default.yaml" "$NEW/engine/default.yaml" || die "복사 실패: default.yaml"
for p in "$SRC"/config/prompts/*.md; do
  [ -f "$p" ] && { install -m 644 "$p" "$NEW/engine/prompts/$(basename "$p")" || die "복사 실패: $p"; }
done
COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
jq -n --arg c "$COMMIT" --arg b "$BRANCH" --arg t "$(date -u +%FT%TZ)" \
  '{commit:$c, branch:$b, installed_at:$t}' > "$NEW/installed.json"
# 도는 중인 훅이 반쯤 바뀐 파일을 읽지 않게 디렉토리를 한 번에 바꾼다.
rm -rf "$G.old"; [ -d "$G" ] && mv "$G" "$G.old"
mv "$NEW" "$G" || { [ -d "$G.old" ] && mv "$G.old" "$G"; die "설치 디렉토리 교체 실패"; }
rm -rf "$G.old"

mkdir -p "$CLAUDE_HOME/skills/dev-bounce"
install -m 644 "$SRC/skills/dev-bounce/SKILL.md" "$CLAUDE_HOME/skills/dev-bounce/SKILL.md" || die "스킬 복사 실패"

# ── 2. bouncer 실행 파일 ─────────────────────────────────────
BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
# 옛 버전이 남긴 심볼릭 링크면 cp 가 링크 대상을 덮어쓴다 — 먼저 지운다.
rm -f "$BINDIR/bouncer" 2>/dev/null
if printf '#!/usr/bin/env bash\nexec bash "%s/engine/bouncer.sh" "$@"\n' "$G" > "$BINDIR/bouncer" 2>/dev/null \
   && [ ! -L "$BINDIR/bouncer" ]; then
  chmod 755 "$BINDIR/bouncer"
else
  printf '  ⚠️ %s 를 만들지 못했다. 엔진은 %s 로 직접 부를 수 있다.\n' "$BINDIR/bouncer" "$G/engine/bouncer.sh"
fi
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '  ⚠️ %s 가 PATH에 없다. 쉘 설정에 추가하라:\n     export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac

# ── 3. hook 등록 (전역 settings, 남의 hook은 건드리지 않는다) ─
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" "$G" <<'PY' || die "hook 등록을 건너뛰고 설치를 중단했습니다."
import json, sys
settings_path, d = sys.argv[1], sys.argv[2]
spec = [
    ("SessionStart", None,                       f"{d}/hooks/session-start.sh", 30),
    ("PreToolUse",   "Edit|Write|MultiEdit|NotebookEdit|Bash", f"{d}/hooks/pre-tool.sh", 10),
    ("Stop",         None,                       f"{d}/hooks/stop.sh", 1800),
    ("SessionEnd",   None,                       f"{d}/hooks/session-end.sh", 5),
]
try:
    cfg = json.load(open(settings_path))
except Exception as exc:
    # 파싱 실패한 설정을 {}로 덮어쓰면 env/permissions/남의 hook이 전부 사라진다.
    import shutil, time
    bak = settings_path + ".bak-" + time.strftime("%Y%m%d%H%M%S")
    try:
        shutil.copy2(settings_path, bak)
    except Exception:
        bak = "(백업 실패)"
    sys.stderr.write(
        "ai-bouncer: settings.json 을 읽지 못했습니다 - %s\n"
        "  파일: %s\n  백업: %s\n"
        "  덮어쓰면 env/permissions/다른 도구의 hook이 사라지므로 설치를 중단합니다.\n"
        % (exc, settings_path, bak))
    sys.exit(3)
hooks = cfg.setdefault("hooks", {})
# 먼저 모든 이벤트에서 ai-bouncer hook을 걷어낸다 (구버전이 쓰던 이벤트 포함).
for event, arr in list(hooks.items()):
    for entry in list(arr):
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/.claude/ai-bouncer/" not in str(h.get("command", ""))
                          and not str(h.get("command", "")).startswith(d + "/")]
        if not entry["hooks"]:
            arr.remove(entry)
    if not arr:
        del hooks[event]
for event, matcher, cmd, timeout in spec:
    e = {"hooks": [{"type": "command", "command": cmd, "args": [], "timeout": timeout}]}
    if matcher:
        e["matcher"] = matcher
    hooks.setdefault(event, []).append(e)
json.dump(cfg, open(settings_path, "w"), ensure_ascii=False, indent=2)
print("  hook %d개 등록 (전역)" % len(spec))
PY

# 아주 옛 버전은 전역 ~/.claude/CLAUDE.md 에 규칙을 넣었다. 전역 파일은 건드리지 않고 알리기만 한다.
if grep -q 'ai-bouncer-rule start' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null; then
  printf '\n  ℹ️ %s 에 구버전 규칙 블록이 남아 있다 (# --- ai-bouncer-rule start --- ~ end ---). 지워도 된다.\n' "$CLAUDE_HOME/CLAUDE.md"
fi

printf '\n전역 설치 완료 (업데이트 브랜치 %s)\n' "$BRANCH"

# ── 4. 지금 레포에 켜기 ──────────────────────────────────────
if [ "$INIT" = 1 ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '\n'
  bash "$G/engine/init.sh" ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} || die "bouncer init 실패"
fi
[ "$CI" = 1 ] || printf '\n다음: 새 세션에서 /dev-bounce 를 실행해보라. 설정이 없는 레포에서는 켤지 먼저 묻는다.\n'
exit 0
