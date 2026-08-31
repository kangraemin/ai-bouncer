#!/usr/bin/env bash
# ai-bouncer 설치.
#   ./install.sh                프로젝트 로컬 (.claude/)  — 기본
#   ./install.sh --global       전역 (~/.claude/)
#   ./install.sh --ci           비대화 모드
#   ./install.sh --branch dev   업데이트 기준 브랜치 지정

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCOPE=local; CI=0; BRANCH=main
while [ $# -gt 0 ]; do
  case "$1" in
    --global) SCOPE=global; shift ;;
    --local)  SCOPE=local;  shift ;;
    --ci)     CI=1; shift ;;
    --branch) BRANCH="${2:-main}"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || die "jq가 필요하다. brew install jq"
command -v python3 >/dev/null 2>&1 || die "python3가 필요하다."

if [ "$SCOPE" = global ]; then
  ROOT="$HOME/.claude"; PROJECT="$HOME"
else
  PROJECT="$PWD"; ROOT="$PWD/.claude"
fi
DIR="$ROOT/ai-bouncer"
SETTINGS="$ROOT/settings.json"

printf 'ai-bouncer 설치 → %s\n' "$DIR"

# ── 1. 파일 배치 ─────────────────────────────────────────────
mkdir -p "$DIR"/{engine/lib,hooks,scripts,prompts,bin} "$ROOT/skills/dev-bounce" || die "디렉토리 생성 실패"
MANIFEST="[]"
for f in engine/compile.py engine/bouncer.sh engine/lib/common.sh \
         hooks/session-start.sh hooks/pre-tool.sh hooks/post-tool.sh \
         hooks/stop.sh hooks/session-end.sh scripts/update-check.sh; do
  mkdir -p "$DIR/$(dirname "$f")"
  install -m 755 "$SRC/$f" "$DIR/$f" || die "복사 실패: $f"
  MANIFEST="$(jq --arg p "$DIR/$f" '. + [$p]' <<<"$MANIFEST")"
done
install -m 644 "$SRC/skills/dev-bounce/SKILL.md" "$ROOT/skills/dev-bounce/SKILL.md" || die "스킬 복사 실패"
MANIFEST="$(jq --arg p "$ROOT/skills/dev-bounce/SKILL.md" '. + [$p]' <<<"$MANIFEST")"

# 워크플로우와 프롬프트는 사용자 자산 — 이미 있으면 덮어쓰지 않는다.
if [ -f "$DIR/workflow.yaml" ]; then
  printf '  workflow.yaml 유지 (기존 설정 보존)\n'
else
  install -m 644 "$SRC/config/default.yaml" "$DIR/workflow.yaml"
  MANIFEST="$(jq --arg p "$DIR/workflow.yaml" '. + [$p]' <<<"$MANIFEST")"
fi
for p in "$SRC"/config/prompts/*.md; do
  [ -f "$p" ] || continue
  t="$DIR/prompts/$(basename "$p")"
  [ -f "$t" ] || { install -m 644 "$p" "$t"; MANIFEST="$(jq --arg p "$t" '. + [$p]' <<<"$MANIFEST")"; }
done

# ── 2. config.json (기존 값 보존, 없는 키만 채움) ────────────
DEFAULTS="$(jq -n --arg b "$BRANCH" '{
  repo:"kangraemin/ai-bouncer", update_branch:$b, update_check:true,
  update_check_interval_hours:6, max_attempts:3, max_continue:10, stale_lock_hours:12
}')"
if [ -f "$DIR/config.json" ]; then
  printf '%s' "$(jq -s '.[0] * .[1]' <(printf '%s' "$DEFAULTS") "$DIR/config.json")" > "$DIR/config.json.tmp" \
    && mv "$DIR/config.json.tmp" "$DIR/config.json"
  printf '  config.json 병합 (기존 값 우선)\n'
else
  printf '%s\n' "$DEFAULTS" > "$DIR/config.json"
  MANIFEST="$(jq --arg p "$DIR/config.json" '. + [$p]' <<<"$MANIFEST")"
fi

# ── 3. bouncer 실행 파일 ─────────────────────────────────────
cat > "$DIR/bin/bouncer" <<SHIM
#!/usr/bin/env bash
exec bash "$DIR/engine/bouncer.sh" "\$@"
SHIM
chmod 755 "$DIR/bin/bouncer"
BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
ln -sf "$DIR/bin/bouncer" "$BINDIR/bouncer" 2>/dev/null \
  && MANIFEST="$(jq --arg p "$BINDIR/bouncer" '. + [$p]' <<<"$MANIFEST")"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '  ⚠️ %s 가 PATH에 없다. 쉘 설정에 추가하라:\n     export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac

# ── 4. hook 등록 (남의 hook은 건드리지 않는다) ───────────────
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" "$DIR" <<'PY'
import json, sys
settings_path, d = sys.argv[1], sys.argv[2]
spec = [
    ("SessionStart", None,                       f"{d}/hooks/session-start.sh", 30),
    ("PreToolUse",   "Edit|Write|MultiEdit|NotebookEdit|Bash", f"{d}/hooks/pre-tool.sh", 10),
    ("PostToolUse",  "ExitPlanMode|Skill",       f"{d}/hooks/post-tool.sh", 10),
    ("Stop",         None,                       f"{d}/hooks/stop.sh", 300),
    ("SessionEnd",   None,                       f"{d}/hooks/session-end.sh", 5),
]
try:
    cfg = json.load(open(settings_path))
except Exception:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
for event, matcher, cmd, timeout in spec:
    arr = hooks.setdefault(event, [])
    # 우리 hook만 제거하고 다시 넣는다 — 다른 도구의 hook은 그대로 둔다.
    for entry in list(arr):
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/ai-bouncer/hooks/" not in str(h.get("command", ""))]
        if not entry["hooks"]:
            arr.remove(entry)
    e = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
    if matcher:
        e["matcher"] = matcher
    arr.append(e)
json.dump(cfg, open(settings_path, "w"), ensure_ascii=False, indent=2)
print("  hook 5개 등록 완료")
PY

# ── 5. 런타임 상태를 gitignore ───────────────────────────────
# 이게 없으면 워킹트리가 항상 더러워서 finalize 게이트가 안 열린다.
GI="$PROJECT/.gitignore"
if git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
  if ! grep -qxF '.ai-bouncer/' "$GI" 2>/dev/null; then
    printf '\n# ai-bouncer 런타임 상태\n.ai-bouncer/\n' >> "$GI"
    printf '  .gitignore에 .ai-bouncer/ 추가\n'
  fi
  printf 'workflow.compiled.json\n' > "$DIR/.gitignore"
fi

# ── 6. 컴파일 + 기록 ─────────────────────────────────────────
python3 "$DIR/engine/compile.py" "$DIR/workflow.yaml" "$DIR/workflow.compiled.json" \
  || die "workflow.yaml 컴파일 실패"
COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
jq -n --arg c "$COMMIT" --arg b "$BRANCH" --arg s "$SCOPE" --arg t "$(date -u +%FT%TZ)" \
  '{commit:$c, branch:$b, scope:$s, installed_at:$t}' > "$DIR/installed.json"
printf '%s\n' "$MANIFEST" | jq '{files: .}' > "$DIR/manifest.json"

printf '\n설치 완료 (%s / 업데이트 브랜치 %s)\n' "$SCOPE" "$BRANCH"
printf '  워크플로우: %s\n  스킬:       /dev-bounce\n' "$DIR/workflow.yaml"
[ "$CI" = 1 ] || printf '\n다음: 새 세션에서 /dev-bounce 를 실행해보라.\n'
