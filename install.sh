#!/usr/bin/env bash
# ai-bouncer 설치.
#   ./install.sh                이 프로젝트에 설치 (.claude/ai-bouncer/)
#   ./install.sh --ci           비대화 모드 (사실 물어보는 게 없다)
#   ./install.sh --branch dev   업데이트 기준 브랜치 지정
#   ./install.sh --no-claude-md CLAUDE.md에 규칙 블록을 넣지 않음
#
# 설치는 프로젝트별로만 한다. 전역 설치는 지원하지 않는다.

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CI=0; BRANCH=main; CLAUDE_MD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-claude-md) CLAUDE_MD=0; shift ;;
    --global|--local)
      printf 'ai-bouncer: %s 는 더 이상 지원하지 않는다. 설치는 프로젝트별로만 한다.\n' "$1" >&2
      exit 1 ;;
    --ci)     CI=1; shift ;;
    --branch)
      [ $# -ge 2 ] || { printf 'ai-bouncer: --branch 에 값이 필요합니다.\n' >&2; exit 1; }
      BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || die "jq가 필요하다. brew install jq"
command -v python3 >/dev/null 2>&1 || die "python3가 필요하다."

# git 레포 안이면 루트에 설치한다. 서브디렉토리에 설치하면 Claude Code가 읽지 않는다.
PROJECT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
[ "$PROJECT" = "$PWD" ] || printf 'ai-bouncer: git 루트에 설치합니다 → %s\n' "$PROJECT"
ROOT="$PROJECT/.claude"; DIR="$ROOT/ai-bouncer"
SETTINGS="$ROOT/settings.json"

printf 'ai-bouncer 설치 → %s\n' "$DIR"

# ── 0. 구버전 마이그레이션 ───────────────────────────────────
# 구버전은 hook 7개와 문서 트리(.ai-bouncer-tasks/)를 쓴다. 신규와 구조가 달라
# 남겨두면 구 hook이 계속 돌면서 신규 워크플로우를 차단한다.
OLD_FILES="hooks/bash-gate.sh hooks/plan-gate.sh hooks/completion-gate.sh
hooks/subagent-track.sh hooks/subagent-cleanup.sh hooks/stop-active-cleanup.sh
hooks/stop-bouncer-compat.sh hooks/doc-reminder.sh
hooks/lib/resolve-task.sh hooks/lib/gate-checks.sh hooks/lib/block-logger.sh
scripts/bouncer-update-check.sh scripts/claim-active.sh scripts/worktree-helper.sh
scripts/bouncer-config.sh config.json
hooks/hooks.json .version-checked"
MIGRATED=0
for f in $OLD_FILES; do
  [ -f "$DIR/$f" ] && { rm -f "$DIR/$f"; MIGRATED=$((MIGRATED+1)); }
done
rmdir "$DIR/hooks/lib" 2>/dev/null
# 구버전이 깔던 위임 에이전트 정의 — 신규엔 위임 구조가 없어 참조 대상이 사라진 파일이다
for ag in dev.md e2e-writer.md intent.md lead.md qa.md guides/tc-guide.md; do
  [ -f "$ROOT/agents/$ag" ] && { rm -f "$ROOT/agents/$ag"; MIGRATED=$((MIGRATED+1)); }
done
rmdir "$ROOT/agents/guides" "$ROOT/agents" 2>/dev/null
# 구버전이 프로젝트 루트에 복사해두던 제거 스크립트
if [ -f "$PROJECT/uninstall.sh" ] && grep -q 'ai-bouncer uninstall' "$PROJECT/uninstall.sh" 2>/dev/null; then
  rm -f "$PROJECT/uninstall.sh"; MIGRATED=$((MIGRATED+1))
fi
# 구버전 전용 스킬
for sk in bouncer-status update-bouncer; do
  [ -d "$ROOT/skills/$sk" ] && { rm -rf "$ROOT/skills/$sk"; MIGRATED=$((MIGRATED+1)); }
done
[ "$MIGRATED" -gt 0 ] && printf '  구버전 파일 %d개 정리 (설정은 workflow.yaml의 settings로 옮겼다)\n' "$MIGRATED"

# 구버전은 프로젝트 .claude/CLAUDE.md 에도 규칙 블록을 넣었다.
# 신규는 프로젝트 루트 CLAUDE.md를 쓰므로, 그대로 두면 같은 지시가 두 군데 남아
# 서로 다른 버전의 규칙을 가리키게 된다.
OLD_CMD="$ROOT/CLAUDE.md"
if [ -f "$OLD_CMD" ] && grep -q 'ai-bouncer-rule start' "$OLD_CMD"; then
  python3 - "$OLD_CMD" <<'PYC'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*# --- ai-bouncer-rule start ---.*?# --- ai-bouncer-rule end ---\n*', '\n', s, flags=re.S)
open(p, 'w').write(s)
PYC
  if [ -n "$(tr -d '[:space:]' < "$OLD_CMD" 2>/dev/null)" ]; then
    printf '  .claude/CLAUDE.md 의 구 규칙 블록 제거 (나머지 내용은 유지)\n'
  else
    rm -f "$OLD_CMD"
    printf '  .claude/CLAUDE.md 제거 (구 규칙 블록뿐이었다)\n'
  fi
fi

# 구버전은 전역 ~/.claude/CLAUDE.md에도 규칙을 넣었다. 전역 파일은 건드리지 않고 알리기만 한다.
OLD_GLOBAL_RULE=0
grep -q 'ai-bouncer-rule start' "$HOME/.claude/CLAUDE.md" 2>/dev/null && OLD_GLOBAL_RULE=1

# 구버전 진행 중 작업은 신규 엔진이 읽지 못한다. 지우지 않고 알리기만 한다.
OLD_TASKS=0
if [ -d "$PROJECT/.ai-bouncer-tasks" ]; then
  OLD_TASKS=$(find "$PROJECT/.ai-bouncer-tasks" -name state.json 2>/dev/null \
    | xargs -I{} jq -r 'select(.workflow_phase and (.workflow_phase|IN("done","cancelled")|not)) | "x"' {} 2>/dev/null | wc -l | tr -d ' ')
fi

# ── 1. 파일 배치 ─────────────────────────────────────────────
mkdir -p "$DIR"/{engine/lib,hooks,scripts,prompts,bin} "$ROOT/skills/dev-bounce" || die "디렉토리 생성 실패"
MANIFEST="[]"
for f in engine/compile.py engine/bouncer.sh engine/lib/common.sh engine/lib/guard.py \
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

# ── 2. 업데이트 브랜치 반영 ──────────────────────────────────
# 설정은 workflow.yaml의 settings 섹션에 있다. 별도 config 파일은 없다.
if [ "$BRANCH" != "main" ]; then
  if grep -qE '^[[:space:]]*update_branch:' "$DIR/workflow.yaml"; then
    python3 - "$DIR/workflow.yaml" "$BRANCH" <<'PYB'
import re, sys
p, b = sys.argv[1], sys.argv[2]
s = open(p).read()
open(p, 'w').write(re.sub(r'(?m)^(\s*)update_branch:.*$', r'\g<1>update_branch: ' + b, s, count=1))
PYB
    printf '  업데이트 브랜치 → %s\n' "$BRANCH"
  else
    printf '  ⚠️ workflow.yaml에 update_branch가 없다. settings에 직접 추가하라:\n'
    printf '     settings:\n       update_branch: %s\n' "$BRANCH"
  fi
fi

# ── 3. bouncer 실행 파일 ─────────────────────────────────────
# 설치가 프로젝트별이므로, 셸에서 부를 때 현재 위치의 프로젝트 엔진을 찾아 실행한다.
# 특정 프로젝트 경로를 박아두면 다른 레포에서 엉뚱한 버전이 돈다.
mkdir -p "$DIR/bin"
cat > "$DIR/bin/bouncer" <<'SHIM'
#!/usr/bin/env bash
d="$PWD"
while [ "$d" != "/" ]; do
  if [ -f "$d/.claude/ai-bouncer/engine/bouncer.sh" ]; then
    exec bash "$d/.claude/ai-bouncer/engine/bouncer.sh" "$@"
  fi
  d="$(dirname "$d")"
done
printf 'ai-bouncer: 이 프로젝트에 설치되어 있지 않다 (./install.sh 로 설치).\n' >&2
exit 1
SHIM
chmod 755 "$DIR/bin/bouncer"
BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
ln -sf "$DIR/bin/bouncer" "$BINDIR/bouncer" 2>/dev/null
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '  ⚠️ %s 가 PATH에 없다. 쉘 설정에 추가하라:\n     export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac

# ── 4. hook 등록 (남의 hook은 건드리지 않는다) ───────────────
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
python3 - "$SETTINGS" <<'PY' || die "hook 등록을 건너뛰고 설치를 중단했습니다."
import json, sys
settings_path = sys.argv[1]
# 절대경로를 박으면 이 settings.json을 커밋했을 때 다른 사람 컴퓨터에서 깨진다.
# ${CLAUDE_PROJECT_DIR}는 세션이 시작된 프로젝트 루트로 치환된다.
# 경로 placeholder에는 exec form(args 포함)이 권장된다 — 셸 개입 없이 그대로 치환된다.
d = "${CLAUDE_PROJECT_DIR}/.claude/ai-bouncer"
spec = [
    ("SessionStart", None,                       f"{d}/hooks/session-start.sh", 30),
    ("PreToolUse",   "Edit|Write|MultiEdit|NotebookEdit|Bash", f"{d}/hooks/pre-tool.sh", 10),
    ("PostToolUse",  "ExitPlanMode|Skill",       f"{d}/hooks/post-tool.sh", 10),
    ("Stop",         None,                       f"{d}/hooks/stop.sh", 300),
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
        "  JSON 문법을 고친 뒤 다시 실행하세요 (주석/후행 콤마/BOM은 허용되지 않습니다).\n"
        % (exc, settings_path, bak))
    sys.exit(3)
hooks = cfg.setdefault("hooks", {})

# 먼저 모든 이벤트에서 ai-bouncer hook을 걷어낸다.
# 등록할 이벤트만 청소하면, 구버전이 쓰던 다른 이벤트(SubagentStart 등)에
# 이미 지워진 스크립트를 가리키는 등록이 남는다.
for event, arr in list(hooks.items()):
    for entry in list(arr):
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/.claude/ai-bouncer/" not in str(h.get("command", ""))]
        if not entry["hooks"]:
            arr.remove(entry)
    if not arr:
        del hooks[event]

for event, matcher, cmd, timeout in spec:
    arr = hooks.setdefault(event, [])
    e = {"hooks": [{"type": "command", "command": cmd, "args": [], "timeout": timeout}]}
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
    GITIGNORE_ADDED=1
    printf '  .gitignore에 .ai-bouncer/ 추가\n'
  fi
  printf 'workflow.compiled.json\n' > "$DIR/.gitignore"
fi

# ── 6. CLAUDE.md 규칙 블록 ───────────────────────────────────
# hook은 작업이 시작된 뒤에만 강제할 수 있다. `.active`가 없으면 PreToolUse는 통과시킨다.
# 그래서 "작업을 시작하게 만드는 것"은 프롬프트 레벨이어야 한다.
# 전역 CLAUDE.md는 건드리지 않는다 — 설치가 프로젝트별이므로 프로젝트 파일에만 넣는다.
CMD_FILE="$PROJECT/CLAUDE.md"
if [ "$CLAUDE_MD" = 1 ]; then
  BLOCK="$(cat <<'MD'
<!-- ai-bouncer:start -->
## ai-bouncer

코드 수정·기능 구현·버그 수정·리팩터링 등 **개발 작업은 `/dev-bounce`로 시작한다.**
스킬을 거치지 않고 Edit / Write / Bash로 소스를 고치지 않는다.

- 작업이 시작되면 hook이 단계별 규칙을 강제한다. 시작 전에는 아무것도 막지 않는다.
- 진행 중인 작업이 있는지 `bouncer status`로 먼저 확인하고, 있으면 이어서 한다.
- 질문·설명 요청은 해당 없다. 그냥 답하면 된다.
- hook이 차단하면 우회하지 말고 차단 사유에 적힌 조건을 충족시켜라.
<!-- ai-bouncer:end -->
MD
)"
  if [ -f "$CMD_FILE" ] && grep -q '<!-- ai-bouncer:start -->' "$CMD_FILE"; then
    # 기존 블록만 교체. 사용자가 쓴 나머지 내용은 건드리지 않는다.
    python3 - "$CMD_FILE" <<PYM
import re, sys
p = sys.argv[1]
s = open(p).read()
block = '''$BLOCK'''
s = re.sub(r'<!-- ai-bouncer:start -->.*?<!-- ai-bouncer:end -->', block, s, flags=re.S)
open(p, 'w').write(s)
PYM
    printf '  CLAUDE.md 규칙 블록 갱신\n'
  else
    [ -f "$CMD_FILE" ] && printf '\n' >> "$CMD_FILE"
    printf '%s\n' "$BLOCK" >> "$CMD_FILE"
    MANIFEST="$(jq --arg p "$CMD_FILE" '. + [$p]' <<<"$MANIFEST")"
    printf '  CLAUDE.md에 규칙 블록 추가\n'
  fi
fi

# ── 7. 컴파일 + 기록 ─────────────────────────────────────────
python3 "$DIR/engine/compile.py" "$DIR/workflow.yaml" "$DIR/workflow.compiled.json" \
  || die "workflow.yaml 컴파일 실패"
COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
jq -n --arg c "$COMMIT" --arg b "$BRANCH" --arg t "$(date -u +%FT%TZ)" \
  '{commit:$c, branch:$b, installed_at:$t}' > "$DIR/installed.json"
# 경로는 프로젝트 기준 상대경로로 저장한다. 절대경로면 clone한 다른 위치에서
# 제거할 때 아무것도 못 지우면서 "제거했다"고 보고하게 된다.
printf '%s\n' "$MANIFEST" \
  | jq --arg root "$PROJECT/" --argjson gi "${GITIGNORE_ADDED:-0}" \
      '{files: (map(if startswith($root) then .[($root|length):] else . end)),
        gitignore_added: ($gi == 1)}' > "$DIR/manifest.json"

OLD_GLOBAL_HOOKS=0
if [ -f "$HOME/.claude/settings.json" ]; then
  OLD_GLOBAL_HOOKS="$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[]
    | select(.command | contains("/.claude/ai-bouncer/"))] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo 0)"
fi
if [ "${OLD_GLOBAL_HOOKS:-0}" -gt 0 ] 2>/dev/null; then
  printf '\n  ⚠️ 전역 ~/.claude/settings.json 에 구버전 hook %s개가 아직 등록돼 있다.\n' "$OLD_GLOBAL_HOOKS"
  printf '     그대로 두면 구 hook과 신규 hook이 동시에 돌아 작업이 차단될 수 있다.\n'
  printf '     정리: bash <ai-bouncer>/migrate.sh --apply\n'
fi

if [ "${OLD_GLOBAL_RULE:-0}" = 1 ]; then
  printf '\n  ℹ️ 전역 ~/.claude/CLAUDE.md에 구버전 규칙 블록이 남아 있다.\n'
  printf '     신규는 프로젝트 CLAUDE.md만 쓰므로 전역 블록은 지워도 된다\n'
  printf '     (# --- ai-bouncer-rule start --- ~ end --- 구간). 전역 파일은 건드리지 않았다.\n'
fi

if [ "${OLD_TASKS:-0}" -gt 0 ] 2>/dev/null; then
  printf '\n  ⚠️ 구버전 미완료 작업 %s건이 .ai-bouncer-tasks/ 에 있다.\n' "$OLD_TASKS"
  printf '     신규 엔진은 이 형식을 읽지 못한다. 문서는 그대로 두었으니\n'
  printf '     필요하면 직접 확인하고, 새 작업은 /dev-bounce 로 시작하라.\n'
fi

printf '\n설치 완료 (업데이트 브랜치 %s)\n' "$BRANCH"
printf '  워크플로우: %s\n  스킬:       /dev-bounce\n' "$DIR/workflow.yaml"
[ "$CI" = 1 ] || printf '\n다음: 새 세션에서 /dev-bounce 를 실행해보라.\n'
